import Foundation

private final class MainActorResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    func set(_ value: T) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
}

/// Run `body` on the main actor and hand its value back to a synchronous caller.
///
/// The REST / MCP / MDXP servers invoke handlers on private `DispatchQueue`s,
/// while `DownloadStore` is `@MainActor @Observable`. Calling store methods
/// straight from those queues races against UI-driven mutations of `tasks`.
/// This helper hops to the main actor and blocks only the *calling* queue, with
/// a bounded wait so a busy main thread cannot wedge a listener forever.
///
/// Do not call it from synchronous work on the main thread that is itself
/// waiting for the server queue — that would be a classic lock inversion. The
/// servers never dispatch back to their queues synchronously from the main
/// actor, so the inversion does not arise here.
public func runOnMainActor<T>(timeout: TimeInterval = 10,
                             _ body: @escaping @Sendable @MainActor () -> T) -> T? {
    if Thread.isMainThread {
        return MainActor.assumeIsolated { body() }
    }
    let box = MainActorResultBox<T>()
    let semaphore = DispatchSemaphore(value: 0)
    Task { @MainActor in
        box.set(body())
        semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
    return box.get()
}
