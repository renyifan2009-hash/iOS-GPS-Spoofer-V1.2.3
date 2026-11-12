import Foundation
import PhoneOnlyCore

/// A named place: a favorite, or an entry in the recent-locations history.
public struct SavedPlace: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var created: Date

    public init(id: UUID = UUID(), name: String, point: GeoPoint, created: Date = Date()) {
        self.id = id
        self.name = name
        self.latitude = point.latitude
        self.longitude = point.longitude
        self.created = created
    }

    public var point: GeoPoint {
        get { GeoPoint(latitude, longitude) }
        set { latitude = newValue.latitude; longitude = newValue.longitude }
    }

    enum CodingKeys: String, CodingKey { case id, name, latitude, longitude, created }

    // Lenient, like SavedRoute: a place only has to say where it is. A missing id,
    // name or date is made up, so one hand-edited or older entry still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let latitude = try c.decode(Double.self, forKey: .latitude)
        let longitude = try c.decode(Double.self, forKey: .longitude)
        guard GeoPoint(latitude, longitude).isValid else {
            throw DecodingError.dataCorruptedError(forKey: .latitude, in: c,
                                                   debugDescription: "not a place on the map")
        }
        self.latitude = latitude
        self.longitude = longitude
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? Coordinate.format(GeoPoint(latitude, longitude), precision: 4)
        created = LibraryDates.decode(c, forKey: .created) ?? Date()
    }
}

/// Dates in a library file: ISO 8601, with or without fractional seconds.
enum LibraryDates {
    static func decode<K: CodingKey>(_ c: KeyedDecodingContainer<K>, forKey key: K) -> Date? {
        if let date = try? c.decode(Date.self, forKey: key) { return date }
        guard let text = try? c.decode(String.self, forKey: key) else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text)
    }
}

/// How a road-following route is computed.
public enum TravelMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case walking, driving

    public var id: String { rawValue }
    public var label: String { self == .walking ? "Walking" : "Driving" }
    public var symbolName: String { self == .walking ? "figure.walk" : "car.fill" }
}

/// A saved, re-playable route.
public struct SavedRoute: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var waypoints: [GeoPoint]
    public var followRoads: Bool
    public var travelMode: TravelMode
    public var loopMode: LoopMode
    /// Pace, in metres per second.
    public var speed: Double
    /// Seconds to wait at each waypoint (nil: no waits).
    public var waits: [Double]?
    public var created: Date

    public init(id: UUID = UUID(), name: String, waypoints: [GeoPoint], followRoads: Bool = false,
                travelMode: TravelMode = .walking, loopMode: LoopMode = .once, speed: Double = 1.4,
                waits: [Double]? = nil, created: Date = Date()) {
        self.id = id
        self.name = name
        self.waypoints = waypoints
        self.followRoads = followRoads
        self.travelMode = travelMode
        self.loopMode = loopMode
        self.speed = speed
        self.waits = waits
        self.created = created
    }

    enum CodingKeys: String, CodingKey {
        case id, name, waypoints, followRoads, travelMode, loopMode, speed, waits, created
    }

    // Lenient decoding so files written by newer/older builds still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "Route"
        // Every waypoint or none: a route with one missing would play somewhere else.
        // (A route that fails here is left out of the list, and the file is backed up.)
        waypoints = c.contains(.waypoints) && ((try? c.decodeNil(forKey: .waypoints)) != true)
            ? try c.decode([GeoPoint].self, forKey: .waypoints) : []
        followRoads = (try? c.decode(Bool.self, forKey: .followRoads)) ?? false
        travelMode = (try? c.decode(TravelMode.self, forKey: .travelMode)) ?? .walking
        loopMode = (try? c.decode(LoopMode.self, forKey: .loopMode)) ?? .once
        speed = (try? c.decode(Double.self, forKey: .speed)) ?? 1.4
        waits = try? c.decodeIfPresent([Double].self, forKey: .waits)
        created = LibraryDates.decode(c, forKey: .created) ?? Date()
    }
}

/// Everything the user has saved, persisted as one JSON file.
public struct LibraryData: Codable, Sendable, Equatable {
    public var version: Int = 1
    public var favorites: [SavedPlace] = []
    public var recents: [SavedPlace] = []
    public var routes: [SavedRoute] = []

    public init(favorites: [SavedPlace] = [], recents: [SavedPlace] = [], routes: [SavedRoute] = []) {
        self.favorites = favorites
        self.recents = recents
        self.routes = routes
    }

    enum CodingKeys: String, CodingKey { case version, favorites, recents, routes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        // One entry that cannot be read must not take the others with it.
        let log = decoder.userInfo[.libraryLoadLog] as? LibraryLoadLog
        favorites = c.decodeEach(SavedPlace.self, forKey: .favorites, log: log)
        recents = c.decodeEach(SavedPlace.self, forKey: .recents, log: log)
        routes = c.decodeEach(SavedRoute.self, forKey: .routes, log: log)
    }

