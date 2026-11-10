import SwiftUI

/// SpoofRemote: the iPhone app for AnyWhere. Either the Mac holds the
/// simulated location (via Apple's developer location service) and this app
/// tells it where to go, or, in the iPhone-only mode, this app sets the
/// location itself.
@main
struct SpoofRemoteApp: App {
    @State private var connection = ConnectionManager()
    @State private var locations = LocationController()
    @State private var routeLibrary = RouteLibrary()
    @State private var phone = OnDeviceController()
    @State private var updates = UpdateChecker()
    @State private var licenses = LicenseStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(connection)
                .environment(locations)
                .environment(routeLibrary)
                .environment(phone)
                .environment(updates)
                .environment(licenses)
                .tint(Brand.indigo)
        }
    }
}
