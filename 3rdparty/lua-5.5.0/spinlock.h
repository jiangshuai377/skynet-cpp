/* spinlock.h -- Windows-compatible spinlock for Skynet's Lua 5.5.0 */
#ifndef SKYNET_SPINLOCK_H
#define SKYNET_SPINLOCK_H

#define SPIN_INIT(q) spinlock_init(&(q)->lock);
#define SPIN_LOCK(q) spinlock_lock(&(q)->lock);
#define SPIN_UNLOCK(q) spinlock_unlock(&(q)->lock);
#define SPIN_DESTROY(q) spinlock_destroy(&(q)->lock);

#ifdef _MSC_VER
/* Windows: use CRITICAL_SECTION for simplicity */
#include <windows.h>

struct spinlock {
    CRITICAL_SECTION cs;
};

static inline void spinlock_init(struct spinlock *lock) {
    InitializeCriticalSectionAndSpinCount(&lock->cs, 4000);
}

static inline void spinlock_lock(struct spinlock *lock) {
    EnterCriticalSection(&lock->cs);
}

static inline int spinlock_trylock(struct spinlock *lock) {
    return TryEnterCriticalSection(&lock->cs);
}

static inline void spinlock_unlock(struct spinlock *lock) {
    LeaveCriticalSection(&lock->cs);
}

static inline void spinlock_destroy(struct spinlock *lock) {
    DeleteCriticalSection(&lock->cs);
}

#elif defined(USE_PTHREAD_LOCK)

#include <pthread.h>

struct spinlock {
    pthread_mutex_t lock;
};

static inline void spinlock_init(struct spinlock *lock) {
    pthread_mutex_init(&lock->lock, NULL);
}
static inline void spinlock_lock(struct spinlock *lock) {
    pthread_mutex_lock(&lock->lock);
}
static inline int spinlock_trylock(struct spinlock *lock) {
    return pthread_mutex_trylock(&lock->lock) == 0;
}
static inline void spinlock_unlock(struct spinlock *lock) {
    pthread_mutex_unlock(&lock->lock);
}
static inline void spinlock_destroy(struct spinlock *lock) {
    pthread_mutex_destroy(&lock->lock);
}

#else
/* GCC/Clang with atomics */
#include "atomic.h"

#ifdef __STDC_NO_ATOMICS__

#define atomic_flag_ int
#define ATOMIC_FLAG_INIT_ 0
#define atomic_flag_test_and_set_(ptr) __sync_lock_test_and_set(ptr, 1)
#define atomic_flag_clear_(ptr) __sync_lock_release(ptr)

struct spinlock {
    atomic_flag_ lock;
};

static inline void spinlock_init(struct spinlock *lock) {
    atomic_flag_ v = ATOMIC_FLAG_INIT_;
    lock->lock = v;
}
static inline void spinlock_lock(struct spinlock *lock) {
    while (atomic_flag_test_and_set_(&lock->lock)) {}
}
static inline int spinlock_trylock(struct spinlock *lock) {
    return atomic_flag_test_and_set_(&lock->lock) == 0;
}
static inline void spinlock_unlock(struct spinlock *lock) {
    atomic_flag_clear_(&lock->lock);
}
static inline void spinlock_destroy(struct spinlock *lock) {
    (void) lock;
}

#else

struct spinlock {
    STD_ atomic_int lock;
};

static inline void spinlock_init(struct spinlock *lock) {
    STD_ atomic_init(&lock->lock, 0);
}
static inline void spinlock_lock(struct spinlock *lock) {
    for (;;) {
        if (!STD_ atomic_exchange_explicit(&lock->lock, 1, STD_ memory_order_acquire))
            return;
        while (STD_ atomic_load_explicit(&lock->lock, STD_ memory_order_relaxed))
            ;
    }
}
static inline int spinlock_trylock(struct spinlock *lock) {
    return !STD_ atomic_load_explicit(&lock->lock, STD_ memory_order_relaxed) &&
        !STD_ atomic_exchange_explicit(&lock->lock, 1, STD_ memory_order_acquire);
}
static inline void spinlock_unlock(struct spinlock *lock) {
    STD_ atomic_store_explicit(&lock->lock, 0, STD_ memory_order_release);
}
static inline void spinlock_destroy(struct spinlock *lock) {
    (void) lock;
}

#endif /* __STDC_NO_ATOMICS__ */

#endif /* _MSC_VER / USE_PTHREAD_LOCK */

#endif /* SKYNET_SPINLOCK_H */
