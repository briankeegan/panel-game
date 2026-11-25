// A STABLE SORT: of two elements that compare equal, the one first stays first -- a beam whose lines score the same keeps them in the
// order they were made.
#ifndef GAMBIT_SORT_H
#define GAMBIT_SORT_H
// Sorts n ints a[] by key[a[i]] descending, ties in their order (a merge sort into tmp, n at most the room tmp has).
static void sortByKeyDesc(int32_t *a, int32_t n, const int32_t *key, int32_t *tmp) {
  for (int32_t w = 1; w < n; w *= 2)
    for (int32_t lo = 0; lo < n; lo += 2 * w) {
      int32_t mid = lo + w < n ? lo + w : n, hi = lo + 2 * w < n ? lo + 2 * w : n, i = lo, j = mid, k = lo;
      while (i < mid && j < hi) tmp[k++] = key[a[j]] > key[a[i]] ? a[j++] : a[i++];
      while (i < mid) tmp[k++] = a[i++];
      while (j < hi) tmp[k++] = a[j++];
      for (k = lo; k < hi; k++) a[k] = tmp[k];
    }
}
// The same by a double key (a nearness, a lead).
static void sortByDoubleDesc(int32_t *a, int32_t n, const double *key, int32_t *tmp) {
  for (int32_t w = 1; w < n; w *= 2)
    for (int32_t lo = 0; lo < n; lo += 2 * w) {
      int32_t mid = lo + w < n ? lo + w : n, hi = lo + 2 * w < n ? lo + 2 * w : n, i = lo, j = mid, k = lo;
      while (i < mid && j < hi) tmp[k++] = key[a[j]] > key[a[i]] ? a[j++] : a[i++];
      while (i < mid) tmp[k++] = a[i++];
      while (j < hi) tmp[k++] = a[j++];
      for (k = lo; k < hi; k++) a[k] = tmp[k];
    }
}
#endif
