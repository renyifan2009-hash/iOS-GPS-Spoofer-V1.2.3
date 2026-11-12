import Foundation

/// Miles or kilometres per hour, by region, and the speed sliders in whichever one is shown. Routes and
/// saved routes keep their speed in km/h; only what a person sees and drags changes.
public struct SpeedUnits: Equatable, Sendable {
    /// The three ways iOS and macOS group regions for measurements.
    public enum Region: Sendable { case us, uk, metric }

    /// Miles per hour (the US and the UK, where road speeds are in mph).
    public let imperial: Bool

    public init(imperial: Bool) { self.imperial = imperial }

    public init(region: Region) { imperial = region != .metric }

    /// The units to show: what the person picked in Settings, or else what this device's region uses.
    public static var current: SpeedUnits { resolve(UnitsChoice.saved, region: deviceRegion) }

    /// The units this device's region uses (Settings ▸ General ▸ Language & Region ▸ Measurement System).
    public static var deviceRegion: Region {
        switch Locale.current.measurementSystem {
        case .us: return .us
        case .uk: return .uk
        default: return .metric
        }
    }

    public static func resolve(_ choice: UnitsChoice, region: Region) -> SpeedUnits {
        switch choice {
        case .automatic: return SpeedUnits(region: region)
        case .miles: return SpeedUnits(imperial: true)
        case .kilometers: return SpeedUnits(imperial: false)
        }
    }

    static let kmPerMile = 1.609344

    public var label: String { imperial ? "mph" : "km/h" }

    /// A speed in km/h, in the shown unit.
    public func display(kmh: Double) -> Double { imperial ? kmh / Self.kmPerMile : kmh }

    /// A speed in the shown unit, in km/h.
    public func kmh(fromDisplay value: Double) -> Double { imperial ? value * Self.kmPerMile : value }

    /// The route speed slider, in the shown unit.
    public func routeRange(driving: Bool) -> ClosedRange<Double> {
        imperial ? (driving ? 5...75 : 1...6) : (driving ? 10...120 : 1...10)
    }

    public func routeStep(driving: Bool) -> Double {
        imperial ? (driving ? 5 : 0.5) : (driving ? 5 : 1)
    }

    /// A town drive or a walk, landing on the slider's steps: 30 mph / 3 mph, or 50 km/h / 5 km/h.
    public func defaultKmh(driving: Bool) -> Double {
        imperial ? kmh(fromDisplay: driving ? 30 : 3) : (driving ? 50 : 5)
    }

    /// The joystick's custom top speed, in the shown unit.
    public var joystickRange: ClosedRange<Double> { imperial ? 1...75 : 1...120 }

    /// "30 mph", "2.5 mph", "50 km/h". Halves show only below 10, where the walking slider uses them.
    public func text(kmh: Double) -> String {
        guard kmh.isFinite, kmh > 0 else { return "0 \(label)" }
        let value = min(display(kmh: kmh), 9_999)
        let half = (value * 2).rounded() / 2
        if value < 10, half != half.rounded() {
            return String(format: "%.1f %@", half, label)
        }
        return "\(Int(value.rounded())) \(label)"
    }

    public func text(metersPerSecond: Double) -> String { text(kmh: metersPerSecond * 3.6) }

    static let metersPerMile = 1_609.344

    /// A route length the way road signs give it: "500 ft", "0.3 mi", "1.9 mi", "12 mi", or "850 m",
    /// "1.9 km", "12 km". Feet below a tenth of a mile and metres below a kilometre, rounded to 10.
    public func distanceText(meters: Double, locale: Locale = .current) -> String {
        let meters = max(0, meters.isFinite ? meters : 0)
        let small = imperial ? meters < Self.metersPerMile / 10 : meters < 1_000
        let measurement: Measurement<UnitLength>
        if small {
            let value = imperial ? meters / 0.3048 : meters
            measurement = Measurement(value: (value / 10).rounded() * 10, unit: imperial ? .feet : .meters)
        } else {
            measurement = Measurement(value: imperial ? meters / Self.metersPerMile : meters / 1_000,
                                      unit: imperial ? .miles : .kilometers)
        }
        let decimals = small || measurement.value >= 10 ? 0...0 : 0...1
        return measurement.formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                                  numberFormatStyle: .number.precision(.fractionLength(decimals)))
            .locale(locale))
    }
}

/// Miles or kilometres, as picked in Settings. Automatic follows the device's region.
public enum UnitsChoice: String, CaseIterable, Sendable {
    case automatic, miles, kilometers

    /// Where the iPhone app keeps it (UserDefaults, so `@AppStorage` can watch it).
    public static let key = "units.choice"

    public static var saved: UnitsChoice {
        UserDefaults.standard.string(forKey: key).flatMap(UnitsChoice.init(rawValue:)) ?? .automatic
    }
}
