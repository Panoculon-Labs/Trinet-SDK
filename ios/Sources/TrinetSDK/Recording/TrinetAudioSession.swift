// TrinetAudioSession.swift — one serial queue for every AVAudioSession /
// AVAudioEngine call.
//
// `setCategory`, `setActive` and `AVAudioEngine.start/stop` are synchronous
// round trips to the audio server. They routinely take 100 ms – 1 s, longer
// when another app holds audio or the route is changing, and Apple advises
// against making them on the main thread. Making them from the main actor is
// what froze the UI when Record was tapped (keep-alive start) and again on stop
// (keep-alive deactivate). Everything audio-session related in the SDK — and
// the app's own playback session setup — goes through this queue, which also
// keeps a category change from interleaving with an activation.

import AVFoundation
import Foundation

public enum TrinetAudioSession {
    /// The queue all audio-session / audio-engine work runs on.
    public static let queue = DispatchQueue(label: "com.panoculon.trinet.audiosession",
                                            qos: .userInitiated)

    /// Run `work` on the audio-session queue. Returns immediately; never call
    /// AVAudioSession's blocking methods on the main thread.
    public static func perform(_ name: StaticString = "audio.session",
                               _ work: @escaping @Sendable (AVAudioSession) -> Void) {
        queue.async {
            let iv = TrinetDiagnostics.begin(name)
            defer { iv.end() }
            work(AVAudioSession.sharedInstance())
        }
    }

    /// Block until everything queued so far has run. For tests; never call it
    /// on the main thread in an app.
    static func waitUntilIdle() { queue.sync {} }
}
