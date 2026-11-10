import Foundation
import UIKit

/// A sideloaded app signed with a free Apple ID stops opening after 7 days. This reads the app's own
/// provisioning profile to know when, so AnyWhere can warn a day ahead and send the person to SideStore,
/// which refreshes it on the iPhone (no computer), by itself in the background or from a Shortcuts
/// automation.
enum SigningStatus {
    /// When this install's signing runs out. Nil for App Store / TestFlight builds, the Simulator, or a
    /// profile that can't be read.
    static let expiry: Date? = readExpiry()

    static var daysLeft: Int? {
        guard let expiry else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: expiry).day
    }

    /// Two days or less: worth a notice on the main card.
    static var isEndingSoon: Bool {
        guard let expiry else { return false }
        return expiry.timeIntervalSinceNow < 2 * 24 * 3600
    }

    /// "Signed until Fri 14 Nov, 9:41 · 3 days left".
    static var summary: String? {
        guard let expiry else { return nil }
        let date = expiry.formatted(date: .abbreviated, time: .shortened)
        guard let days = daysLeft else { return "Signed until \(date)" }
        if expiry < Date() { return "Signing ended \(date)" }
        let left = days < 1 ? "less than a day left" : days == 1 ? "1 day left" : "\(days) days left"
        return "Signed until \(date) · \(left)"
    }

    private static func readExpiry() -> Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        // The profile is a signed (CMS) envelope with a plain XML plist inside.
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let xml = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any] else {
            return nil
        }
        return plist["ExpirationDate"] as? Date
    }
}

/// SideStore installs and refreshes sideloaded apps on the iPhone itself, with the same pairing file and
/// LocalDevVPN that AnyWhere's iPhone-only mode uses. Links from its URL handler
/// (SideStore/SideStore, SideStore/DeepLinks/URLHandler.swift).
@MainActor
enum SideStore {
    /// AnyWhere's source: SideStore checks it for updates and installs them. Each release publishes it.
    static let sourceURL = "https://github.com/renyifan2009-hash/iOS-GPS-Spoofer-V1.2.3/releases/latest/download/source.json"
    static let website = URL(string: "https://sidestore.io")!

    static var isInstalled: Bool { UIApplication.shared.canOpenURL(URL(string: "sidestore://")!) }

    /// Add AnyWhere's source to SideStore, so new versions show up there.
    static func addSource() {
        var components = URLComponents(string: "sidestore://source")!
        components.queryItems = [URLQueryItem(name: "url", value: sourceURL)]
        guard let url = components.url else { return }
        UIApplication.shared.open(url) { opened in
            if !opened { UIApplication.shared.open(website) }
        }
    }

    /// Open SideStore (to tap Refresh All).
    static func open() {
        UIApplication.shared.open(URL(string: "sidestore://")!) { opened in
            if !opened { UIApplication.shared.open(website) }
        }
    }

    /// Ask SideStore for this iPhone's pairing file. SideStore answers with
    /// `anywhere://pairingFile?data=<base64>` (a newer SideStore feature; older ones ignore it).
    static func requestPairingFile() {
        UIApplication.shared.open(URL(string: "sidestore://pairing?urlname=anywhere")!) { opened in
            if !opened { UIApplication.shared.open(website) }
        }
    }
}
