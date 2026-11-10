import Foundation
import MapKit
import Observation
import PhoneOnlyCore
import RemoteAPI

/// All GPS commands go to OnDeviceController, never to ConnectionManager or a remote computer.
@MainActor
@Observable
final class PhoneMotionController: ControlTarget {
    let phone: OnDeviceController
    var executionName: String { "iPhone" }
    private(set) var activity = "hold"
    private(set) var progress = 0.0
    private(set) var paused = false
    private(set) var speed = 0.0
    private(set) var deadline: Date?
    private(set) var lastError: String?
    private(set) var planning = false
    /// While a route stands at one of its stops: which, and for how long (shown as "Leaving in 29:41").
    private(set) var routeWait: RouteWait?
    /// The exact place being held. With the GPS wobble on, `phone.current` wanders a few metres around it.
    private(set) var anchor: CLLocationCoordinate2D?
    private var heading = 0.0
    private var input = JoystickInput.idle
    private var inputAt = Date.distantPast
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var directions: MKDirections?
    @ObservationIgnored private let now: @Sendable () -> Date

    init(phone: OnDeviceController, now: @escaping @Sendable () -> Date = { Date() }) {
        self.phone = phone
        self.now = now
    }

    var isSpoofing: Bool { phone.isSpoofing }
    var isWorking: Bool { planning || phone.isWorking }
    var status: RemoteStatus? {
        RemoteStatus(connected: phone.isSetUp, spoofing: phone.isSpoofing,
                     latitude: phone.current?.latitude, longitude: phone.current?.longitude,
                     placeName: phone.currentName,
                     phase: phone.phase == .stopping ? .stopping : (isWorking ? .starting : (isSpoofing ? .active : .idle)),
                     serverName: "This iPhone", activity: planning ? "planning" : activity,
                     speed: speed, heading: heading, routeProgress: activity == "route" ? progress : nil,
                     routePaused: paused, autoStopAt: deadline?.timeIntervalSince1970,
                     routeWait: activity == "route" ? routeWait : nil)
    }

    @discardableResult
    func start(at coordinate: CLLocationCoordinate2D, name: String?, joystick: Bool = false) async -> Bool {
        guard !isWorking else { return false }
        cancelMotion()
        let token = generation
        // Move straight to the new place. Stopping first would put the real location back on the iPhone
        // until the new one is set: seconds, or longer if the connection has to be made again.
        guard await settle(), token == generation else { return false }
        guard await phone.set(coordinate, name: name), token == generation else { return false }
        activity = joystick ? "joystick" : "hold"
        anchor = joystick ? nil : coordinate
        lastError = nil
        if joystick {
            runJoystick(token: token)
        } else {
            holdNaturally(at: StandaloneRoute.Point(coordinate.latitude, coordinate.longitude), token: token)
        }
        return true
    }

    func steer(heading: Double, speed: Double) async -> String? {
        guard !isWorking else { return "Wait for this iPhone to finish starting or stopping." }
        guard phone.isSpoofing else { return "Start the location on this iPhone first." }
        guard heading.isFinite, speed.isFinite, (0...JoystickInput.maxSpeed).contains(speed) else {
            return "That direction or speed isn't valid."
        }
        if activity != "joystick" {
            cancelMotion()
            activity = "joystick"
            runJoystick(token: generation)
        }
        input = JoystickInput(heading: JoystickInput.wrap(heading), speed: speed)
        inputAt = Date()
        self.heading = input.heading
        return nil
    }

    /// Release the thumb immediately when the app becomes inactive. Held locations and routes
    /// retain their background session; joystick motion never continues after the UI disappears.
    func releaseJoystick() { input = .idle; speed = 0 }

