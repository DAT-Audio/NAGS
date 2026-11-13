#if canImport(os)
import os
#endif
#if canImport(WinSDK)
import WinSDK          // the Windows port: SRWLOCK
#endif

/// A lock for the audio thread: held for a few instructions, and
/// it donates priority, so a real-time thread waiting on a network thread cannot be inverted.
/// On the Mac `os_unfair_lock`, as before; Windows: an `SRWLOCK` (also never spins forever and
/// is fair enough at these hold times). Not copyable in use: make one per thing it guards.
public struct AudioLock {
    #if canImport(os)
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    public init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }
    @inline(__always) public func acquire() { os_unfair_lock_lock(lock) }
    @inline(__always) public func release() { os_unfair_lock_unlock(lock) }
    public func free() { lock.deallocate() }
    #elseif os(Windows)
    // A slim reader/writer lock, taken exclusively. It is the lock Windows wants here: a word
    // wide, no allocation of its own, no kernel transition when uncontended, and — as the audio
    // thread needs — it hands the lock on rather than letting a waiter spin.
    private let lock: UnsafeMutablePointer<SRWLOCK>
    public init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: SRWLOCK())
        InitializeSRWLock(lock)
    }
    @inline(__always) public func acquire() { AcquireSRWLockExclusive(lock) }
    @inline(__always) public func release() { ReleaseSRWLockExclusive(lock) }
    public func free() { lock.deallocate() }
    #endif
}
