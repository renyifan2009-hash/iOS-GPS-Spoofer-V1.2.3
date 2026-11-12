import RemoteAPI

/// The controls can send commands to a Mac or execute them entirely on this phone.
@MainActor
protocol ControlTarget: AnyObject {
    var status: RemoteStatus? { get }
    var isSpoofing: Bool { get }
    var isWorking: Bool { get }
    var executionName: String { get }
    /// Routes driven here can keep to each road's speed limit ("Drive at the speed limit").
    var drivesAtSpeedLimits: Bool { get }
    func steer(heading: Double, speed: Double) async -> String?
    @discardableResult func stop() async -> Bool
    @discardableResult func setPaused(_ paused: Bool) async -> Bool
    @discardableResult func setAutoStop(minutes: Int) async -> Bool
}

extension ConnectionManager: ControlTarget {
    var executionName: String { "Mac" }
    /// A Mac on protocol version 3 or later takes the route's roads and drives them at their limits.
    var drivesAtSpeedLimits: Bool { takesRoads }
}
