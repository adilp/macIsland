import Foundation
import AppKit

/// The low-level sound seam the `Alerter` drives — "make a sound", with the *policy*
/// (which card, single ring, timeout) owned by the `Alerter` above it and the *sound
/// identity* (which system file) owned by the concrete output below it. This split is
/// what lets the whole alerting layer be verified with **no real audio**: tests inject
/// a spy that records `playOnce`/`startRinging`/`stopRinging`, production injects
/// `SystemAudioOutput` (unified spec §8.1; ticket "asserted at a spy-audio seam").
///
/// `@MainActor` because the `Alerter` it serves is `@MainActor` and every call lands
/// on the card lifecycle.
@MainActor
public protocol AudioOutput: AnyObject {
    /// Play a single system sound once — the `.soundOnce` arrival chime.
    func playOnce()
    /// Begin the looping ring. The `Alerter` guarantees a single global ring channel
    /// (at most one active ring), so this is only called when no ring is playing.
    func startRinging()
    /// Stop the looping ring. Safe (a no-op) when nothing is ringing.
    func stopRinging()
}

/// The production output: **macOS system sounds only** (Apple-only, zero bundle
/// weight — unified spec §8.1), ported from the reference's proven choices. The exact
/// files are swappable build-time craft; the architecture (system sounds, single
/// ring, core-owned) is fixed. Apple frameworks only — `NSSound`.
///
/// Not exercised by the headless suite (real sound needs real audio); it is the seam
/// the `Alerter` is tested *around*, exactly as `SystemClock` is for the `Clock`.
@MainActor
public final class SystemAudioOutput: AudioOutput {
    /// One-shot arrival chime.
    private static let onceURL = URL(fileURLWithPath: "/System/Library/Sounds/Pop.aiff")
    /// Looping ring.
    private static let ringURL = URL(fileURLWithPath: "/System/Library/Sounds/Funk.aiff")

    /// The live looping ring, retained so it can be stopped; `nil` when silent. A
    /// fresh `NSSound` per ring (they aren't reliably re-`play()`able once stopped).
    private var ring: NSSound?

    public init() {}

    public func playOnce() {
        NSSound(contentsOf: Self.onceURL, byReference: true)?.play()
    }

    public func startRinging() {
        ring?.stop()
        let sound = NSSound(contentsOf: Self.ringURL, byReference: true)
        sound?.loops = true
        sound?.play()
        ring = sound
    }

    public func stopRinging() {
        ring?.stop()
        ring = nil
    }
}
