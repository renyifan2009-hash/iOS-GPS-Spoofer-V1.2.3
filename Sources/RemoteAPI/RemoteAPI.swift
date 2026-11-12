import Foundation

/// The wire protocol between the iPhone remote app and the Mac helper
/// (`iosgpsspoof serve`, or the Mac app with Settings ▸ Remote turned on).
///
/// JSON over plain HTTP/1.1 on the local network. The Mac only accepts
/// connections from private / link-local addresses, and every request except
/// `GET /info` and `POST /pair` must carry `Authorization: Bearer <token>`,
/// where the token comes from pairing with the 6-digit code the Mac shows.
///
///     GET  /info       → ServerInfo                       (no token needed)
///     POST /pair       PairRequest → PairResponse         (no token needed)
///     GET  /status     → RemoteStatus
///     POST /location   LocationRequest → RemoteStatus     (moves now if spoofing)
///     POST /start      LocationRequest? → RemoteStatus    (body optional)
///     POST /route      RouteRequest → RemoteStatus        (drives a route, optionally on the roads sent)
///     POST /joystick   JoystickRequest → RemoteStatus     (steer: a heading and a speed)
///     POST /pause      PauseRequest → RemoteStatus        (pause or resume a route)
///     POST /autostop   AutoStopRequest → RemoteStatus     (stop by itself after N minutes)
///     POST /stop       → RemoteStatus                     (restores the real GPS)
///     POST /unpair     → RemoteStatus                     (revokes this token)
///
/// Errors come back as a non-2xx status with an `APIError` body.
public enum RemoteAPI {
    /// 2: a wait on a route's first stop holds the start before leaving, and `/status` can carry `routeWait`.
    /// 3: a route can carry its roads (`RouteRequest.legs`, so `/route` takes bodies up to
    /// `maxRouteBodyBytes`) and ask to drive at each road's speed limit (`followSpeedLimits`).
    public static let version = 3
    /// Bonjour service type the Mac advertises and the iPhone browses for.
    public static let serviceType = "_iosgpsspoof._tcp"
    public static let defaultPort: UInt16 = 47_653
    public static let pairingCodeLength = 6

    public enum Path {
        public static let info = "/info"
        public static let pair = "/pair"
        public static let unpair = "/unpair"
        public static let status = "/status"
        public static let location = "/location"
        public static let start = "/start"
        public static let route = "/route"
        public static let joystick = "/joystick"
        public static let pause = "/pause"
        public static let autoStop = "/autostop"
        public static let stop = "/stop"
    }

    /// Keys of the Bonjour TXT record.
    public enum TXTKey {
        public static let version = "v"
        public static let serverID = "id"
        public static let name = "name"
        /// Comma-separated IPv4 addresses, a fallback when resolving fails.
        public static let addresses = "ip"
        public static let port = "port"
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }
}

/// Who is answering; safe to show before pairing.
public struct ServerInfo: Codable, Sendable, Equatable {
    /// Stable across restarts, so the iPhone can find its paired Mac again.
    public var serverID: String
    public var name: String
    public var version: Int

    public init(serverID: String, name: String, version: Int = RemoteAPI.version) {
        self.serverID = serverID
        self.name = name
        self.version = version
    }
}

public struct PairRequest: Codable, Sendable, Equatable {
    public var code: String
    public var clientName: String
    /// Stable per iPhone, so re-pairing replaces the old token instead of
    /// piling up entries.
    public var clientID: String

    public init(code: String, clientName: String, clientID: String) {
        self.code = code
        self.clientName = clientName
        self.clientID = clientID
    }
}

public struct PairResponse: Codable, Sendable, Equatable {
    public var token: String
    public var server: ServerInfo

    public init(token: String, server: ServerInfo) {
        self.token = token
        self.server = server
    }
}

public struct LocationRequest: Codable, Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    /// Shown back in `RemoteStatus.placeName` (and on the Mac).
    public var name: String?

    public init(latitude: Double, longitude: Double, name: String? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.name = name
    }

    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite
            && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

/// A route for the Mac to drive, sent by the iPhone. The Mac plans it (with the
/// realistic-trips engine when `realistic`) and moves the location along it; a
/// `POST /stop` ends it and restores the real GPS. Travel and loop modes are
/// strings so this library stays free of SpooferCore; they match the raw values
/// of SpooferCore's `TravelMode` and `LoopMode`.
public struct RouteRequest: Codable, Sendable, Equatable {
    /// A point on the route, with an optional wait there.
    public struct Waypoint: Codable, Sendable, Equatable {
        public var latitude: Double
        public var longitude: Double
        /// Seconds to wait at this point (nil or 0: don't wait).
        public var wait: Double?

