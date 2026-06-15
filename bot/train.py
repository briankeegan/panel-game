#!/usr/bin/env python3
"""Behavior-cloning trainer (DATA_CONTRACT §14). Trains the per-player policy on the
shared-encoder feature binaries and exports weights in the bot's FFI format.

Usage: train.py <name> <feat_dir> <split_dir> <out_dir>
  e.g. train.py chaos952 bot/data/chaos_feat bot/data/chaos_bot bot/models/chaos952

Features come from bot/parseReplays.lua (PA_PARSE_EMIT=features): per-game gzip of
[int32 N, int32 featSize, N*featSize float32, N int32 labels]. Labels are
ActionCodes indices (1-based: 1=WAIT, 2=RAISE, 3..62=SWAP). Split via the gameId
lists in <split_dir>.
"""
import sys, os, gzip, struct, json
import numpy as np
import torch
import torch.nn as nn

FSIZE, NCLASS = 589, 62
WAIT, RAISE = 1, 2  # 1-based label values
WAIT_KEEP = 0.3     # subsample WAIT in TRAIN (kept fraction); val stays full


def load_game(feat_dir, gid):
    fp = os.path.join(feat_dir, f"{gid}.feat.gz")
    if not os.path.exists(fp):
        return None, None
    raw = gzip.open(fp, "rb").read()
    n, fs = struct.unpack("<ii", raw[:8])
    X = np.frombuffer(raw[8:8 + n * fs * 4], dtype="<f4").reshape(n, fs).copy()
    y = np.frombuffer(raw[8 + n * fs * 4:], dtype="<i4").copy()
    return X, y


def load_split(feat_dir, gamefile, wait_keep=1.0):
    Xs, ys = [], []
    for line in open(gamefile):
        gid = line.strip()
        if not gid:
            continue
        X, y = load_game(feat_dir, gid)
        if X is None:
            continue
        if wait_keep < 1.0:
            keep = (y != WAIT) | (np.random.rand(len(y)) < wait_keep)
            X, y = X[keep], y[keep]
        Xs.append(X); ys.append(y)
    return np.concatenate(Xs), np.concatenate(ys)


def typ(cls):  # 1-based class -> coarse type
    return np.where(cls == WAIT, 0, np.where(cls == RAISE, 1, 2))


def main():
    name, feat_dir, split_dir, out_dir = sys.argv[1:5]
    os.makedirs(out_dir, exist_ok=True)
    torch.manual_seed(0); np.random.seed(0)

    print(f"[{name}] loading…")
    Xtr, ytr = load_split(feat_dir, os.path.join(split_dir, "train_games.txt"), WAIT_KEEP)
    Xva, yva = load_split(feat_dir, os.path.join(split_dir, "val_games.txt"), 1.0)
    print(f"  train {Xtr.shape}  val {Xva.shape}")

    # class weights: inverse sqrt frequency, normalized (0-based for torch)
    counts = np.bincount(ytr - 1, minlength=NCLASS).astype(np.float64)
    w = 1.0 / np.sqrt(np.maximum(counts, 1.0))
    w = w / w.mean()
    weight = torch.tensor(w, dtype=torch.float32)

    Xtr_t = torch.from_numpy(Xtr)
    ytr_t = torch.from_numpy((ytr - 1).astype(np.int64))
    Xva_t = torch.from_numpy(Xva)
    yva_np = yva  # 1-based

    model = nn.Sequential(
        nn.Linear(FSIZE, 256), nn.ReLU(),
        nn.Linear(256, 128), nn.ReLU(),
        nn.Linear(128, NCLASS),
    )
    opt = torch.optim.Adam(model.parameters(), lr=1e-3, weight_decay=1e-5)
    lossfn = nn.CrossEntropyLoss(weight=weight)

    N = Xtr_t.shape[0]
    BS, EPOCHS = 4096, 6
    for ep in range(EPOCHS):
        model.train()
        perm = torch.randperm(N)
        tot = 0.0
        for i in range(0, N, BS):
            idx = perm[i:i + BS]
            opt.zero_grad()
            out = model(Xtr_t[idx])
            loss = lossfn(out, ytr_t[idx])
            loss.backward(); opt.step()
            tot += loss.item() * len(idx)
        # val
        model.eval()
        with torch.no_grad():
            pred = (model(Xva_t).argmax(1).numpy() + 1)  # back to 1-based
        type_agree = (typ(pred) == typ(yva_np)).mean()
        swap_mask = yva_np >= 3
        swap_recall = (typ(pred[swap_mask]) == 2).mean() if swap_mask.any() else 0.0
        swap_pos = (pred[swap_mask] == yva_np[swap_mask]).mean() if swap_mask.any() else 0.0
        print(f"  epoch {ep+1}/{EPOCHS} loss {tot/N:.3f}  val type_agree {type_agree:.3f} "
              f"SWAP_recall {swap_recall:.3f} SWAP_pos {swap_pos:.3f}")

    # export: flat LE float32, per layer W(out×in, row-major) then b(out)
    layers_meta = []
    blobs = []
    for lin, act in [(model[0], "relu"), (model[2], "relu"), (model[4], "none")]:
        Wt = lin.weight.detach().numpy().astype("<f4")  # (out, in) row-major
        b = lin.bias.detach().numpy().astype("<f4")
        blobs.append(Wt.tobytes()); blobs.append(b.tobytes())
        layers_meta.append({"in": Wt.shape[1], "out": Wt.shape[0], "act": act})
    open(os.path.join(out_dir, "weights.bin"), "wb").write(b"".join(blobs))
    json.dump({"layers": layers_meta, "featureSize": FSIZE, "actionCount": NCLASS},
              open(os.path.join(out_dir, "model.json"), "w"), indent=2)
    print(f"  exported -> {out_dir}/weights.bin (+model.json)")


if __name__ == "__main__":
    main()
