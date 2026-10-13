import Foundation
#if canImport(BackgroundTasks) && os(iOS)
import BackgroundTasks

/// The agent's scheduled notes on iOS while the app is not running: one `BGAppRefreshTaskRequest`
/// at the earliest note (`earliestBeginDate`), replaced at each change and withdrawn when none is
/// pending. iOS decides when it runs, possibly late or never for a rarely used app; the next
/// foreground delivers what it missed. No permission prompt, no notification.
///
/// App setup (Xcode): add `identifier` to `BGTaskSchedulerPermittedIdentifiers` in Info.plist,
/// enable Background Modes > Background fetch, and call `registerHandler` before
/// `application(_:didFinishLaunchingWithOptions:)` returns. Without the Info.plist entry a request
/// is refused, and the Runtime reports `schedule.degraded` with reason `not_configured`.
public final class AppRefreshScheduler: RuntimeScheduler, @unchecked Sendable {
    public let identifier: String
    public init(identifier: String) { self.identifier = identifier }

    public func schedule(earliest: Date) throws {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = earliest
        do { try BGTaskScheduler.shared.submit(request) }
        catch let error as BGTaskScheduler.Error where error.code == .notPermitted {
            throw CrocheError("not_configured", "Add \(identifier) to BGTaskSchedulerPermittedIdentifiers and enable Background fetch")
        } catch let error as BGTaskScheduler.Error where error.code == .unavailable {
            throw CrocheError("background_unavailable", "Background App Refresh is off or unavailable here")
        } catch {
            throw CrocheError("schedule_failed", "BGTaskScheduler refused the request")
        }
    }
    public func cancel() { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }

    /// One open Runtime per identifier: a run delivers through the one Runtime its identifier
    /// names (Atlas, #323 P1-2). This scheduler object is no exception: `create` attaches once per
    /// Runtime, so a second attach while the identifier is held is refused, whoever holds it
    /// (Atlas, #323 at dc38bf0). Close-and-reuse stays valid.
    public func attach() throws { try Self.claims.claim(identifier, by: self) }
    public func detach() { Self.claims.release(identifier, by: self) }
    private static let claims = SchedulerClaims(what: "task identifier")

    /// Registers what runs when iOS launches the task: `runtime` returns the app's Runtime
    /// (opening it when the app was launched for this task), whose `deliverDue()` then runs. When
    /// iOS ends the background time first, the delivery turn is cancelled and its notes stay
    /// pending. Call once, before `application(_:didFinishLaunchingWithOptions:)` returns.
    @discardableResult
    public func registerHandler(runtime: @escaping @Sendable () async throws -> CrocheRuntime) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            let granted = GrantedTask(task)
            let delivery = BackgroundDelivery(open: runtime)
            task.expirationHandler = { delivery.expire() }
            delivery.start { success in granted.task.setTaskCompleted(success: success) }
        }
    }
}

private final class GrantedTask: @unchecked Sendable {
    let task: BGTask
    init(_ task: BGTask) { self.task = task }
}
#endif
