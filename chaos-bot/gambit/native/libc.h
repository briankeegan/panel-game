// What the engines take from a C library, which they are built without
// (-nostdlib): the integer types, memcpy / memset as the single bulk-memory
// instructions (memory.copy, memory.fill), and memcmp, which a variable-length
// __builtin_memcmp lowers to; weak, so two files that
// both include this can be linked into one module (bit.c with pa.c). A native
// build (the drill, drill.c) takes them from the system's C library.
#ifndef LIBC_H
#define LIBC_H
typedef int int32_t;
typedef unsigned int uint32_t;
typedef unsigned char uint8_t;
typedef unsigned short uint16_t;
typedef uint16_t Wait;   // a frame count the engine reports: as wide as the longest board settles
#ifdef __wasm__
__attribute__((weak)) void *memcpy(void *d, const void *s, unsigned long n) { __builtin_memcpy(d, s, n); return d; }
__attribute__((weak)) void *memset(void *d, int c, unsigned long n) { __builtin_memset(d, c, n); return d; }
__attribute__((weak)) int memcmp(const void *a, const void *b, unsigned long n) {
  const unsigned char *x = a, *y = b;
  for (unsigned long i = 0; i < n; i++) if (x[i] != y[i]) return x[i] < y[i] ? -1 : 1;
  return 0;
}
#else
void *memcpy(void *d, const void *s, unsigned long n);
void *memset(void *d, int c, unsigned long n);
int memcmp(const void *a, const void *b, unsigned long n);
#endif
// PATLS: a counter every thread bumps on every frame or resolve, natively each
// thread's own -- one shared line written from every core stalls them all
#ifdef __wasm__
#define PATLS
#else
#define PATLS _Thread_local
#endif
#endif
