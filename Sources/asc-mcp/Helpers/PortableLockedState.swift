import Foundation

/// Synchronous state lock shared by upload recovery helpers on macOS and Linux.
/// The unchecked conformance is limited to state accessed exclusively under NSLock.
final class PortableLockedState<State: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State

    /// Initialize a platform-independent protected state value.
    /// - Returns: A lock whose state can only be accessed through withLock.
    /// - Throws: Never.
    init(initialState: State) { self.state = initialState }

    /// Access state synchronously while holding the lock; never await inside the closure.
    /// - Returns: The closure's computed value.
    /// - Throws: Any error thrown by the closure.
    func withLock<Result>(_ operation: (inout State) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try operation(&state)
    }
}