        public init(latitude: Double, longitude: Double, wait: Double? = nil) {
            self.latitude = latitude
            self.longitude = longitude
            self.wait = wait
        }

        public var isValid: Bool {
            latitude.isFinite && longitude.isFinite
                && (-90...90).contains(latitude) && (-180...180).contains(longitude)
                && (wait.map { $0.isFinite && $0 >= 0 && $0 <= RemoteAPI.maxWaitSeconds } ?? true)
        }
    }

    /// The route's points, in order (two or more).
    public var waypoints: [Waypoint]
    /// Follow real roads and paths between waypoints, instead of straight lines.
    public var followRoads: Bool
    /// "walking" or "driving".
    public var travelMode: String
    /// "once", "loop" or "pingPong".
    public var loopMode: String
    /// Top speed, metres per second.
    public var speed: Double
    /// Move like a real person (the realistic-trips engine).
    public var realistic: Bool
    /// With `realistic` and driving: slow down in rush hour (time-of-day traffic).
    public var timeOfDayTraffic: Bool
    /// Shown back in `RemoteStatus.placeName` and on the Mac.
    public var name: String?
    /// The roads between the stops, as the iPhone's Apple Maps found them: `legs[i]` runs from waypoint
    /// `i` to `i + 1`, and for a loop whose last stop isn't its first, one more runs from the last stop
    /// back to the first. A nil leg is a straight line (Apple Maps had no road there). nil: the Mac finds
    /// the roads itself, or drives straight lines. Sent to Macs on version 3 or later only: an older one
    /// turns a body this big away.
    public var legs: [RoadLeg?]?
    /// With `realistic` and driving on roads: drive each road at about its speed limit, and `speed` only
    /// where no limit is known. nil or false: `speed` is the top speed, and limits only slow the route.
    public var followSpeedLimits: Bool?

    public static let travelModes = ["walking", "driving"]
    public static let loopModes = ["once", "loop", "pingPong"]

    public init(waypoints: [Waypoint], followRoads: Bool = false, travelMode: String = "walking",
                loopMode: String = "once", speed: Double = 1.4, realistic: Bool = true,
                timeOfDayTraffic: Bool = false, name: String? = nil, legs: [RoadLeg?]? = nil,
                followSpeedLimits: Bool? = nil) {
        self.waypoints = waypoints
        self.followRoads = followRoads
        self.travelMode = travelMode
        self.loopMode = loopMode
        self.speed = speed
        self.realistic = realistic
        self.timeOfDayTraffic = timeOfDayTraffic
        self.name = name
        self.legs = legs
        self.followSpeedLimits = followSpeedLimits
    }

    public var isValid: Bool {
        waypoints.count >= 2 && waypoints.allSatisfy(\.isValid)
            && speed.isFinite && speed > 0 && speed < 400
            && Self.travelModes.contains(travelMode) && Self.loopModes.contains(loopMode)
    }

    // Lenient decoding so a newer or older iPhone build still loads.
    enum CodingKeys: String, CodingKey {
        case waypoints, followRoads, travelMode, loopMode, speed, realistic, timeOfDayTraffic, name, legs,
             followSpeedLimits
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        waypoints = (try? c.decode([Waypoint].self, forKey: .waypoints)) ?? []
        followRoads = (try? c.decode(Bool.self, forKey: .followRoads)) ?? false
        travelMode = (try? c.decode(String.self, forKey: .travelMode)) ?? "walking"
        loopMode = (try? c.decode(String.self, forKey: .loopMode)) ?? "once"
        speed = (try? c.decode(Double.self, forKey: .speed)) ?? 1.4
        realistic = (try? c.decode(Bool.self, forKey: .realistic)) ?? true
        timeOfDayTraffic = (try? c.decode(Bool.self, forKey: .timeOfDayTraffic)) ?? false
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        // Roads that can't be read are left out (the Mac finds its own, or drives straight), not an error.
        legs = try? c.decodeIfPresent([RoadLeg?].self, forKey: .legs)
        followSpeedLimits = try? c.decodeIfPresent(Bool.self, forKey: .followSpeedLimits)
    }

