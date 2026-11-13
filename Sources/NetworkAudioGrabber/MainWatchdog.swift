import Foundation

/// Notices the main thread being held — the window not answering — and says so in the log with
/// how long (a launch once showed a blank window with no controls for ~30 s, which a later sampled
/// launch could not reproduce). A background thread asks the main thread to answer
/// twice a second; an answer more than a second late is logged once it comes. Costs two wake-ups
/// a second and nothing on the main thread beyond an empty block.
final class MainWatchdog {
    private var thread: Thread?

    func start(report: @escaping (TimeInterval) -> Void) {
        guard thread == nil else { return }
        let t = Thread {
            while true {
                let asked = CFAbsoluteTimeGetCurrent()
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                answered.wait()
                let held = CFAbsoluteTimeGetCurrent() - asked
                if held > 1 { DispatchQueue.main.async { report(held) } }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        t.name = "Main-thread watchdog"
        t.qualityOfService = .utility
        t.start()
        thread = t
    }
}