    public static let maxRecents = 25

    /// Record a visit, de-duplicating anything within ~25 m and capping the list.
    public mutating func recordRecent(_ place: SavedPlace) {
        recents.removeAll { Geo.distance($0.point, place.point) < 25 }
        recents.insert(place, at: 0)
        if recents.count > Self.maxRecents { recents.removeLast(recents.count - Self.maxRecents) }
    }

    public func favorite(near point: GeoPoint, within metres: Double = 15) -> SavedPlace? {
        favorites.first { Geo.distance($0.point, point) < metres }
    }

    /// Case-insensitive lookup by name: an exact match, else the one favorite
    /// whose name starts with it. Nil for a blank name (every name starts with
    /// nothing, so it would pick the first favorite) and nil when several
    /// favorites start with it, because guessing sends the phone to the wrong
    /// place. `favorites(startingWith:)` lists them.
    public func favorite(named name: String) -> SavedPlace? {
        let key = Self.lookupKey(name)
        guard !key.isEmpty else { return nil }
        if let exact = favorites.first(where: { $0.name.lowercased() == key }) { return exact }
        let starting = favorites(startingWith: name)
        return starting.count == 1 ? starting[0] : nil
    }

    /// Favorites whose name starts with `prefix`, ignoring case. None for a blank prefix.
    public func favorites(startingWith prefix: String) -> [SavedPlace] {
        let key = Self.lookupKey(prefix)
        guard !key.isEmpty else { return [] }
        return favorites.filter { $0.name.lowercased().hasPrefix(key) }
    }

    private static func lookupKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

public enum LibraryFile {
    /// `~/Library/Application Support/AnyWhere/library.json`
    public static var defaultURL: URL {
        AppSupport.directory.appendingPathComponent("library.json")
    }

    /// What loading found, for anyone who wants to tell the user.
    public struct LoadReport: Sendable, Equatable {
        /// Favorites, recents and routes that could not be read and were left out.
        public var droppedEntries = 0
        /// A copy of the file as it was, kept because entries were left out.
        public var backup: URL?
        /// The file was not a library at all, so it was moved here.
        public var movedAside: URL?
        /// The file is there but could not be read or set aside. It is left exactly as
        /// it is, and saving over it is refused.
        public var unreadable = false

        public init() {}
    }

    /// Never throws, and never loses what it can't understand:
    /// - a missing file is an empty library;
    /// - a file that is not a library is moved aside (so it isn't overwritten);
    /// - entries that can't be read are left out one by one, and the file is
    ///   copied to `library.backup-<id>.json` first;
    /// - a file that can't be read at all is left alone, and `save` refuses to
    ///   replace it.
    public static func load(from url: URL = defaultURL) -> LibraryData {
        loadWithReport(from: url).library
    }

    public static func loadWithReport(from url: URL = defaultURL) -> (library: LibraryData, report: LoadReport) {
        var report = LoadReport()
        guard FileManager.default.fileExists(atPath: url.path) else { return (LibraryData(), report) }
        guard let data = try? Data(contentsOf: url) else {
            report.unreadable = true
            return (LibraryData(), report)
        }
        let log = LibraryLoadLog()
        do {
            let library = try decoder(log: log).decode(LibraryData.self, from: data)
            report.droppedEntries = log.dropped
            if log.dropped > 0 { report.backup = keepCopy(of: url, data: data) }
            return (library, report)
        } catch {
            report.movedAside = moveAside(url)
            report.unreadable = report.movedAside == nil
            return (LibraryData(), report)
        }
    }

    public static func save(_ library: LibraryData, to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try protectExistingFile(at: url)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(library).write(to: url, options: .atomic)
    }

    // MARK: Not losing what is there

    private static func decoder(log: LibraryLoadLog? = nil) -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let log { decoder.userInfo[.libraryLoadLog] = log }
        return decoder
    }

    /// Before a save replaces the file: if it holds anything this build can't
    /// represent, keep a copy; if it can't be read at all, don't replace it.
    private static func protectExistingFile(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let data = try? Data(contentsOf: url) else {
            throw SpoofError("the saved places file can't be read, so it was left as it is")
        }
        let log = LibraryLoadLog()
        if (try? decoder(log: log).decode(LibraryData.self, from: data)) == nil {
            guard moveAside(url) != nil else {
                throw SpoofError("the saved places file isn't readable and couldn't be set aside, so it was left as it is")
            }
        } else if log.dropped > 0, keepCopy(of: url, data: data) == nil {
            throw SpoofError("couldn't keep a copy of the saved places file, so it was left as it is")
        }
    }

