// WHAT A BOARD'S PANELS ARE WORTH IN LIFE, MEASURED (core/material.h): over the games of Gambit runs (a directory per game, each with its
// results.txt and survivor.log), the frames boards spent with each number of panels on them (the decision log's pan=, held to the next
// decision) and the games lost there (the panels at the last decision). Pooled a row's worth of panels a bin; a bin's life is its frames
// over its losses, a loss not yet seen counted as one. The life of every count is drawn straight between the bins' middles.
//
//   ./build.sh material DIR...           builds this with the system's libc, writes core/material.h, prints the bins
//
// The header is made by this, never by hand; made again from new runs when the bot changes enough to move it.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define W 6
#define ROWS 12
#define MAXP (W * ROWS)
#define NB (ROWS + 1)
#define MAXRUNS 64

static long long frames[NB];
static int lost[NB], games, losses, nruns;
static char runs[MAXRUNS][32];
static int binOf(int p) { int b = p / W; return b < NB - 1 ? b : NB - 1; }

// one game: its end (lost or survived, the frame), its decisions' frames and panels
static void readGame(const char *dir) {
  char path[4096], line[1 << 16];
  snprintf(path, sizeof path, "%s/results.txt", dir);
  FILE *f = fopen(path, "r");
  if (!f) return;
  int end = -1, wasLost = 0;
  while (fgets(line, sizeof line, f)) {
    char *p;
    if ((p = strstr(line, " lost frames="))) { end = atoi(p + 13); wasLost = 1; break; }
    if ((p = strstr(line, " survived frames="))) { end = atoi(p + 17); break; }
  }
  fclose(f);
  if (end < 0) return;
  snprintf(path, sizeof path, "%s/survivor.log", dir);
  if (!(f = fopen(path, "r"))) return;
  int lastF = -1, lastP = -1, any = 0;
  while (fgets(line, sizeof line, f)) {
    if (strncmp(line, "GAMBITD ", 8)) continue;
    char *p = strstr(line, " pan=");
    if (!p) continue;
    int fr = atoi(line + 8), pan = atoi(p + 5);
    if (any && fr != lastF) frames[binOf(lastP)] += fr - lastF > 0 ? fr - lastF : 0;
    lastF = fr; lastP = pan; any = 1;
  }
  fclose(f);
  if (!any) return;
  frames[binOf(lastP)] += end - lastF > 0 ? end - lastF : 0;
  if (wasLost) { lost[binOf(lastP)]++; losses++; }
  games++;
  // (the run: the directory's name up to its first '-')
  const char *base = strrchr(dir, '/');
  base = base && base[1] ? base + 1 : dir;
  char run[32]; int k = 0;
  while (base[k] && base[k] != '-' && k < 31) { run[k] = base[k]; k++; }
  run[k] = 0;
  for (int i = 0; i < nruns; i++) if (!strcmp(runs[i], run)) return;
  if (nruns < MAXRUNS) strcpy(runs[nruns++], run);
}

int main(int argc, char **argv) {
  if (argc < 3) { fprintf(stderr, "material OUT.h DIR...\n"); return 2; }
  for (int i = 2; i < argc; i++) { size_t n = strlen(argv[i]); if (n && argv[i][n - 1] == '/') argv[i][n - 1] = 0; readGame(argv[i]); }
  if (!games) { fprintf(stderr, "material: no games with pan= in their logs\n"); return 1; }
  double mid[NB], life[NB]; int nb = 0;
  for (int b = 0; b < NB; b++) if (frames[b] > 0) { mid[nb] = b * W + (W - 1) / 2.0; life[nb] = (double)frames[b] / (lost[b] > 1 ? lost[b] : 1); nb++; }
  int out[MAXP + 1];
  for (int p = 0; p <= MAXP; p++) {
    double v = life[0];
    if (p >= mid[nb - 1]) v = life[nb - 1];
    else for (int i = 0; i + 1 < nb; i++) if (p >= mid[i] && p <= mid[i + 1]) { double t = (p - mid[i]) / (mid[i + 1] - mid[i]); v = life[i] + t * (life[i + 1] - life[i]); break; }
    out[p] = (int)(v + 0.5);
  }
  FILE *h = fopen(argv[1], "w");
  if (!h) { fprintf(stderr, "material: cannot write %s\n", argv[1]); return 1; }
  fprintf(h, "// THE LIFE A BOARD HAS, BY THE PANELS ON IT (outcome.c lifeOf), in frames: made by material.c from %d games of %d runs (", games, nruns);
  for (int i = 0; i < nruns; i++) fprintf(h, "%s%s", i ? ", " : "", runs[i]);
  fprintf(h, "),\n// %d lost -- never by hand. A row's worth of panels a bin, its frames over its losses (a loss not yet seen counted as one), drawn\n// straight between the bins' middles:\n", losses);
  for (int b = 0; b < NB; b++) {
    fprintf(h, "//   %2d-%2d  %8lld frames  %3d lost\n", b * W, b * W + W - 1, frames[b], lost[b]);
    printf("%2d-%2d  %8lld frames  %3d lost\n", b * W, b * W + W - 1, frames[b], lost[b]);
  }
  fprintf(h, "#define LIFEMAX %d\nstatic const int32_t LIFE[LIFEMAX + 1] = {\n", MAXP);
  for (int p = 0; p <= MAXP; p++) fprintf(h, "%s%d%s%s", p % 12 == 0 ? "  " : "", out[p], p < MAXP ? "," : "", p % 12 == 11 || p == MAXP ? "\n" : " ");
  fprintf(h, "};\n");
  fclose(h);
  printf("wrote %s: %d games, %d lost\n", argv[1], games, losses);
  return 0;
}
