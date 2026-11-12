import Network

/// Which network this iPhone is on, as far as its developer connection cares.
///
/// While cellular data is the iPhone's only network, iOS turns away connections to its own developer
/// services that come in through LocalDevVPN: 10.7.0.1 refuses them, though LocalDevVPN says
/// Connected. A LocalDevVPN collaborator says Apple enforces this and it can't be worked around
/// (https://github.com/jkcoxson/LocalDevVPN/issues/31). It works on a joined Wi‑Fi network, and in
/// Airplane Mode when LocalDevVPN was connected before Airplane Mode went on.
public enum PhoneNetwork {
    /// True when cellular data is the only way out: no joined Wi‑Fi and no wired network.
    /// `interfaces` are the types of the current path's available interfaces.
    public static func isCellularOnly(_ interfaces: [NWInterface.InterfaceType]) -> Bool {
        interfaces.contains(.cellular) && !interfaces.contains(.wifi) && !interfaces.contains(.wiredEthernet)
    }
}
