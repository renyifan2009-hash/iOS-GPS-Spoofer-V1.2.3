import Foundation
import UIKit
import UserNotifications

/// LocalDevVPN routes this iPhone's developer traffic back to itself, which the iPhone-only mode needs.
/// It has links that turn it on or off and then open the app that asked
/// (`localdevvpn://enable?scheme=anywhere` and `localdevvpn://disable?scheme=anywhere`, from its source:
/// jkcoxson/LocalDevVPN, LocalDevVPNApp.swift; StikDebug uses the same). About a second later it opens
/// `anywhere://`, which brings AnyWhere back.
///
/// AnyWhere turns it on when it opens and when Start finds it off, and off when the location is stopped.
/// It can't turn it off when AnyWhere is closed: iOS doesn't let an app open another app from the
/// background, and a held location needs LocalDevVPN on while other apps are in use.
@MainActor
enum LocalDevVPN {
    static let appStore = URL(string: "https://apps.apple.com/app/localdevvpn/id6755608044")!
    static let enable = URL(string: "localdevvpn://enable?scheme=anywhere")!
    static let disable = URL(string: "localdevvpn://disable?scheme=anywhere")!
    static let autoOpenKey = "vpn.autoOpen"
    static let turnOffAtStopKey = "vpn.turnOffAtStop"

    /// Open LocalDevVPN by itself when AnyWhere opens or Start finds the developer connection isn't
    /// there. On unless turned off in Settings.
    static var opensAutomatically: Bool {
        UserDefaults.standard.object(forKey: autoOpenKey) as? Bool ?? true
    }

    /// Turn LocalDevVPN off when the location on this iPhone is stopped. On unless turned off in Settings.
    static var turnsOffAtStop: Bool {
        UserDefaults.standard.object(forKey: turnOffAtStopKey) as? Bool ?? true
    }

    static var isInstalled: Bool {
        UIApplication.shared.canOpenURL(URL(string: "localdevvpn://")!)
    }

    /// When it was last opened by itself: not again within a minute, so a VPN that can't connect
    /// doesn't bounce the person between the two apps.
    private static var lastAutomaticOpen: Date?

    /// AnyWhere turned it on, and hasn't turned it off since, in this run of the app. On cellular data
    /// alone nothing answers even with LocalDevVPN on, so this is the only sign that it is.
    private(set) static var turnedOnHere = false

    /// Turn LocalDevVPN on and come back. Without it installed, its App Store page opens instead.
    static func turnOn() {
        UIApplication.shared.open(enable) { opened in
            if opened { turnedOnHere = true } else { UIApplication.shared.open(appStore) }
        }
    }

    /// Called when AnyWhere comes to the screen, or loses its connection while on it.
    static func turnOnIfNeeded() {
        guard mayOpen else { return }
        if let last = lastAutomaticOpen, Date().timeIntervalSince(last) < 60 { return }
        lastAutomaticOpen = Date()
        turnOn()
    }

    /// Start found nothing answering. The person just tapped Start, so the minute's wait doesn't apply.
    /// Says whether LocalDevVPN was opened. On cellular data alone only if AnyWhere hasn't turned it on
    /// already: it can't answer there anyway, but it has to be on for Airplane Mode to work.
    static func turnOnToStart(cellularOnly: Bool) -> Bool {
        guard mayOpen, !(cellularOnly && turnedOnHere) else { return false }
        lastAutomaticOpen = Date()
        turnOn()
        return true
    }

    /// The location on this iPhone was stopped: turn LocalDevVPN off, unless Settings says not to. Only
    /// while AnyWhere is on screen, since only then can it open LocalDevVPN (a timer's stop may come in
    /// the background).
    static func turnOffAfterStop() {
        guard turnsOffAtStop, isInstalled, UIApplication.shared.applicationState == .active else { return }
        turnedOnHere = false
        UIApplication.shared.open(disable)
    }

    private static var mayOpen: Bool {
        opensAutomatically && isInstalled && UIApplication.shared.applicationState == .active
    }
}

/// Notifications the app posts for itself: the connection dropped while the screen was off, or the
/// signing is about to run out.
@MainActor
enum LocalAlerts {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// The held location lost its connection while AnyWhere wasn't on screen.
    static func connectionLost() {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = "Reconnecting your location"
        content.body = "AnyWhere lost its developer connection and is trying again. If it doesn't come back, "
            + "open AnyWhere to turn LocalDevVPN on."
        content.sound = .default
        post("connection-lost", content, after: 1)
    }

    /// A reminder a day before the app's signing runs out (see `SigningStatus`).
    static func scheduleSigningReminder(expiry: Date?) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["signing-expiry"])
        guard let expiry else { return }
        let when = expiry.addingTimeInterval(-24 * 3600).timeIntervalSinceNow
        guard when > 60 else { return }
        let content = UNMutableNotificationContent()
        content.title = "Refresh AnyWhere today"
        content.body = "Its signing ends tomorrow. Open SideStore and tap Refresh All so it keeps opening."
        content.sound = .default
        post("signing-expiry", content, after: when)
    }

    private static func post(_ id: String, _ content: UNNotificationContent, after seconds: TimeInterval) {
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}
