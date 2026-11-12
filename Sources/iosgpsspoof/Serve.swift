import ArgumentParser
import Foundation
import RemoteAPI
import SpooferCore
import SpooferRemote

extension EnginePreference: ExpressibleByArgument {}

/// `iosgpsspoof serve`: the Mac helper the SpoofRemote iPhone app talks to.
struct Serve: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Let the AnyWhere iPhone app control the location over your local network.",
        discussion: """
            Starts a small server that the AnyWhere app on your iPhone finds over \
            Bonjour. Pair once with the 6-digit code printed below; after that the iPhone \
            can start, move and stop the simulated location without you touching the Mac. \
            The Mac keeps the developer connection to the iPhone (USB or Wi-Fi) open and \
            re-establishes it if it drops.

            Only devices on your local network (including the iPhone's own Personal \
            Hotspot) can connect, and only after pairing. Ctrl-C stops the server and \
            restores the real location.

            --install-agent starts the helper at every login as a user LaunchAgent \
            (no administrator rights). Its log, including new pairing codes, is \
            ~/Library/Logs/iosgpsspoof-remote.log.
            """
    )

    @OptionGroup var common: CommonOptions

    @Option(help: "TCP port to listen on.")
    var port: Int = Int(RemoteAPI.defaultPort)

    @Option(help: "Name the iPhone shows for this Mac (default: the Mac's name).")
    var name: String?

    @Option(help: "Engine: automatic | live | classic.")
    var engine: EnginePreference = .automatic

    @Flag(name: .customLong("install-agent"), help: "Start this helper at login (user LaunchAgent), then exit.")
    var installAgent = false

    @Flag(name: .customLong("uninstall-agent"), help: "Remove the LaunchAgent, then exit.")
    var uninstallAgent = false

    @Flag(name: .customLong("forget-paired"), help: "Unpair every iPhone, then exit.")
    var forgetPaired = false

    @Flag(help: "Also log pymobiledevice3's debug output.")
    var verbose = false

    func validate() throws {
        guard (1...65_535).contains(port) else { throw ValidationError("--port must be between 1 and 65535.") }
    }

    func run() throws {
        if uninstallAgent {
            try LaunchAgent.uninstall()
            print("Removed the LaunchAgent. The helper no longer starts at login.")
            return
        }
        if forgetPaired {
            PairingManager().revokeAll()
            print("Unpaired every iPhone. They'll need a new code to connect.")
            return
        }

        signal(SIGPIPE, SIG_IGN)
        let pmd = try Pymobiledevice3.resolve(explicit: common.pythonPath)

        if installAgent {
            try LaunchAgent.install(arguments: agentArguments(pmd: pmd))
            print("""
                Installed. The helper now runs in the background and starts at every login.
                  Log (with the pairing code): \(LaunchAgent.logURL.path)
                  Remove it with:              iosgpsspoof serve --uninstall-agent
                """)
            return
        }

        log("pymobiledevice3: \(pmd.displayPath)")
        let serverName = name ?? BonjourService.computerName
        let engineKind = resolveEngine(pmd)
        let pairing = PairingManager()
        let controller = SessionRemoteController(pmd: pmd, options: .init(
            udid: common.udid, connection: common.connection, transport: common.transport,
            engine: engineKind, serverName: serverName,
            // Routes on roads look up their lights, signs and speed limits on OpenStreetMap.
            roadData: SessionRemoteController.Options.defaultRoadData))
        let verbose = self.verbose
        controller.onLog = { level, line in
            guard verbose || level != .debug else { return }
            log(line)
        }
        controller.startMonitoring()

        let listenPort = UInt16(port)
        let server = MacRemoteServer(name: serverName, port: listenPort, controller: controller, pairing: pairing)
        server.onLog = { line in log(line) }
        pairing.onChange = { log("pairing code: \(pairing.formattedCode)") }
        server.onStateChange = { state in
            switch state {
            case .ready:
                Serve.printBanner(name: serverName, port: listenPort, code: pairing.formattedCode,
                                  paired: pairing.pairedClients.map(\.name))
            case .failed(let message):
                warn(message)
                controller.shutdown()
                Foundation.exit(1)
            default:
                break
            }
        }
        try server.start()

        // Ctrl-C, or launchctl stopping the agent: put the real location back first.
        let watcher = ShutdownWatcher()
        watcher.install {
            log("shutting down, restoring the real location…")
            server.stop()
            controller.shutdown()
            log("stopped.")
            Foundation.exit(0)
        }
        withExtendedLifetime(watcher) {
            dispatchMain()
        }
    }

    private func resolveEngine(_ pmd: Pymobiledevice3) -> EngineKind {
        if engine == .classic { return .classic }
        log("checking the live engine…")
        switch LiveHelper.probe(python: pmd.pythonInterpreter) {
        case .supported(let version):
            log("live engine ready (pymobiledevice3 \(version))")
            return .live
        case .unsupported(let reason):
            if engine == .live {
                warn("the live engine isn't available (\(reason)); using the classic engine")
            } else {
                log("live engine unavailable (\(reason)); using the classic engine")
            }
            return .classic
        }
    }

    /// The same options, pinned to absolute paths so the agent behaves like
    /// this run regardless of its working directory and minimal PATH.
    private func agentArguments(pmd: Pymobiledevice3) -> [String] {
        var args = ["serve", "--port", String(port), "--engine", engine.rawValue,
                    "--connection", common.connection.rawValue, "--transport", common.transport.rawValue,
                    "--python-path", pmd.executableURL.path]
        if let name { args += ["--name", name] }
        if let udid = common.udid { args += ["--udid", udid] }
        if verbose { args.append("--verbose") }
        return args
    }

    static func printBanner(name: String, port: UInt16, code: String, paired: [String]) {
        let addresses = BonjourService.localIPv4Addresses()
        var lines = [
            "",
            "  AnyWhere remote is ready.",
            "",
            "    This Mac:       \(name)",
            "    Pairing code:   \(code)        (enter it in the AnyWhere app)",
            "    Port:           \(port)",
        ]
        if addresses.isEmpty {
            lines.append("    Reachable at:   (no network yet; connect to Wi-Fi or the iPhone's hotspot)")
        } else {
            for (index, address) in addresses.enumerated() {
                let prefix = index == 0 ? "    Reachable at:   " : "                    "
                lines.append(prefix + "\(address.address)  \(address.label)")
            }
        }
        if !paired.isEmpty {
            lines.append("    Paired:         \(paired.joined(separator: ", "))")
        }
        lines += [
            "",
            "  The iPhone finds this Mac automatically. If it doesn't, type one of the",
            "  addresses above in the app. Leave this running; Ctrl-C stops it and",
            "  restores the real location.",
            "",
        ]
        print(lines.joined(separator: "\n"))
        fflush(stdout)
    }
}

/// The per-user LaunchAgent that keeps `serve` running across logins.
enum LaunchAgent {
    static let label = "com.iosgpsspoof.remote"

    static var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var logURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/iosgpsspoof-remote.log")
    }

    static func install(arguments: [String]) throws {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().path else {
            throw SpoofError("couldn't find this program's own path")
        }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable] + arguments,
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 60,
            "ProcessType": "Interactive",
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path,
            "EnvironmentVariables": ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let fm = FileManager.default
        try fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try? launchctl(["bootout", "gui/\(getuid())/\(label)"])   // replace an older copy
        try data.write(to: plistURL, options: .atomic)
        let result = try launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        guard result.status == 0 else {
            throw SpoofError("launchctl couldn't start the agent: \(result.errorSummary)")
        }
    }

    static func uninstall() throws {
        _ = try? launchctl(["bootout", "gui/\(getuid())/\(label)"])
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) throws -> ProcessResult {
        try ProcessRunner.run(URL(fileURLWithPath: "/bin/launchctl"), arguments: arguments, timeout: 20)
    }
}