    /// The road legs, if they fit this route: one per pair of stops (plus the way back for a loop that
    /// doesn't end where it starts), each with readable points. nil otherwise.
    public var usableLegs: [RoadLeg?]? {
        guard let legs, waypoints.count >= 2 else { return nil }
        let first = waypoints[0], last = waypoints[waypoints.count - 1]
        let closes = loopMode == "loop" && (first.latitude != last.latitude || first.longitude != last.longitude)
        let expected = waypoints.count - 1 + (closes ? 1 : 0)
        // A loop that ends at its start needs no way back, but one sent anyway does no harm.
        guard legs.count == expected || (loopMode == "loop" && legs.count == waypoints.count) else { return nil }
        let points = legs.reduce(0) { $0 + ($1?.pointCount ?? 0) }
        guard points <= RemoteAPI.maxRoadPoints, legs.allSatisfy({ $0?.isValid ?? true }) else { return nil }
        return legs
    }
}

/// One stretch of road between two stops of a route.
public struct RoadLeg: Codable, Sendable, Equatable {
    /// latitude, longitude, latitude, longitude… in degrees: the road from one stop to the next, starting at
    /// the stop it leaves and ending at the one it reaches.
    public var coordinates: [Double]
    /// Apple Maps' length for it, metres.
    public var meters: Double?
    /// How long Apple Maps expects it to take, seconds: where no speed limit is known, the Mac drives it at
    /// about the speed that makes (`SpeedZone.cruise`).
    public var expectedSeconds: Double?

    public init(coordinates: [Double], meters: Double? = nil, expectedSeconds: Double? = nil) {
        self.coordinates = coordinates
        self.meters = meters
        self.expectedSeconds = expectedSeconds
    }

    /// From (latitude, longitude) points, each kept to six decimals (about 10 cm), which is plenty for a road
    /// and keeps the request small.
    public init(points: [(latitude: Double, longitude: Double)], meters: Double? = nil, expectedSeconds: Double? = nil) {
        func round(_ x: Double) -> Double { (x * 1e6).rounded() / 1e6 }
        self.init(coordinates: points.flatMap { [round($0.latitude), round($0.longitude)] },
                  meters: meters, expectedSeconds: expectedSeconds)
    }

    public var pointCount: Int { coordinates.count / 2 }

    /// The points as (latitude, longitude) pairs.
    public var points: [(latitude: Double, longitude: Double)] {
        stride(from: 0, to: coordinates.count - 1, by: 2).map { (coordinates[$0], coordinates[$0 + 1]) }
    }

    /// Two or more real places, and a length and time that are numbers if given.
    public var isValid: Bool {
        guard coordinates.count >= 4, coordinates.count % 2 == 0 else { return false }
        for i in stride(from: 0, to: coordinates.count, by: 2) {
            let lat = coordinates[i], lon = coordinates[i + 1]
            guard lat.isFinite, lon.isFinite, (-90...90).contains(lat), (-180...180).contains(lon) else { return false }
        }
        return (meters.map { $0.isFinite && $0 >= 0 } ?? true)
            && (expectedSeconds.map { $0.isFinite && $0 >= 0 } ?? true)
    }
}

public struct DeviceSummary: Codable, Sendable, Equatable {
    public var name: String
    public var model: String
    public var iosVersion: String
    /// "usb" or "network".
    public var connection: String

    public init(name: String, model: String, iosVersion: String, connection: String) {
        self.name = name
        self.model = model
        self.iosVersion = iosVersion
        self.connection = connection
    }
}

public enum SpoofPhase: String, Codable, Sendable, Equatable {
    case idle
    case starting
    case active
    case reconnecting
    case stopping
    case failed
}

public struct RemoteStatus: Codable, Sendable, Equatable {
    /// The Mac can see the iPhone it controls (over USB or the network).
    public var connected: Bool
    /// A simulated location is being held, or being re-established.
    public var spoofing: Bool
    public var latitude: Double?
    public var longitude: Double?
    public var placeName: String?
    public var phase: SpoofPhase
    /// Human-readable progress or error text for the current phase.
    public var detail: String?
    public var device: DeviceSummary?
    /// "Live" or "Classic".
    public var engine: String?
    public var serverName: String
    /// What the Mac is doing: "hold" (a place), "planning", "route" or "joystick". nil when idle.
    /// Added after version 1: older Macs leave these out, and older iPhones ignore them.
    public var activity: String?
    /// Current movement speed, metres per second.
    public var speed: Double?
    /// Direction of travel, degrees clockwise from north.
    public var heading: Double?
    /// How far along the current lap of a route, 0...1.
    public var routeProgress: Double?
    public var routePaused: Bool?
    /// When Auto-stop will put the real location back (seconds since 1970); nil when it is off.
    public var autoStopAt: Double?
    /// While a route is stopped: why, at which of your stops, and for how much longer. nil while moving.
    public var routeWait: RouteWait?
    /// The protocol version the Mac speaks (`RemoteAPI.version`). nil from a Mac before version 2.
    public var apiVersion: Int?