    /// A copy next to the file, named for its contents, so the same file is only copied once.
    private static func keepCopy(of url: URL, data: Data) -> URL? {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in data { hash = (hash ^ UInt64(byte)) &* 0x0100_0000_01B3 }
        let copy = url.deletingPathExtension().appendingPathExtension("backup-\(String(hash, radix: 16)).json")
        if FileManager.default.fileExists(atPath: copy.path) { return copy }
        do {
            try data.write(to: copy, options: .atomic)
            return copy
        } catch {
            return nil
        }
    }

    /// Move a file that isn't a library out of the way, to a name that isn't taken.
    private static func moveAside(_ url: URL) -> URL? {
        let stamp = Int(Date().timeIntervalSince1970)
        for n in 0..<100 {
            let suffix = n == 0 ? "" : "-\(n + 1)"
            let target = url.deletingPathExtension().appendingPathExtension("corrupt-\(stamp)\(suffix).json")
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
            do {
                try FileManager.default.moveItem(at: url, to: target)
                return target
            } catch {
                return nil
            }
        }
        return nil
    }
}

/// Counts what a lenient decode had to leave out. Handed to the decoder through
/// `userInfo`, because decoding an array one entry at a time has no other way
/// to say what it skipped.
final class LibraryLoadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var dropped: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func drop() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

extension CodingUserInfoKey {
    static let libraryLoadLog = CodingUserInfoKey(rawValue: "anywhere.libraryLoadLog")!
}

/// Stands in for an entry that failed to decode, so the array can step past it.
private struct SkippedEntry: Decodable {}

extension KeyedDecodingContainer {
    /// The array under `key` with any entry that can't be read left out. Missing
    /// or null is empty. Something that isn't an array counts as one lost entry.
    func decodeEach<T: Decodable>(_ type: T.Type, forKey key: Key, log: LibraryLoadLog?) -> [T] {
        guard contains(key), (try? decodeNil(forKey: key)) != true else { return [] }
        guard var list = try? nestedUnkeyedContainer(forKey: key) else {
            log?.drop()
            return []
        }
        var items: [T] = []
        while !list.isAtEnd {
            if let item = try? list.decode(T.self) {
                items.append(item)
            } else {
                log?.drop()
                // A failed decode doesn't move on by itself. If stepping past it fails too, stop: the
                // loop would otherwise never reach the end of the list.
                if (try? list.decode(SkippedEntry.self)) == nil { break }
            }
        }
        return items
    }
}

public enum AppSupport {
    /// The folder inside Application Support, named after the product.
    public static let folderName = "AnyWhere"
    /// What the folder was called before the product became AnyWhere.
    public static let legacyFolderName = "iOS GPS Spoofer"

    private static var base: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    }

    /// The app's support directory (created on demand by writers). The first time anything
    /// asks for it, saved places and routes from the old folder are copied in.
    public static var directory: URL {
        _ = migrationDone
        return base.appendingPathComponent(folderName, isDirectory: true)
    }

    /// The old folder. Read-only from here: nothing is ever deleted from it.
    public static var legacyDirectory: URL {
        base.appendingPathComponent(legacyFolderName, isDirectory: true)
    }

    /// The Python environment holding pymobiledevice3, as installed by
    /// `setup.sh` (and by the app's own installer).
    public static var helperEnvironment: URL {
        directory.appendingPathComponent("venv", isDirectory: true)
    }

    /// The environment an earlier version installed under the old folder's name. Still
    /// usable (and tried after the new one), so updating the app never leaves it without
    /// its helper.
    public static var legacyHelperEnvironment: URL {
        legacyDirectory.appendingPathComponent("venv", isDirectory: true)
    }

    private static let migrationDone: Void = {
        _ = migrateLegacyData(from: legacyDirectory, to: base.appendingPathComponent(folderName, isDirectory: true))
    }()

    /// Items that are rebuilt rather than copied: a Python environment keeps absolute paths
    /// to where it was made, so a copied one would not work.
    static let notMigrated: Set<String> = ["venv", "helpers"]

    /// Copy what the old folder holds (saved places, routes, the remote's pairing) into the
    /// new one. Copies only what is missing, never overwrites, never deletes, and never
    /// throws: a file that can't be copied is skipped. Returns the names it copied.
    @discardableResult
    static func migrateLegacyData(from legacy: URL, to new: URL, fileManager fm: FileManager = .default) -> [String] {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: legacy.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let names = try? fm.contentsOfDirectory(atPath: legacy.path) else { return [] }
        var copied: [String] = []
        for name in names.sorted() where !notMigrated.contains(name) {
            let source = legacy.appendingPathComponent(name)
            let destination = new.appendingPathComponent(name)
            guard !fm.fileExists(atPath: destination.path) else { continue }
            do {
                try fm.createDirectory(at: new, withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: destination)
                copied.append(name)
            } catch {
                continue
            }
        }
        return copied
    }
}
