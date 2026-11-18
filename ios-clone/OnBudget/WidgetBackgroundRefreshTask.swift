import BackgroundTasks
import WidgetKit
import OnBudgetKit

/// Widget background refresh (build 43, owner Nov 17, 2026).
///
/// The widget used to update only when the app was opened or the
/// sync button was tapped. This BGAppRefreshTask fetches fresh
/// numbers in the background when iOS schedules it, writes a new
/// snapshot, and reloads the widget timeline — so the widget shows
/// fresher numbers without the app being opened.
///
/// Timing is iOS's, not ours: the task is requested with an
/// earliestBeginDate ~1 hour out (a hint only), and iOS runs it a
/// few times a day based on usage and battery — sometimes later,
/// sometimes not at all. This is NOT a timer, and nothing here
/// runs on a fixed schedule. The 24 hourly timeline entries stay
/// as the fallback (the widget never goes blank), and the sync
/// button stays as the on-demand path.
///
/// The task is registered once, early, in AppDelegate's
/// didFinishLaunchingWithOptions — registration must happen before
/// the app finishes launching, or iOS never delivers the task.
/// It is (re)scheduled on every launch and every foreground, and
/// again after each run, so the chain keeps going: a missed or
/// failed schedule is repaired the next time the app opens.
enum WidgetBackgroundRefreshTask {
    /// Register the handler with the system. Call once, at launch.
    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: WidgetBackgroundRefresh.taskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else { return }
            // handle is @MainActor (TaskCompleter is main-actor
            // isolated): hop there. The handler already runs on
            // the main queue, so this lands immediately.
            Task { @MainActor in handle(refreshTask) }
        }
    }

    /// Ask iOS to run the task, no earlier than ~1 hour from now.
    /// The date is a hint only — iOS decides when it actually runs.
    /// A failed submit (for example, the identifier missing from
    /// Info.plist) is silent: the next launch or foreground tries
    /// again, and the widget keeps its hourly timeline fallback.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: WidgetBackgroundRefresh.taskIdentifier)
        request.earliestBeginDate = WidgetBackgroundRefresh.nextBeginDate()
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // No retry here — schedule() runs again on the next
            // launch / foreground, which repairs the chain.
        }
    }

    /// Run the task: fetch fresh numbers through the same kit path
    /// the widget's sync button uses, reload the timeline only when
    /// a new snapshot was written (on failure the last snapshot
    /// stands — there is no button state to update, so no reload),
    /// end the task, then schedule the next run.
    /// @MainActor: TaskCompleter is main-actor isolated, so the
    /// handler must construct it on the main actor (run
    /// 44237070772 failed to compile without this — Swift 6 rejects
    /// a main-actor-isolated init from a nonisolated context).
    @MainActor
    private static func handle(_ task: BGAppRefreshTask) {
        // One completion only: the expiration handler and the fetch
        // both end the task, and whichever runs first wins. Both
        // completions run on the main actor, so the flag needs no
        // lock.
        let completer = TaskCompleter(task: task)
        task.expirationHandler = {
            // iOS is about to end the task: report it as failed.
            // The in-flight fetch dies with the process; the last
            // snapshot stands, and the next run is still scheduled
            // below (schedule() runs on every launch / foreground).
            Task { @MainActor in completer.complete(success: false) }
        }
        Task {
            let ok = await WidgetSnapshotRefresher.refreshSnapshot()
            if ok {
                WidgetCenter.shared.reloadAllTimelines()
            }
            await MainActor.run { completer.complete(success: ok) }
            schedule()
        }
    }

    /// Ends a BGTask exactly once, however it finishes.
    @MainActor
    private final class TaskCompleter {
        private let task: BGTask
        private var done = false

        init(task: BGTask) {
            self.task = task
        }

        func complete(success: Bool) {
            guard !done else { return }
            done = true
            task.setTaskCompleted(success: success)
        }
    }
}
