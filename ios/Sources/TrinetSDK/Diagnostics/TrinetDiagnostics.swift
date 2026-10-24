// TrinetDiagnostics.swift — cheap, permanent performance instrumentation.
//
// Two pieces:
//   - Named intervals (`TrinetDiagnostics.begin("record.start")` … `.end()`, or
//     `measure("…") { … }`). Each one is an os_signpost interval (Instruments →
//     Points of Interest, subsystem com.panoculon.trinet) and, if it runs longer
//     than 100 ms, also a log line ("slow: record.start 412 ms (began on main)").
//     Open intervals are tracked so the stall detector can name them.
//   - `MainThreadStallDetector`: a background timer pings the main queue and, if
//     main doesn't answer within the threshold (250 ms by default), logs a
//     "STALL" line naming the intervals in flight, then a second line with the
//     total stall duration and every interval that overlapped it.
//
// Everything logs through os.Logger (subsystem "com.panoculon.trinet",
// category "perf"), so it shows in the Xcode console and in Console.app.
// Signposts cost next to nothing unless Instruments is recording; the slow-log
// only fires on slow intervals; the stall detector only runs when started (the
// demo app starts it in DEBUG builds).

import Foundation
import os

public enum TrinetDiagnostics {
    public static let subsystem = "com.panoculon.trinet"
    static let logger = Logger(subsystem: subsystem, category: "perf")
    static let signposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)

    /// Intervals at least this long are also logged, not just signposted.
    public static let slowIntervalNs: UInt64 = 100_000_000

    /// One in-flight named operation. `end()` exactly once.
    public struct Interval: @unchecked Sendable {
        let name: StaticString
        let state: OSSignpostIntervalState
        let token: Int
        let startNs: UInt64
        let onMain: Bool

        public func end() {
            TrinetDiagnostics.signposter.endInterval(name, state)
            let durNs = monotonicNs() &- startNs
            ActiveOperations.shared.end(token, at: durNs &+ startNs)
            if durNs >= TrinetDiagnostics.slowIntervalNs {
                let n = "\(name)"
                let ms = Int(durNs / 1_000_000)
                let side = onMain ? "main" : "background"
                TrinetDiagnostics.logger.notice(
                    "slow: \(n, privacy: .public) \(ms) ms (began on \(side, privacy: .public))")
            }
        }
    }

    /// Start a named interval (signpost + stall-detector label). Safe from any
    /// thread or actor; pair with `end()` (typically in a `defer`).
    public static func begin(_ name: StaticString) -> Interval {
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval(name, id: id)
        let now = monotonicNs()
        let onMain = Thread.isMainThread
        let token = ActiveOperations.shared.begin("\(name)", at: now, onMain: onMain)
        return Interval(name: name, state: state, token: token, startNs: now, onMain: onMain)
    }

    /// Run `body` inside a named interval.
    @discardableResult
    public static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let iv = begin(name)
        defer { iv.end() }
        return try body()
    }

    /// A single point event in the signpost stream and the log (e.g. "share
    /// sheet presented").
    public static func event(_ name: StaticString, _ detail: String = "") {
        signposter.emitEvent(name)
        let n = "\(name)"
        logger.info("\(n, privacy: .public) \(detail, privacy: .public)")
    }

    static func monotonicNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
}

/// Registry of open intervals (+ a short history of finished ones) so a stall
/// report can say what was running.
final class ActiveOperations: @unchecked Sendable {
    static let shared = ActiveOperations()

    struct Op {
        let name: String
        let startNs: UInt64
        var endNs: UInt64?
        let onMain: Bool
    }

    private let lock = NSLock()
    private var nextToken = 0
    private var open: [Int: Op] = [:]
    private var finished: [Op] = []          // ring of the most recent
    private static let historyLimit = 64

    func begin(_ name: String, at ns: UInt64, onMain: Bool) -> Int {
        lock.withLock {
            nextToken &+= 1
            open[nextToken] = Op(name: name, startNs: ns, endNs: nil, onMain: onMain)
            return nextToken
        }
    }

    func end(_ token: Int, at ns: UInt64) {
        lock.withLock {
            guard var op = open.removeValue(forKey: token) else { return }
            op.endNs = ns
            finished.append(op)
            if finished.count > Self.historyLimit {
                finished.removeFirst(finished.count - Self.historyLimit)
            }
        }
    }

