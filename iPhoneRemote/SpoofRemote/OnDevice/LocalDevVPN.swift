import Foundation
import UIKit
import UserNotifications

/// LocalDevVPN routes this iPhone's developer traffic back to itself, which the iPhone-only mode needs.
/// It has a link that turns it on and then opens the app that asked
/// (`localdevvpn://enable?scheme=anywhere`, from its source: jkcoxson/LocalDevVPN, LocalDevVPNApp.swift;
/// StikDebug uses the same). About a second later it opens `anywhere://`, which brings AnyWhere back.
@MainActor
enum LocalDevVPN {
    static let appStore = URL(string: "https://apps.apple.com/app/localdevvpn/id6755608044")!
    static let enable = URL(string: "localdevvpn://enable?scheme=anywhere")!
    static let autoOpenKey = "vpn.autoOpen"

    /// Open LocalDevVPN by itself when AnyWhere opens and the developer connection isn't there.
    /// On unless turned off in Settings.
    static var opensAutomatically: Bool {
        UserDefaults.standard.object(forKey: autoOpenKey) as? Bool ?? true
    }

    static var isInstalled: Bool {
        UIApplication.shared.canOpenURL(URL(string: "localdevvpn://")!)
    }

    /// When it was last opened by itself: not again within a minute, so a VPN that can't connect
    /// doesn't bounce the person between the two apps.
    private static var lastAutomaticOpen: Date?

    /// Turn LocalDevVPN on and come back. Without it installed, its App Store page opens instead.
    static func turnOn() {
        UIApplication.shared.open(enable) { opened in
            if !opened { UIApplication.shared.open(appStore) }
        }
    }

    /// Called when AnyWhere comes to the screen, or loses its connection while on it.
    static func turnOnIfNeeded() {
        guard opensAutomatically, isInstalled, UIApplication.shared.applicationState == .active else { return }
        if let last = lastAutomaticOpen, Date().timeIntervalSince(last) < 60 { return }
        lastAutomaticOpen = Date()
        turnOn()
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
