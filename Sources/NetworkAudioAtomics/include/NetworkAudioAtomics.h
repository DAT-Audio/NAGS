// Atomic loads and stores for values shared between the audio or network threads and the UI
// C11 <stdatomic.h>, because Swift's own `Atomic` needs macOS 15 and the
// swift-atomics package would be a dependency to licence for six one-line functions.
//
// Relaxed access compiles to the same single load or store the plain code did on arm64 and
// x86-64; what it adds is the guarantee — no torn value, no load hoisted out of a loop or a
// store dropped by the optimiser — that plain Swift memory access across threads does not give.

#ifndef NETWORK_AUDIO_ATOMICS_H
#define NETWORK_AUDIO_ATOMICS_H

#include <stdatomic.h>
#include <stdint.h>

static inline uint32_t nag_load32(const uint32_t *p) {
    return atomic_load_explicit((const _Atomic uint32_t *)p, memory_order_relaxed);
}
static inline void nag_store32(uint32_t *p, uint32_t v) {
    atomic_store_explicit((_Atomic uint32_t *)p, v, memory_order_relaxed);
}
static inline uint32_t nag_load32_acquire(const uint32_t *p) {
    return atomic_load_explicit((const _Atomic uint32_t *)p, memory_order_acquire);
}
static inline void nag_store32_release(uint32_t *p, uint32_t v) {
    atomic_store_explicit((_Atomic uint32_t *)p, v, memory_order_release);
}
static inline uint64_t nag_load64(const uint64_t *p) {
    return atomic_load_explicit((const _Atomic uint64_t *)p, memory_order_relaxed);
}
static inline void nag_store64(uint64_t *p, uint64_t v) {
    atomic_store_explicit((_Atomic uint64_t *)p, v, memory_order_relaxed);
}
static inline void nag_fence_acquire(void) { atomic_thread_fence(memory_order_acquire); }
static inline void nag_fence_release(void) { atomic_thread_fence(memory_order_release); }

#endif