    public init(connected: Bool, spoofing: Bool, latitude: Double? = nil, longitude: Double? = nil,
                placeName: String? = nil, phase: SpoofPhase, detail: String? = nil,
                device: DeviceSummary? = nil, engine: String? = nil, serverName: String,
                activity: String? = nil, speed: Double? = nil, heading: Double? = nil,
                routeProgress: Double? = nil, routePaused: Bool? = nil, autoStopAt: Double? = nil,
                routeWait: RouteWait? = nil, apiVersion: Int? = RemoteAPI.version) {
        self.connected = connected
        self.spoofing = spoofing
        self.latitude = latitude
        self.longitude = longitude
        self.placeName = placeName
        self.phase = phase
        self.detail = detail
        self.device = device
        self.engine = engine
        self.serverName = serverName
        self.activity = activity
        self.speed = speed
        self.heading = heading
        self.routeProgress = routeProgress
        self.routePaused = routePaused
        self.autoStopAt = autoStopAt
        self.routeWait = routeWait
        self.apiVersion = apiVersion
    }
}

/// Why a route is standing still, so the iPhone can say "Leaving in 29:41" or "Resting at stop 2".
public struct RouteWait: Codable, Sendable, Equatable {
    /// "stop" (one of your stops), "light", "sign", "yield", "crossing", "break", "turnaround" or "arrived".
    public var reason: String
    /// Which of your stops, counting the start as 0, when `reason` is "stop".
    public var stop: Int?
    /// Seconds left. nil when it stays until you stop it (arrived).
    public var remaining: Double?

    public init(reason: String, stop: Int? = nil, remaining: Double? = nil) {
        self.reason = reason
        self.stop = stop
        self.remaining = remaining
    }
}

/// Where to steer, from the iPhone's joystick. The Mac keeps moving that way at that speed until the next
/// request, and stops by itself if none arrives for `RemoteAPI.joystickTimeout` seconds, so a dropped
/// connection can never leave the location running away. Resend about every half second while a direction
/// is held. A speed of 0 stands still. The location must already be held (`POST /start` first).
public struct JoystickRequest: Codable, Sendable, Equatable {
    /// Degrees clockwise from true north, 0 up to (not including) 360.
    public var heading: Double
    /// Metres per second.
    public var speed: Double

    public static let maxSpeed = 70.0

    public init(heading: Double, speed: Double) {
        self.heading = heading
        self.speed = speed
    }

    public var isValid: Bool {
        heading.isFinite && speed.isFinite && heading >= 0 && heading < 360 && speed >= 0 && speed <= Self.maxSpeed
    }

    /// The same request with the heading wrapped into 0..<360 and the speed held to the limits.
    public var normalized: JoystickRequest {
        guard heading.isFinite, speed.isFinite else { return JoystickRequest(heading: 0, speed: 0) }
        var h = heading.truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        return JoystickRequest(heading: h, speed: min(max(speed, 0), Self.maxSpeed))
    }
}

extension RemoteAPI {
    /// Seconds without a joystick request after which the Mac stops moving.
    public static let joystickTimeout: TimeInterval = 1.5
    /// The longest an Auto-stop may be: a day.
    public static let maxAutoStopMinutes = 24 * 60
    /// The longest wait at one stop of a route: a day (the same as `WaitDuration.maxSeconds` on the iPhone).
    public static let maxWaitSeconds: Double = 24 * 3600
    /// The most road points one route may carry, all legs together (a few hundred kilometres of road).
    public static let maxRoadPoints = 60_000
    /// The largest `/route` body a Mac on version 3 or later takes; every other call stays at 64 KB.
    public static let maxRouteBodyBytes = 4 * 1024 * 1024
}

public struct PauseRequest: Codable, Sendable, Equatable {
    public var paused: Bool

    public init(paused: Bool) {
        self.paused = paused
    }
}

/// Stop by itself after this many minutes (0 turns it off). It counts from the request.
public struct AutoStopRequest: Codable, Sendable, Equatable {
    public var minutes: Int

    public init(minutes: Int) {
        self.minutes = minutes
    }

    public var isValid: Bool { (0...RemoteAPI.maxAutoStopMinutes).contains(minutes) }
}

public struct APIError: Codable, Sendable, Equatable, Error {
    public var error: String

    public init(_ error: String) {
        self.error = error
    }
}
