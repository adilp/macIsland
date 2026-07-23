import Foundation
import EventKit
import AppKit

/// The production `MeetingStore` — the **only** EventKit-importing file (Calendar spec
/// §7). It is to `CalendarEngine` what `SystemClock` is to `Clock` and `SystemAudioOutput`
/// is to `AudioOutput`: the real seam the engine is tested *around*, injected in the app
/// and never exercised by the headless suite (which uses `FakeMeetingStore`). Min macOS
/// 14, so only the modern `requestFullAccessToEvents()` path exists (spec §2/§8.2).
///
/// All EventKit→`MeetingEvent` conversion (the `EKEvent` adapter, the calendar
/// `CGColor`→hex, the `LinkParser` call) lives here, keeping `MeetingEvent`/`LinkParser`
/// themselves pure and headless-testable.
@MainActor
public final class EventKitStore: MeetingStore {
    // `EKEventStore` is thread-safe but only annotated `Sendable` in newer SDKs. Under the
    // Xcode 16 / macOS 15 SDK (CI, and most contributors), passing this main-actor-isolated
    // value into the `nonisolated` async `requestFullAccessToEvents()` is a Swift 6 data-race
    // error; `nonisolated(unsafe)` vouches for its thread-safety and compiles on every SDK.
    private nonisolated(unsafe) let store = EKEventStore()
    private var observer: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    public init() {}

    public var authorization: CalendarAuthorization {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied   // denied / restricted / writeOnly / @unknown → inert
        }
    }

    public func requestAccess() async -> Bool {
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            Log.calendar.error("requestFullAccessToEvents failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    public func upcomingMeetings(within horizon: Duration, now: Date) -> [MeetingEvent] {
        let end = now.addingTimeInterval(horizon.timeInterval)
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
            .map(MeetingEvent.init(ekEvent:))
    }

    public func observeChanges(_ onChange: @escaping @MainActor () -> Void) {
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { _ in
            // Delivered on the main queue; hop to the main actor to call the engine.
            Task { @MainActor in onChange() }
        }
        // Waking from sleep is the other moment the meeting set must be re-evaluated: a T-1
        // timer that should have fired while asleep was missed (the core's one-shots run on
        // the suspend-aware uptime clock, which pauses during sleep), and an already-underway
        // meeting needs its Join card surfaced on lid-open. Wake posts on NSWorkspace's own
        // notification centre, not `NotificationCenter.default`.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in onChange() }
        }
    }

    public func stopObserving() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }
}

// MARK: - EventKit → MeetingEvent adapter

private extension MeetingEvent {
    /// Build the pure value from an `EKEvent`: parse the video link from its text fields
    /// and convert the calendar color to a `"#RRGGBB"` hex string, so nothing EventKit-
    /// or SwiftUI-shaped escapes into the domain value.
    init(ekEvent e: EKEvent) {
        self.init(
            id: e.eventIdentifier ?? UUID().uuidString,
            title: e.title ?? "Untitled",
            startDate: e.startDate,
            endDate: e.endDate,
            calendarName: e.calendar.title,
            tint: MeetingEvent.hex(from: e.calendar.cgColor),
            videoLink: LinkParser.extractVideoLink(
                notes: e.notes,
                location: e.location,
                url: e.url?.absoluteString))
    }

    /// A `CGColor` as `"#RRGGBB"` (sRGB), or nil if it can't be resolved — the domain
    /// model's `tint` is a hex string, killing the reference's `Color` coupling (spec §4).
    static func hex(from cgColor: CGColor?) -> String? {
        guard let cgColor,
              let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = cgColor.converted(to: srgb, intent: .defaultIntent, options: nil),
              let c = converted.components, c.count >= 3 else { return nil }
        let channel = { (x: CGFloat) in Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channel(c[0]), channel(c[1]), channel(c[2]))
    }
}
