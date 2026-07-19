import Foundation
@testable import MacIslandCore

// MARK: - FakeMeetingStore

/// The in-memory `MeetingStore` seam (ticket criterion 1: "with a fake `EventStore`
/// + injected clock"). A test sets the meeting list and authorization, drives change
/// events with `triggerChange`, and awaits the first fetch deterministically with
/// `awaitFetch` — so the whole `CalendarEngine`/`CalendarSource` chain is exercised
/// with **no EventKit and no wall-clock waits**, exactly as `SpyAudio` does for sound
/// and `TestConnection` for the socket.
@MainActor
final class FakeMeetingStore: MeetingStore {
    private var _authorization: CalendarAuthorization
    /// Whether `requestAccess()` grants (flips to `.authorized`) or denies.
    var grantOnRequest: Bool
    /// The events the store "contains"; `upcomingMeetings` returns those overlapping
    /// the look-ahead window (EventKit's overlap semantics), all-day excluded by the
    /// caller's construction.
    var meetings: [MeetingEvent]

    private(set) var authReadCount = 0
    private(set) var requestAccessCount = 0
    private(set) var fetchCount = 0
    private var onChange: (@MainActor () -> Void)?
    private var fetchWaiters: [(count: Int, cont: CheckedContinuation<Void, Never>)] = []
    private var authWaiters: [(count: Int, cont: CheckedContinuation<Void, Never>)] = []
    private var requestWaiters: [(count: Int, cont: CheckedContinuation<Void, Never>)] = []

    init(
        meetings: [MeetingEvent] = [],
        authorization: CalendarAuthorization = .authorized,
        grantOnRequest: Bool = true
    ) {
        self.meetings = meetings
        self._authorization = authorization
        self.grantOnRequest = grantOnRequest
    }

    /// Reading auth is the first store touch on *every* bootstrap path, so counting it
    /// gives a deterministic "bootstrap has run at least to the auth check" signal —
    /// the one the inert (`.denied`) path needs (it makes no other store call).
    var authorization: CalendarAuthorization {
        authReadCount += 1
        authWaiters.removeAll { if authReadCount >= $0.count { $0.cont.resume(); return true }; return false }
        return _authorization
    }

    func requestAccess() async -> Bool {
        _authorization = grantOnRequest ? .authorized : .denied
        requestAccessCount += 1
        requestWaiters.removeAll { if requestAccessCount >= $0.count { $0.cont.resume(); return true }; return false }
        return grantOnRequest
    }

    func upcomingMeetings(within horizon: Duration, now: Date) -> [MeetingEvent] {
        fetchCount += 1
        fetchWaiters.removeAll { if fetchCount >= $0.count { $0.cont.resume(); return true }; return false }
        let end = now.addingTimeInterval(horizon.timeInterval)
        // Overlap [now, end): future + in-progress events, past events dropped.
        return meetings
            .filter { $0.startDate < end && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
    }

    func observeChanges(_ onChange: @escaping @MainActor () -> Void) { self.onChange = onChange }
    func stopObserving() { onChange = nil }

    // --- Test drivers ---

    /// Simulate an `EKEventStoreChanged` edit: optionally swap the meeting set, then
    /// fire the observer (→ engine re-fetch + reschedule).
    func triggerChange(meetings: [MeetingEvent]? = nil) {
        if let meetings { self.meetings = meetings }
        onChange?()
    }

    /// Await the store's first fetch — the deterministic "the source's `start` ran and
    /// scheduled" signal for the authorized / granted paths (register spawns `start` in
    /// a Task, so a test can't assume it ran synchronously).
    func awaitFetch(count: Int = 1) async {
        if fetchCount >= count { return }
        await withCheckedContinuation { fetchWaiters.append((count, $0)) }
    }

    /// Await the first auth read — the signal the inert `.denied` path needs.
    func awaitBootstrap(count: Int = 1) async {
        if authReadCount >= count { return }
        await withCheckedContinuation { authWaiters.append((count, $0)) }
    }

    /// Await the first `requestAccess` — for the `.notDetermined` → denied path.
    func awaitRequestAccess(count: Int = 1) async {
        if requestAccessCount >= count { return }
        await withCheckedContinuation { requestWaiters.append((count, $0)) }
    }
}

// MARK: - MeetingEvent builders

extension MeetingEvent {
    /// A test meeting. `start` is required; the rest default to a plausible 30-minute
    /// non-video "Standup" on the "Work" calendar.
    static func make(
        id: String = "evt-1",
        title: String = "Standup",
        start: Date,
        durationMinutes: Double = 30,
        calendarName: String = "Work",
        tint: String? = "#FF3B30",
        videoLink: VideoLink? = nil
    ) -> MeetingEvent {
        MeetingEvent(
            id: id,
            title: title,
            startDate: start,
            endDate: start.addingTimeInterval(durationMinutes * 60),
            calendarName: calendarName,
            tint: tint,
            videoLink: videoLink
        )
    }
}

extension VideoLink {
    /// A Google Meet link for test meetings.
    static let meet = VideoLink(url: URL(string: "https://meet.google.com/abc-defg-hij")!, type: .googleMeet)
}
