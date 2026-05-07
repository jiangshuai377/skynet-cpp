/* atomic.h -- Windows-compatible atomic operations for Skynet's Lua 5.5.0 */
#ifndef SKYNET_ATOMIC_H
#define SKYNET_ATOMIC_H

#include <stddef.h>
#include <stdint.h>

#ifdef _MSC_VER
/* MSVC: use Interlocked intrinsics */
#include <windows.h>
#include <intrin.h>

#define ATOM_INT volatile long
#define ATOM_POINTER volatile uintptr_t
#define ATOM_SIZET volatile size_t
#define ATOM_ULONG volatile unsigned long
#define ATOM_INIT(ptr, v) (*(ptr) = (v))
#define ATOM_LOAD(ptr) (*(ptr))
#define ATOM_STORE(ptr, v) (*(ptr) = (v))
#define ATOM_CAS(ptr, oval, nval) (InterlockedCompareExchange((volatile LONG*)(ptr), (LONG)(nval), (LONG)(oval)) == (LONG)(oval))
#define ATOM_CAS_ULONG(ptr, oval, nval) (InterlockedCompareExchange((volatile LONG*)(ptr), (LONG)(nval), (LONG)(oval)) == (LONG)(oval))
#define ATOM_CAS_SIZET(ptr, oval, nval) (InterlockedCompareExchange64((volatile LONG64*)(ptr), (LONG64)(nval), (LONG64)(oval)) == (LONG64)(oval))
#define ATOM_CAS_POINTER(ptr, oval, nval) (InterlockedCompareExchange64((volatile LONG64*)(ptr), (LONG64)(nval), (LONG64)(oval)) == (LONG64)(oval))
#define ATOM_FINC(ptr) InterlockedIncrement((volatile LONG*)(ptr))
#define ATOM_FDEC(ptr) InterlockedDecrement((volatile LONG*)(ptr))
#define ATOM_FADD(ptr,n) InterlockedExchangeAdd((volatile LONG*)(ptr), (LONG)(n))
#define ATOM_FSUB(ptr,n) InterlockedExchangeAdd((volatile LONG*)(ptr), -(LONG)(n))
#define ATOM_FAND(ptr,n) InterlockedAnd((volatile LONG*)(ptr), (LONG)(n))

/* For spinlock.h compatibility */
#define STD_

#else /* GCC/Clang */

#ifdef __STDC_NO_ATOMICS__

#define ATOM_INT volatile int
#define ATOM_POINTER volatile uintptr_t
#define ATOM_SIZET volatile size_t
#define ATOM_ULONG volatile unsigned long
#define ATOM_INIT(ptr, v) (*(ptr) = v)
#define ATOM_LOAD(ptr) (*(ptr))
#define ATOM_STORE(ptr, v) (*(ptr) = v)
#define ATOM_CAS(ptr, oval, nval) __sync_bool_compare_and_swap(ptr, oval, nval)
#define ATOM_CAS_ULONG(ptr, oval, nval) __sync_bool_compare_and_swap(ptr, oval, nval)
#define ATOM_CAS_SIZET(ptr, oval, nval) __sync_bool_compare_and_swap(ptr, oval, nval)
#define ATOM_CAS_POINTER(ptr, oval, nval) __sync_bool_compare_and_swap(ptr, oval, nval)
#define ATOM_FINC(ptr) __sync_fetch_and_add(ptr, 1)
#define ATOM_FDEC(ptr) __sync_fetch_and_sub(ptr, 1)
#define ATOM_FADD(ptr,n) __sync_fetch_and_add(ptr, n)
#define ATOM_FSUB(ptr,n) __sync_fetch_and_sub(ptr, n)
#define ATOM_FAND(ptr,n) __sync_fetch_and_and(ptr, n)

#else

#include <stdatomic.h>
#define STD_

#define ATOM_INT  atomic_int
#define ATOM_POINTER atomic_uintptr_t
#define ATOM_SIZET atomic_size_t
#define ATOM_ULONG atomic_ulong
#define ATOM_INIT(ref, v) atomic_init(ref, v)
#define ATOM_LOAD(ptr) atomic_load(ptr)
#define ATOM_STORE(ptr, v) atomic_store(ptr, v)

static inline int
ATOM_CAS(atomic_int *ptr, int oval, int nval) {
    return atomic_compare_exchange_weak(ptr, &(oval), nval);
}
static inline int
ATOM_CAS_SIZET(atomic_size_t *ptr, size_t oval, size_t nval) {
    return atomic_compare_exchange_weak(ptr, &(oval), nval);
}
static inline int
ATOM_CAS_ULONG(atomic_ulong *ptr, unsigned long oval, unsigned long nval) {
    return atomic_compare_exchange_weak(ptr, &(oval), nval);
}
static inline int
ATOM_CAS_POINTER(atomic_uintptr_t *ptr, uintptr_t oval, uintptr_t nval) {
    return atomic_compare_exchange_weak(ptr, &(oval), nval);
}

#define ATOM_FINC(ptr) atomic_fetch_add(ptr, 1)
#define ATOM_FDEC(ptr) atomic_fetch_sub(ptr, 1)
#define ATOM_FADD(ptr,n) atomic_fetch_add(ptr, n)
#define ATOM_FSUB(ptr,n) atomic_fetch_sub(ptr, n)
#define ATOM_FAND(ptr,n) atomic_fetch_and(ptr, n)

#endif /* __STDC_NO_ATOMICS__ */

#endif /* _MSC_VER */

#endif /* SKYNET_ATOMIC_H */
