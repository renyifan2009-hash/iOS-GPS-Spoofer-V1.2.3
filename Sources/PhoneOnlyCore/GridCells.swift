import Foundation

/// Cell numbers for the grids that find what is near a route. Longitude wraps
/// at the antimeridian, so a leg or a lookup that crosses it lands on the cells
/// on both sides of it instead of running round the world.
package enum GridCells {
    /// The column holding `longitude`. 180 and -180 are one meridian, so both
    /// give the westernmost column.
    package static func column(of longitude: Double, cell: Double) -> Int {
        var l = Geo.normalizedLongitude(longitude)
        if l >= 180 { l = -180 }
        return Int(floor(l / cell))
    }

    package static func row(of latitude: Double, cell: Double) -> Int {
        Int(floor(latitude / cell))
    }

    /// The column that a number past the grid's edge (east of 180 or west of
    /// -180) stands for.
    package static func wrapped(column: Int, cell: Double) -> Int {
        self.column(of: (Double(column) + 0.5) * cell, cell: cell)
    }

    /// `to - from` in degrees of longitude, the short way round.
    package static func longitudeDelta(from: Double, to: Double) -> Double {
        var d = to - from
        if d > 180 { d -= 360 } else if d < -180 { d += 360 }
        return d
    }
}
