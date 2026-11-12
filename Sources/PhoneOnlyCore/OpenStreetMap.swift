import Foundation

/// A point from OpenStreetMap with its tags.
public struct OSMNode: Sendable, Equatable {
    public var id: Int64
    public var point: GeoPoint
    public var tags: [String: String]

    public init(id: Int64, point: GeoPoint, tags: [String: String]) {
        self.id = id
        self.point = point
        self.tags = tags
    }
}

/// What an Overpass API query answered: the nodes and ways, with their tags.
public struct OverpassAnswer: Sendable, Equatable {
    public var nodes: [OSMNode]
    public var ways: [OSMWay]

    public init(nodes: [OSMNode], ways: [OSMWay]) {
        self.nodes = nodes
        self.ways = ways
    }

    /// The server's own words when it couldn't answer (a timeout, too busy…).
    public struct Remark: Error, Equatable {
        public let text: String
    }

    /// Reads an Overpass JSON answer (`out geom`). Throws `Remark` when the server says it failed.
    public static func decode(_ data: Data) throws -> OverpassAnswer {
        struct Element: Decodable {
            struct LatLon: Decodable {
                let lat: Double
                let lon: Double
            }
            let type: String
            let id: Int64
            let lat: Double?
            let lon: Double?
            let tags: [String: String]?
            let geometry: [LatLon?]?
            let nodes: [Int64]?
        }
        struct Answer: Decodable {
            let elements: [Element]
            let remark: String?
        }
        let answer = try JSONDecoder().decode(Answer.self, from: data)
        if let remark = answer.remark, remark.lowercased().contains("error") {
            throw Remark(text: remark)
        }
        var nodes: [OSMNode] = []
        var ways: [OSMWay] = []
        for element in answer.elements {
            switch element.type {
            case "node":
                guard let lat = element.lat, let lon = element.lon else { continue }
                nodes.append(OSMNode(id: element.id, point: GeoPoint(lat, lon), tags: element.tags ?? [:]))
            case "way":
                let geometry = element.geometry ?? []
                let refs = element.nodes ?? []
                var points: [GeoPoint] = []
                var ids: [Int64] = []
                for (i, entry) in geometry.enumerated() {
                    guard let entry else { continue }
                    points.append(GeoPoint(entry.lat, entry.lon))
                    if refs.count == geometry.count { ids.append(refs[i]) }
                }
                guard points.count >= 2 else { continue }
                ways.append(OSMWay(id: element.id, points: points, tags: element.tags ?? [:],
                                   nodeIDs: ids.count == points.count ? ids : []))
            default:
                continue
            }
        }
        return OverpassAnswer(nodes: nodes, ways: ways)
    }
}
