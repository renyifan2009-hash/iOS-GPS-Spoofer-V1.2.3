import PhoneOnlyCore
import Foundation
import RemoteAPI
import SpooferCore
import SpooferRemote

/// What the AnyWhere iPhone app can do to this window: send a route, steer with the joystick, pause, and ask
/// for Auto-stop. `AppRemoteBridge` (RemoteHost.swift) checks the request and calls these.
extension AppModel {
    /// The route the iPhone built replaces the one in the window, waits for its roads (up to 20 seconds, then
    /// goes with straight legs, as the Route tab's Start does), and starts.
    func startRemoteRoute(_ request: RouteRequest) {
        // Before the stops change: their road legs come from the cache, not from asking Apple Maps again.
        remoteRoadPlan = Self.roadPlan(for: request)
        remoteRouteTask?.cancel()
        remoteJoystickMotion = nil
        mode = .route
        remoteTrafficOverride = request.travelMode == "driving" ? request.timeOfDayTraffic : false
        travelMode = TravelMode(rawValue: request.travelMode) ?? .walking
        followRoads = request.followRoads
        loopMode = LoopMode(rawValue: request.loopMode) ?? .once
        pacing = .speed
        routeSpeed = request.speed
        routeName = request.name
        savedRouteID = nil
        waypoints = request.waypoints.map {
            Waypoint(point: GeoPoint($0.latitude, $0.longitude), wait: WaitDuration.clamp($0.wait ?? 0))
        }
        // The same stops as the route before don't ask for roads again by themselves: these may be new ones.
        if remoteRoadPlan?.hasRoads == true { routeInputsChanged() }
        appendLog("iPhone Remote: a \(request.waypoints.count)-point route\(request.name.map { " “\($0)”" } ?? "").", level: .info)
        remoteRouteTask = Task { [weak self] in
            // Road legs come from Apple Maps a moment after the stops are set.
            for _ in 0..<200 {
                guard let self, !Task.isCancelled else { return }
                if self.directionsState != .computing { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let self, !Task.isCancelled else { return }
            self.startRoute()
            self.remoteRouteTask = nil
        }
    }

    /// The roads the iPhone sent go into the directions cache (a leg it had none for is asked for here, as
    /// before), and its wishes for the speed are kept for the trip.
    static func roadPlan(for request: RouteRequest) -> RemoteRoadPlan {
        let stops = request.waypoints.map { GeoPoint($0.latitude, $0.longitude) }
        var cruise: [Double?] = []
        if RoadRoute(request: request) != nil, let legs = request.usableLegs {
            let mode = TravelMode(rawValue: request.travelMode) ?? .walking
            let ends = legs.count == stops.count ? stops + [stops[0]] : stops   // a loop's way back
            for (i, leg) in legs.enumerated() {
                guard let leg else { cruise.append(nil); continue }
                let points = leg.points.map { GeoPoint($0.latitude, $0.longitude) }
                DirectionsService.shared.prime(from: ends[i], to: ends[i + 1], mode: mode, points: points)
                cruise.append(leg.expectedSeconds.flatMap {
                    SpeedZone.cruise(meters: leg.meters ?? Geo.length(of: points), expectedSeconds: $0)
                })
            }
        }
        return RemoteRoadPlan(stops: stops, followRoads: request.followRoads,
                              travelMode: TravelMode(rawValue: request.travelMode) ?? .walking,
                              realistic: request.realistic, followLimits: RouteRunner.followsLimits(request),
                              hasRoads: RoadRoute(request: request) != nil, legCruise: cruise)
    }

    /// The iPhone's plan, while the window still has the route it sent (its stops, roads and travel).
    var activeRemoteRoadPlan: RemoteRoadPlan? {
        guard let plan = remoteRoadPlan, plan.stops == waypoints.map(\.point), plan.followRoads == followRoads,
              plan.travelMode == travelMode else { return nil }
        return plan
    }

    /// "Drive like a real person": as the iPhone asked for the route it sent, otherwise the Mac's own setting.
    var realisticTrips: Bool { activeRemoteRoadPlan?.realistic ?? prefs.realisticTrips }

    /// Drive each road at about its limit, as the iPhone asked.
    var followsRemoteLimits: Bool { activeRemoteRoadPlan?.followLimits == true && travelMode == .driving }

    /// Apple Maps' speed for each leg as stretches of `path`, for where OpenStreetMap knows no limit.
    func remoteLegZones(along path: RoutePath) -> [SpeedZone] {
        guard let plan = activeRemoteRoadPlan, plan.legCruise.contains(where: { $0 != nil }) else { return [] }
        var ends = RouteMatcher(path: path).distances(ofWaypoints: plan.stops)
        if plan.legCruise.count > ends.count - 1 { ends.append(path.length) }   // a loop's way back
        return SpeedZone.legs(ends: ends, speeds: plan.legCruise)
    }

    /// A route from the iPhone is being planned: its roads are loading, it has not started yet.
    var remoteRoutePlanning: Bool { remoteRouteTask != nil && activity != .routing }

    /// Steering from the iPhone's joystick. The location must already be held.
    func steerFromPhone(_ request: JoystickRequest) {
        if activity != .joystick {
            remoteRouteTask?.cancel()
            remoteRouteTask = nil
            takeJoystickControl()
        }
        remoteJoystickMotion = JoystickMotion(request, receivedAt: Date())
    }

    /// Auto-stop for this session only, as the iPhone asked. The Mac's own saved setting is not changed.
    func armAutoStopFromPhone(minutes: Int) {
        let wanted = Killswitch.sanitize(minutes: minutes)
        armKillswitch(minutes: wanted)
        appendLog(wanted > 0 ? "iPhone Remote: Auto-stop after \(Killswitch.label(minutes: wanted))."
                             : "iPhone Remote: Auto-stop off.", level: .info)
    }
}

/// How the iPhone wants the route it sent driven.
struct RemoteRoadPlan: Equatable {
    /// The route's stops, roads and travel, to tell whether the window still has it.
    var stops: [GeoPoint]
    var followRoads: Bool
    var travelMode: TravelMode
    /// "Drive like a real person" on the iPhone.
    var realistic: Bool
    /// Each road at about its limit, the speed only where none is known.
    var followLimits: Bool
    /// The iPhone sent roads for it (put into the directions cache).
    var hasRoads: Bool
    /// Apple Maps' typical speed for each leg (the way back last, for a loop), m/s; nil where it had none.
    var legCruise: [Double?]
}