    private func runJoystick(token: Int) {
        runner = Task { [weak self] in
            var previous = ContinuousClock.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, token == self.generation, self.phone.isSpoofing else { return }
                let now = ContinuousClock.now
                let dt = min(0.5, max(0, previous.duration(to: now).seconds))
                previous = now
                // While the connection is coming back, the heartbeat does the reconnecting.
                guard !self.phone.isUpdatingLocation, !self.phone.isReconnecting else { continue }
                let speed = Date().timeIntervalSince(self.inputAt) <= RemoteAPI.joystickTimeout ? self.input.speed : 0
                self.speed = speed
                guard speed > 0, let current = self.phone.current else { continue }
                let moved = PhoneGeo.moved(latitude: current.latitude, longitude: current.longitude,
                                           meters: speed * dt, bearing: self.input.heading)
                guard await self.phone.set(CLLocationCoordinate2D(latitude: moved.latitude, longitude: moved.longitude),
                                          name: "Joystick"), token == self.generation else {
                    if token == self.generation, self.phone.isReconnecting { self.speed = 0; continue }
                    if token == self.generation { self.lastError = self.phone.lastError; self.speed = 0 }
                    return
                }
            }
        }
    }

    @discardableResult
    func driveRoute(_ request: RouteRequest) async -> Bool {
        guard !isWorking, request.isValid, request.waypoints.count <= SavedRoute.maxStops else { return false }
        cancelMotion()
        let token = generation
        planning = true
        defer { if token == generation { planning = false } }
        // Plan first, while the place being held stays held; then move to the route's start. (Stopping first
        // would show the real location for as long as the road directions take.)
        do {
            var waypoints = request.waypoints
            if request.loopMode == "loop", let first = waypoints.first, let last = waypoints.last,
               first.latitude != last.latitude || first.longitude != last.longitude {
                waypoints.append(.init(latitude: first.latitude, longitude: first.longitude))
            }
            var legs: [[StandaloneRoute.Point]] = []
            for index in 1..<waypoints.count {
                guard token == generation else { return false }
                let a = StandaloneRoute.Point(waypoints[index - 1].latitude, waypoints[index - 1].longitude)
                let b = StandaloneRoute.Point(waypoints[index].latitude, waypoints[index].longitude)
                if request.followRoads, StandaloneRoute.distance(a, b) > 0.01 {
                    let leg = try await roadLeg(from: a, to: b, driving: request.travelMode == "driving")
                    guard token == generation else { return false }
                    legs.append(leg)
                } else { legs.append([a, b]) }
            }
            let route = try StandaloneRoute(legs: legs, waits: waypoints.map { $0.wait ?? 0 },
                                            speed: request.speed, repeatMode: request.loopMode)
            guard token == generation else { return false }
            let first = route.start
            guard await settle(), token == generation else { return false }
            guard await phone.set(.init(latitude: first.latitude, longitude: first.longitude), name: request.name),
                  token == generation else { return false }
            activity = "route"; progress = 0; paused = false; lastError = nil; anchor = nil
            runRoute(route, natural: request.realistic, driving: request.travelMode == "driving", token: token)
            return true
        } catch {
            if token == generation { lastError = "Couldn't plan this route on the iPhone: \(error.localizedDescription)" }
            return false
        }
    }

    private func roadLeg(from a: StandaloneRoute.Point, to b: StandaloneRoute.Point, driving: Bool) async throws -> [StandaloneRoute.Point] {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: .init(latitude: a.latitude, longitude: a.longitude)))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: .init(latitude: b.latitude, longitude: b.longitude)))
        request.transportType = driving ? .automobile : .walking
        let directions = MKDirections(request: request)
        self.directions = directions
        defer { self.directions = nil }
        // Older MapKit SDKs return a non-Sendable Response from the async overlay. Convert it
        // inside the completion callback so only our Sendable points cross back to the actor.
        return try await withCheckedThrowingContinuation { continuation in
            directions.calculate { response, error in
                if let error { continuation.resume(throwing: error); return }
                guard let polyline = response?.routes.first?.polyline, polyline.pointCount >= 2,
                      polyline.pointCount <= 100_000 else {
                    continuation.resume(throwing: StandaloneRoute.Problem.invalid)
                    return
                }
                var coordinates = [CLLocationCoordinate2D](repeating: .init(), count: polyline.pointCount)
                polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: polyline.pointCount))
                // Explicit endpoints preserve the chosen stops and continuity between legs.
                continuation.resume(returning: [a] + coordinates.map { StandaloneRoute.Point($0.latitude, $0.longitude) } + [b])
            }
        }
    }

    /// Play the route. With `natural` on (Drive like a real person) the car eases off and on, slows for
    /// corners, stops at some lights and signs, and the GPS wobbles a few metres like a real phone's;
    /// off, it keeps to the selected speed on a clean line.
    private func runRoute(_ route: StandaloneRoute, natural: Bool, driving: Bool, token: Int) {
        runner = Task { [weak self] in
            var drive = NaturalDrive(route: route, driving: driving)
            var wobble = GPSWobble(size: natural ? (driving ? 3.5 : 3) : 0)
            var elapsed = 0.0
            var previous = ContinuousClock.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, token == self.generation, self.phone.isSpoofing else { return }
                let now = ContinuousClock.now
                let dt = min(0.5, max(0, previous.duration(to: now).seconds))
                previous = now
                // Paused, or the connection is coming back (the heartbeat reconnects): time stands still.
                guard !self.paused, !self.phone.isUpdatingLocation, !self.phone.isReconnecting else {
                    self.speed = 0
                    continue
                }
                // Worked out on a copy, and kept only once the iPhone has the point: a move that fails
                // while the connection comes back mustn't skip the car ahead.
                var trial = drive
                let step = natural ? trial.advance(dt: dt)
                    : NaturalDrive.Step(elapsed: elapsed + dt, speed: route.speed, reason: nil, remaining: nil)
                let sample = route.sample(at: step.elapsed)
                let shown = wobble.apply(latitude: sample.point.latitude, longitude: sample.point.longitude, dt: dt)
                guard await self.phone.set(.init(latitude: shown.latitude, longitude: shown.longitude),
                                          name: self.phone.currentName), token == self.generation else {
                    if token == self.generation, self.phone.isReconnecting { self.speed = 0; continue }
                    if token == self.generation { self.lastError = self.phone.lastError; self.speed = 0 }
                    return
                }
                drive = trial
                elapsed = step.elapsed; self.progress = sample.progress
                self.speed = sample.moving && step.reason == nil ? step.speed : 0
                let wait: RouteWait?
                if let stop = route.waiting(at: step.elapsed) {
                    wait = RouteWait(reason: "stop", stop: stop.stop, remaining: stop.remaining)
                } else if let reason = step.reason {
                    wait = RouteWait(reason: reason, remaining: step.remaining)
                } else {
                    wait = nil
                }
                if wait != self.routeWait { self.routeWait = wait }
                if sample.finished {
                    self.activity = "hold"; self.speed = 0; self.routeWait = nil
                    self.anchor = CLLocationCoordinate2D(latitude: sample.point.latitude, longitude: sample.point.longitude)
                    if natural { self.holdNaturally(at: sample.point, token: token) }
                    return
                }
            }
        }
    }

    /// GPS wobble while a place is held, so it doesn't sit on one exact point like a pin: a phone
    /// standing still still wanders a few metres. Off in Settings, the point stays exact.
    private func holdNaturally(at point: StandaloneRoute.Point, token: Int) {
        guard NaturalSettings.holdWobble else { return }
        runner = Task { [weak self] in
            var wobble = GPSWobble(size: 2.2)
            var previous = ContinuousClock.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, token == self.generation, self.phone.isSpoofing, self.activity == "hold" else { return }
                let now = ContinuousClock.now
                let dt = previous.duration(to: now).seconds
                previous = now
                guard !self.phone.isUpdatingLocation, !self.phone.isReconnecting else { continue }
                let shown = wobble.apply(latitude: point.latitude, longitude: point.longitude, dt: dt)
                _ = await self.phone.set(.init(latitude: shown.latitude, longitude: shown.longitude),
                                         name: self.phone.currentName)
            }
        }
    }

    @discardableResult
    func setPaused(_ paused: Bool) async -> Bool {
        guard activity == "route", phone.isSpoofing else { return false }
        self.paused = paused
        if paused { speed = 0 }
        return true
    }

    @discardableResult
    func setAutoStop(minutes: Int) async -> Bool {
        timer?.cancel(); timer = nil
        deadline = Killswitch.deadline(from: now(), minutes: minutes)
        guard let deadline else { return true }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.deadline == deadline else { return }
                if !self.phone.isSpoofing, !self.phone.isWorking, !self.planning {
                    self.deadline = nil
                    return
                }
                if self.now() >= deadline { _ = await self.stop(); return }
            }
        }
        return true
    }

    @discardableResult
    func stop() async -> Bool {
        cancelMotion()
        timer?.cancel(); timer = nil; deadline = nil
        planning = false; activity = "hold"; anchor = nil
        return await phone.stop()
    }

    private func cancelMotion() {
        generation += 1
        runner?.cancel(); runner = nil
        directions?.cancel(); directions = nil
        input = .idle; inputAt = .distantPast; speed = 0; paused = false; routeWait = nil
    }

    /// A joystick or route step may still be sending its last point, and a new place can't be set while one is
    /// in flight. Wait for it (up to five seconds) instead of stopping the location.
    private func settle() async -> Bool {
        for _ in 0..<50 where phone.isUpdatingLocation {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
        }
        return !phone.isUpdatingLocation
    }
}

/// Choices for how natural the simulated GPS looks, from Settings.
enum NaturalSettings {
    static let holdWobbleKey = "natural.holdWobble"

    /// A held place wanders a few metres like a real phone's GPS. On unless turned off.
    static var holdWobble: Bool {
        UserDefaults.standard.object(forKey: holdWobbleKey) as? Bool ?? true
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
