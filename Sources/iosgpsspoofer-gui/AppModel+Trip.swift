import PhoneOnlyCore
import Foundation
import SpooferCore

/// Realistic trips: the map data along the route, the trip planner, and the
/// waits at your stops. See docs/design/realistic-trips.md.
extension AppModel {
    enum RoadDataState: Equatable {
        /// Realistic trips are off, or there's no route yet.
        case off
        /// Straight lines between the stops: no roads to look up.
        case needsRoads
        case loading(Double)
        case ready
        case failed(String)
    }

    static let roadDataLoader = OverpassLoader(
        userAgent: "AnyWhere/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")"
            + " (+https://github.com/renyifan2009-hash/iOS-GPS-Spoofer-V1.2.3)",
        cacheDirectory: AppSupport.directory.appendingPathComponent("osm-cache", isDirectory: true))

    /// The route as it plays (closed for loops).
    var playPath: RoutePath { RoutePlayback(path: routePath, loopMode: loopMode).path }

    static func pathKey(_ path: RoutePath) -> String {
        let ends = [path.start, path.end].compactMap { $0 }
            .map { String(format: "%.6f,%.6f", $0.latitude, $0.longitude) }.joined(separator: ";")
        return "\(path.points.count)|\(ends)|\(Int(path.length.rounded()))"
    }

    /// Map data for `path`, if it's been loaded for exactly that path. For a route the iPhone sent to be
    /// driven at the limits, Apple Maps' speed for each leg fills in where OpenStreetMap has no limit (or
    /// couldn't be reached).
    func roadFeatures(for path: RoutePath) -> RoadFeatures {
        var features = roadDataPathKey == Self.pathKey(path) ? roadFeatures : .none
        if followsRemoteLimits {
            features.zones = SpeedZone.merged(primary: features.zones, fallback: remoteLegZones(along: path))
        }
        return features
    }

    /// The map data for the route as it plays has loaded.
    var roadDataReady: Bool { roadDataState == .ready && roadDataPathKey == Self.pathKey(playPath) }

    /// The settings for the route being played or edited.
    /// A route runs on the trip engine when "Drive like a real person" is on, or when one of its stops has a
    /// wait (only the trip engine stops and waits). With the setting off it keeps to the plain speed:
    /// no lights, signs, turns, limits or breaks, just the waits you set.
    var usesTripEngine: Bool { prefs.realisticTrips || waypoints.contains { $0.wait > 0 } }

    func tripSettings(paceFactor: Double = 1) -> TripSettings {
        let top = max(0.1, effectiveRouteSpeed)
        // The iPhone asked for each road at its limit: a car, however slow the speed for unknown roads.
        let atLimits = followsRemoteLimits
        let profile = atLimits ? .drive : MotionProfile.forSpeed(top)
        guard prefs.realisticTrips else {
            return TripSettings(topSpeed: top, profile: profile, trafficLights: false, stopSigns: false,
                                slowForTurns: false, speedLimits: false, breaks: false,
                                speedVariation: prefs.speedVariation, paceFactor: paceFactor)
        }
        // Time-of-day traffic slows driving only (not walking or running), and
        // is re-read from the clock each time settings are rebuilt.
        let traffic = ((remoteTrafficOverride ?? prefs.tripTimeOfDayTraffic) && profile.kind == .drive) ? Congestion.factor(at: Date()) : 1
        return TripSettings(topSpeed: top, profile: profile,
                            trafficLights: prefs.tripTrafficLights, stopSigns: prefs.tripStopSigns,
                            slowForTurns: prefs.tripSlowForTurns, speedLimits: prefs.tripSpeedLimits || atLimits,
                            breaks: prefs.tripBreaks, speedVariation: prefs.speedVariation, paceFactor: paceFactor,
                            trafficFactor: traffic,
                            // A road route without its map data: sharp turns stand in for junctions.
                            guessJunctions: followRoads && !roadDataReady,
                            cruiseAtLimits: atLimits)
    }

    /// Pacing by duration: the time one lap of the planner should take.
    private var targetLapTime: TimeInterval? {
        guard pacing == .time, routeDuration > 0 else { return nil }
        // A one-way trip's wait before leaving comes on top of the duration you set for the drive.
        return (loopMode == .pingPong ? routeDuration * 2 : routeDuration) + departureWait
    }

    /// The wait at the start before a one-way trip leaves (a loop's is a one-off, outside a lap's time).
    var departureWait: TimeInterval { loopMode == .once ? (waypoints.first?.wait ?? 0) : 0 }

    func makeTripPlanner(path: RoutePath, loopMode: LoopMode) -> TripPlanner {
        var planner = TripPlanner(path: path, loopMode: loopMode, settings: tripSettings(),
                                  features: roadFeatures(for: path), waypointStops: waypointStops(along: path))
        if let target = targetLapTime {
            planner.update(settings: tripSettings(paceFactor: planner.fittedPaceFactor(for: target)))
        }
        return planner
    }

    /// A trip controller for the playback as it is now.
    func makeTrip(for playback: RoutePlayback, speed: Double = 0) -> TripController {
        tripPaceKey = paceKey
        return TripController(planner: makeTripPlanner(path: playback.path, loopMode: playback.loopMode),
                              lap: playback.lap, lapDistance: playback.lapDistance, speed: speed)
    }

    /// What the fitted pace depends on.
    var paceKey: String { "\(pacing.rawValue)|\(routeDuration)|\(loopMode.rawValue)" }

    /// The settings to use this tick: today's preferences, keeping the fitted pace
    /// unless the duration changed.
    func liveTripSettings(for trip: TripController) -> TripSettings {
        guard targetLapTime != nil else {
            tripPaceKey = nil   // back to Duration later: fit the pace again
            return tripSettings()
        }
        if tripPaceKey == paceKey { return tripSettings(paceFactor: trip.planner.settings.paceFactor) }
        var probe = trip.planner
        probe.update(settings: tripSettings())
        tripPaceKey = paceKey
        return tripSettings(paceFactor: probe.fittedPaceFactor(for: targetLapTime ?? routeDuration))
    }

    /// Your stops with a wait, by distance along `path`.
    func waypointStops(along path: RoutePath) -> [WaypointStop] {
        guard waypoints.contains(where: { $0.wait > 0 }) else { return [] }
        let distances = RouteMatcher(path: path).distances(ofWaypoints: waypoints.map(\.point))
        return waypoints.indices.compactMap { i in
            guard waypoints[i].wait > 0, i < distances.count else { return nil }
            return WaypointStop(index: i, distance: distances[i], wait: waypoints[i].wait)
        }
    }

    func setWait(_ seconds: TimeInterval, forWaypoint id: UUID) {
        guard let i = waypoints.firstIndex(where: { $0.id == id }) else { return }
        waypoints[i].wait = WaitDuration.clamp(seconds)
    }

    /// Only the waits changed: save them, and tell a playing trip.
    func waitsChanged() {
        saveRouteDraft()
        lapTimeCache = nil
        guard var trip, activity == .routing else { return }
        trip.update(waypointStops: waypointStops(along: trip.planner.path))
        self.trip = trip
    }

    /// Preferences for realistic trips changed (Settings or the route card).
    func tripPreferencesChanged() {
        lapTimeCache = nil
        refreshRoadData()
    }

    // MARK: Map data

    /// Look up traffic lights, signs and speed limits along the route, after
    /// the roads are known. Cheap when nothing changed (the answers are cached).
    func refreshRoadData() {
        lapTimeCache = nil
        // Speed bumps alone are worth a lookup too, but only for driving.
        let wanted = prefs.tripTrafficLights || prefs.tripStopSigns || prefs.tripSpeedLimits
            || (prefs.tripSlowForTurns && travelMode == .driving) || followsRemoteLimits
        guard prefs.realisticTrips, wanted, waypoints.count >= 2, routeGeometry.count >= 2 else {
            roadDataTask?.cancel()
            roadDataState = .off
            return
        }
        guard followRoads else {
            roadDataTask?.cancel()
            roadDataState = .needsRoads
            return
        }
        // Called again once the road route arrives.
        guard directionsState != .computing else { return }
        let path = playPath
        let key = Self.pathKey(path)
        let roads = travelMode == .driving
        if key == roadDataPathKey, roadDataState == .ready, roadDataHasRoads == roads { return }
        let pending = key + (roads ? "|roads" : "")
        if case .loading = roadDataState, roadDataTask != nil, pendingRoadDataKey == pending { return }
        roadDataTask?.cancel()
        if pendingRoadDataKey != pending { roadDataRetries = 3 }
        pendingRoadDataKey = pending
        roadDataState = .loading(0)
        roadDataTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            do {
                let features = try await Self.roadDataLoader.features(along: path, roads: roads) { fraction in
                    Task { @MainActor in
                        let model = AppModel.shared
                        guard case .loading = model.roadDataState else { return }
                        model.roadDataState = .loading(fraction)
                    }
                }
                guard !Task.isCancelled, let self else { return }
                self.roadFeatures = features
                self.roadDataPathKey = key
                self.roadDataHasRoads = roads
                self.roadDataState = .ready
                self.roadDataRetries = 3
                self.lapTimeCache = nil
                self.appendLog(Self.describe(features, length: path.length, wayBack: self.loopMode == .pingPong),
                               level: .info)
                // Some pieces couldn't be checked: try them again later (the rest is cached).
                if !features.complete { self.scheduleRoadDataRetry(for: pending) }
                if var trip = self.trip, Self.pathKey(trip.planner.path) == key {
                    trip.update(features: self.roadFeatures(for: trip.planner.path))
                    self.trip = trip
                }
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), let self else { return }
                self.roadDataState = .failed(Self.describe(error))
                self.appendLog("Couldn't load traffic lights from OpenStreetMap: \(Self.describe(error)).",
                               level: .warning)
                self.scheduleRoadDataRetry(for: pending)
            }
        }
    }

    /// Public map servers are sometimes busy: try again by itself a few times
    /// (after 20 s, 1 min, 2 min) while the route stays the same.
    private func scheduleRoadDataRetry(for key: String) {
        guard roadDataRetries > 0 else { return }
        let delay: Double = [120, 60, 20][min(2, max(0, roadDataRetries - 1))]
        roadDataRetries -= 1
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.pendingRoadDataKey == key else { return }
            switch self.roadDataState {
            case .failed: break
            case .ready where !self.roadFeatures.complete: break
            default: return
            }
            self.roadDataState = .off
            self.refreshRoadData()
        }
    }

    func retryRoadData() {
        roadDataPathKey = nil
        roadDataState = .off
        roadDataRetries = 3
        refreshRoadData()
    }

    static func describe(_ features: RoadFeatures, length: Double, wayBack: Bool = false) -> String {
        let lights = features.uniqueCount(of: .trafficSignal, wayBack: wayBack)
        let signs = features.uniqueCount(of: .stopSign, wayBack: wayBack)
        let bumps = features.uniqueCount(of: .trafficCalming, wayBack: wayBack)
        let coverage = Int((features.speedLimitCoverage(of: length) * 100).rounded())
        var text = "OpenStreetMap: \(lights) traffic light\(lights == 1 ? "" : "s"), "
            + "\(signs) stop sign\(signs == 1 ? "" : "s")"
            + (bumps > 0 ? ", \(bumps) speed bump\(bumps == 1 ? "" : "s")" : "") + " on this route"
        if coverage > 0 { text += ", speed limits for \(coverage)% of it" }
        if !features.complete { text += " (some of the route couldn't be checked)" }
        return text + "."
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed:
                return "no internet connection"
            case .timedOut:
                return "it didn't answer in time"
            default:
                return "couldn't reach it"
            }
        }
        let text = String(describing: error)
        if text.contains("429") || text.contains("503") || text.contains("504") { return "it's busy right now" }
        return text
    }

    /// The lights and signs to show along the route.
    var roadMarkers: [RoadMarker] {
        guard prefs.realisticTrips, mode == .route || activity == .routing, roadDataReady else { return [] }
        var seen = Set<GeoPoint>()
        let wayBack = loopMode == .pingPong
        return roadFeatures.features.compactMap { feature in
            // Signs only for the other direction don't matter unless the route comes back.
            guard wayBack || feature.facing != .backward else { return nil }
            switch feature.kind {
            case .trafficSignal, .signalCrossing: guard prefs.tripTrafficLights else { return nil }
            case .stopSign, .giveWay: guard prefs.tripStopSigns else { return nil }
            case .trafficCalming: guard prefs.tripSlowForTurns, travelMode == .driving else { return nil }
            }
            guard seen.insert(feature.point).inserted else { return nil }
            return RoadMarker(point: feature.point, kind: feature.kind)
        }
    }

    // MARK: Lap time

    /// The expected time for one pass (one lap for loops), with the stops.
    var expectedTripPassTime: TimeInterval? {
        guard usesTripEngine, routeGeometry.count >= 2, effectiveRouteSpeed > 0 else { return nil }
        if pacing == .time { return routeDuration > 0 ? routeDuration + departureWait : nil }
        let key = "\(routeSignature)|\(roadDataPathKey ?? "-")|\(waypoints.map(\.wait))|\(tripSettings())"
        if let cache = lapTimeCache, cache.key == key { return cache.value }
        let lap = makeTripPlanner(path: playPath, loopMode: loopMode).expectedLapTime()
        let value = loopMode == .pingPong ? lap / 2 : lap
        lapTimeCache = (key, value)
        return value
    }
}
