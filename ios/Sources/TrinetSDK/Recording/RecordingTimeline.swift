// RecordingTimeline.swift — the pure decision logic behind Mp4Writer's
// session start and audio placement, factored out so it can be unit-tested
// without AVFoundation or a camera.
//
//   * SessionStartGate — when to open the AVAssetWriter session. The AAC track
//     must be added BEFORE startWriting(), so the writer waits (briefly) to learn
//     the audio format; cameras without audio fall back to video-only after a
//     short grace window. The session always opens on a keyframe.
//   * AudioRebaser — maps each AAC frame's device timestamp onto the MP4's
//     video timeline (zero = first written video frame), keeps audio PTS
//     strictly increasing, and recovers from a grossly inconsistent audio clock
//     by re-anchoring audio onto the video frames it arrived with.

import Foundation

/// Decides when Mp4Writer may open its session.
struct SessionStartGate: Equatable {
    /// Video frames to wait for an audio format before giving up and opening a
    /// video-only file (~0.5 s at 30 fps).
    static let defaultAudioGraceFrames = 15

    let audioGraceFrames: Int
    /// Video frames seen (with a usable format) while the session was closed.
    private(set) var framesWaited = 0

    init(audioGraceFrames: Int = SessionStartGate.defaultAudioGraceFrames) {
        self.audioGraceFrames = max(0, audioGraceFrames)
    }

    /// True once the grace window has passed without any audio.
    var graceExpired: Bool { framesWaited >= audioGraceFrames }

    /// Call for every video frame that arrives while the session is closed.
    /// Returns true if the session should open with THIS frame (which is then
    /// written as the first sample). Never opens on a non-keyframe; frames that
    /// return false are dropped by the caller.
    mutating func shouldOpen(isKey: Bool, audioFormatKnown: Bool) -> Bool {
        framesWaited += 1
        guard isKey else { return false }
        return audioFormatKnown || framesWaited > audioGraceFrames
    }
}

/// Places AAC frames on the MP4 timeline.
struct AudioRebaser: Equatable {
    /// An audio clock this far from the video clock is treated as unrelated.
    static let maxSkewNs: Int64 = 2_000_000_000
    /// Consecutive post-start frames that would all land before the first
    /// video frame (≈1 s of AAC at 48 kHz) before re-anchoring.
    static let maxConsecutiveNegative = 50

    enum Decision: Equatable {
        case write(relNs: Int64)
        case drop
    }

    /// Added to an audio frame's device time to put it on the video clock.
    /// nil until the first frame is seen.
    private(set) var offsetNs: Int64?
    /// True once audio was re-anchored onto the video timeline.
    private(set) var rebased = false
    /// Set by the call that performed the re-anchor (for one-shot logging).
    private(set) var didRebaseOnLastCall = false
    private var consecutiveNegative = 0
    private(set) var lastRelNs: Int64 = -1

    /// - Parameters:
    ///   - audioNs: the frame's device time (its pts_us × 1000).
    ///   - auSofNs: frame time of the video access unit the audio arrived with
    ///     (same clock as `videoBaseNs`).
    ///   - videoBaseNs: frame time of the first video frame written (MP4 t = 0).
    mutating func place(audioNs: Int64, auSofNs: Int64, videoBaseNs: Int64) -> Decision {
        didRebaseOnLastCall = false
        if offsetNs == nil {
            if abs(audioNs - auSofNs) > Self.maxSkewNs {
                reanchor(audioNs: audioNs, auSofNs: auSofNs)
            } else {
                offsetNs = 0
            }
        }
        var rel = audioNs + offsetNs! - videoBaseNs
        if rel < 0 {
            // Audio that arrived with frames before the first written video
            // frame is ordinary pre-roll: drop it without suspicion. Audio that
            // arrived AFTER recording started but still maps before t = 0 means
            // the clocks disagree; after enough of it, re-anchor.
            if auSofNs >= videoBaseNs {
                consecutiveNegative += 1
                if !rebased && consecutiveNegative >= Self.maxConsecutiveNegative {
                    reanchor(audioNs: audioNs, auSofNs: auSofNs)
                    rel = audioNs + offsetNs! - videoBaseNs
                }
            }
            if rel < 0 { return .drop }
        }
        consecutiveNegative = 0
        guard rel > lastRelNs else { return .drop }   // strictly increasing
        lastRelNs = rel
        return .write(relNs: rel)
    }

    private mutating func reanchor(audioNs: Int64, auSofNs: Int64) {
        offsetNs = auSofNs - audioNs
        rebased = true
        didRebaseOnLastCall = true
        consecutiveNegative = 0
    }
}
