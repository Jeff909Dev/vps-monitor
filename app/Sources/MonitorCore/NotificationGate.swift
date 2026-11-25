import Foundation

public struct NotificationEvent: Equatable, Sendable {
    public var id: String
    public var title: String
    public var body: String
}

/// Decides which polls deserve a notification: each critical alert once, until it clears; and the server being out of
/// reach once, after three failed polls in a row, until a poll works again.
public struct NotificationGate: Equatable, Sendable {
    public static let failuresBeforeNotice = 3

    /// Critical alerts already announced and still active.
    private var announced: Set<String> = []
    private var failures = 0
    private var unreachableAnnounced = false

    public init() {}

    public mutating func pollSucceeded(host: String, alerts: [Alert], _ s: Strings) -> [NotificationEvent] {
        failures = 0
        unreachableAnnounced = false
        let critical = alerts.filter { $0.level == .critical }
        let fresh = critical.filter { !announced.contains($0.id) }
        // An alert that cleared drops out, so it is announced again if it comes back.
        announced = Set(critical.map(\.id))
        return fresh.map {
            NotificationEvent(id: "alert-\($0.id)", title: s.notifications.alertTitle(host, $0.short), body: $0.sentence)
        }
    }

    public mutating func pollFailed(host: String, error: String, _ s: Strings) -> [NotificationEvent] {
        failures += 1
        guard failures >= Self.failuresBeforeNotice, !unreachableAnnounced else { return [] }
        unreachableAnnounced = true
        return [NotificationEvent(id: "unreachable", title: s.notifications.unreachableTitle(host), body: error)]
    }
}