    /// Intervals still open, oldest first.
    func describeOpen(now: UInt64) -> String {
        let ops = lock.withLock { open.values.sorted { $0.startNs < $1.startNs } }
        return Self.describe(ops, now: now)
    }

    /// Recently finished intervals, oldest first (tests / diagnostics).
    func recentlyFinished() -> [Op] {
        lock.withLock { finished }
    }

    /// Every interval (open or finished) that overlapped [from, to].
    func describeOverlapping(from: UInt64, to: UInt64) -> String {
        let ops = lock.withLock { () -> [Op] in
            let all = finished + Array(open.values)
            return all.filter { $0.startNs <= to && ($0.endNs ?? to) >= from }
                      .sorted { $0.startNs < $1.startNs }
        }
        return Self.describe(ops, now: to)
    }

    private static func describe(_ ops: [Op], now: UInt64) -> String {
        if ops.isEmpty { return "none" }
        return ops.map { op in
            let dur = Int(((op.endNs ?? now) &- op.startNs) / 1_000_000)
            let state = op.endNs == nil ? "running" : "done"
            return "\(op.name) [\(op.onMain ? "main" : "bg"), \(state), \(dur) ms]"
        }.joined(separator: ", ")
    }
}

/// Watches the main thread from a background queue and logs whenever it fails
/// to run a trivial block within `thresholdMs`. Start it once (the demo app does
/// so in DEBUG builds); it costs one tiny main-queue block every ~50 ms.
///
/// Console lines (subsystem com.panoculon.trinet, category perf):
///   STALL: main thread blocked ≥ 250 ms — open intervals: …
///   STALL ended: main thread was blocked 1834 ms — intervals during stall: …
public final class MainThreadStallDetector: @unchecked Sendable {
    public static let shared = MainThreadStallDetector()

    private let queue = DispatchQueue(label: "com.panoculon.trinet.stallwatch",
                                      qos: .userInteractive)
    private var timer: DispatchSourceTimer?        // queue only
    private var thresholdNs: UInt64 = 250_000_000  // queue only
    private var pingSentNs: UInt64?                // queue only
    private var pingSeq = 0                        // queue only
    private var stallReported = false              // queue only
    private var stallObserver: (@Sendable (UInt64) -> Void)?   // queue only

    private init() {}

    /// Test hook: called (on the watchdog queue) with the blocked duration in
    /// ns whenever a stall ends.
    func setStallObserver(_ observer: (@Sendable (UInt64) -> Void)?) {
        queue.async { [self] in stallObserver = observer }
    }

    public func start(thresholdMs: Int = 250) {
        queue.async { [self] in
            thresholdNs = UInt64(max(50, thresholdMs)) * 1_000_000
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50),
                       leeway: .milliseconds(10))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
            TrinetDiagnostics.logger.notice("main-thread stall detector on (threshold \(thresholdMs) ms)")
        }
    }

    public func stop() {
        queue.async { [self] in
            timer?.cancel(); timer = nil
            pingSentNs = nil; stallReported = false
        }
    }

    private func tick() {
        let now = TrinetDiagnostics.monotonicNs()
        if let sent = pingSentNs {
            let waited = now &- sent
            if !stallReported, waited >= thresholdNs {
                stallReported = true
                let ms = Int(waited / 1_000_000)
                let ops = ActiveOperations.shared.describeOpen(now: now)
                TrinetDiagnostics.signposter.emitEvent("main.stall")
                TrinetDiagnostics.logger.error(
                    "STALL: main thread blocked ≥ \(ms) ms — open intervals: \(ops, privacy: .public)")
            }
            return
        }
        pingSeq &+= 1
        let seq = pingSeq
        pingSentNs = now
        DispatchQueue.main.async { [weak self] in
            let pongNs = TrinetDiagnostics.monotonicNs()
            guard let self else { return }
            self.queue.async { self.pong(seq, at: pongNs) }
        }
    }

    private func pong(_ seq: Int, at pongNs: UInt64) {
        guard seq == pingSeq, let sent = pingSentNs else { return }
        let blocked = pongNs &- sent
        if stallReported || blocked >= thresholdNs {
            let ms = Int(blocked / 1_000_000)
            let ops = ActiveOperations.shared.describeOverlapping(from: sent, to: pongNs)
            TrinetDiagnostics.logger.error(
                "STALL ended: main thread was blocked \(ms) ms — intervals during stall: \(ops, privacy: .public)")
            stallObserver?(blocked)
        }
        pingSentNs = nil
        stallReported = false
    }
}
