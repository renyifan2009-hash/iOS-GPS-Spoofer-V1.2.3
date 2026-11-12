import Foundation
import PhoneOnlyCore

/// Updating from the project's published release instead of rebuilding on the person's Mac.
///
/// The release DMG is built, launch-tested and checksummed by CI, so it starts the same
/// everywhere. Rebuilding from source on a Mac whose developer tools don't match its system once
/// produced an app that crashed at launch. This file holds the parts that can be tested without a
/// network: reading the release tag, the file names, checking a download, putting the app beside
/// the old one, starting it once, and swapping it in with a way back.
public enum ReleaseInstall {
    // MARK: Names and addresses

    /// "https://github.com/o/r/releases/tag/v2.4.0" -> "v2.4.0". GitHub redirects `releases/latest` here.
    public static func tag(fromReleaseURL url: URL) -> String? {
        let parts = url.pathComponents
        guard let index = parts.lastIndex(of: "tag"), index + 1 < parts.count else { return nil }
        let tag = parts[index + 1]
        return ReleaseVersion(tag) == nil ? nil : tag
    }

    /// The DMG CI publishes for a version: `AnyWhere-2.4.0.dmg`.
    public static func dmgName(version: String) -> String {
        "AnyWhere-\(ReleaseVersion(version)?.description ?? version).dmg"
    }

    public static func assetURL(repository: String, tag: String, name: String) -> URL? {
        guard !name.isEmpty, !name.contains("/"), !tag.contains("/"), !tag.isEmpty else { return nil }
        return URL(string: "https://github.com/\(repository)/releases/download/\(tag)/\(name)")
    }

    public static func latestReleaseURL(repository: String) -> URL? {
        URL(string: "https://github.com/\(repository)/releases/latest")
    }

    // MARK: Where the app is running

    public enum Problem: Error, Equatable, CustomStringConvertible {
        case runningFromDiskImageOrQuarantine
        case folderNotWritable(String)
        case checksumMissing
        case checksumMismatch
        case noAppInDiskImage
        case couldNotMount(String)
        case copyFailed(String)
        case badSignature
        case selfTestFailed(String)
        case swapFailed(String)

        public var description: String {
            switch self {
            case .runningFromDiskImageOrQuarantine:
                return "AnyWhere is running from a temporary place. Drag it into the Applications folder, open it from there, then update."
            case .folderNotWritable(let folder):
                return "AnyWhere can't change the folder it is in (\(folder)). Move it to your Applications folder, or update from the Releases page."
            case .checksumMissing:
                return "The release has no checksum to check the download against, so it wasn't installed."
            case .checksumMismatch:
                return "The download doesn't match the release's checksum, so it was thrown away. Try again."
            case .noAppInDiskImage:
                return "The download has no AnyWhere app inside."
            case .couldNotMount(let why):
                return "Couldn't open the download: \(why)"
            case .copyFailed(let why):
                return "Couldn't copy the new app: \(why)"
            case .badSignature:
                return "The new app failed its signature check, so it wasn't installed."
            case .selfTestFailed(let why):
                return "The new app didn't start properly, so it wasn't installed. Your current app is unchanged. \(why)"
            case .swapFailed(let why):
                return "Couldn't put the new app in place: \(why)"
            }
        }
    }

    /// Whether the running app can be replaced where it sits. An app opened from a disk image or
    /// straight from Downloads runs from a read-only, randomised path (App Translocation).
    public static func checkReplaceable(appURL: URL, fileManager fm: FileManager = .default) throws {
        let path = appURL.path
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") {
            throw Problem.runningFromDiskImageOrQuarantine
        }
        let parent = appURL.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: parent.path) else { throw Problem.folderNotWritable(parent.lastPathComponent) }
    }

    // MARK: Checking and staging a download

    /// Checks the DMG against `SHA256SUMS.txt` text. A release with no usable checksum is refused.
    public static func verifyDownload(_ dmg: URL, checksums: String?, name: String) throws {
        guard let checksums, let expected = PhoneApp.expectedChecksum(for: name, inChecksumFile: checksums) else {
            throw Problem.checksumMissing
        }
        guard try PhoneApp.sha256(ofFileAt: dmg) == expected else { throw Problem.checksumMismatch }
    }

    /// Opens the DMG read-only, copies `AnyWhere.app` into a private staging folder beside
    /// `destinationParent`, closes the DMG, checks the signature, and runs `selfTest` on the copy.
    /// Returns the staged app. Nothing that already exists is touched.
    public static func stage(dmg: URL, beside destinationParent: URL, appName: String = "AnyWhere.app",
                             selfTest: (URL) throws -> Void) throws -> URL {
        let fm = FileManager.default
        let mount = fm.temporaryDirectory.appendingPathComponent("anywhere-mount-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        // Opening a disk image now and then fails for a moment ("resource busy"), and a failed try can leave it
        // half open. Close whatever is left and try again a few times before giving up.
        var attach = try ProcessRunner.run(hdiutil, arguments: attachArguments(dmg, at: mount), timeout: 120)
        for wait in [1.0, 2, 4] where attach.status != 0 {
            detachAll(of: dmg)
            Thread.sleep(forTimeInterval: wait)
            attach = try ProcessRunner.run(hdiutil, arguments: attachArguments(dmg, at: mount), timeout: 120)
        }
        guard attach.status == 0 else {
            detachAll(of: dmg)
            try? fm.removeItem(at: mount)
            throw Problem.couldNotMount(attach.errorSummary.isEmpty ? "status \(attach.status)" : attach.errorSummary)
        }
        func detach() {
            for wait in [0.0, 1, 2] {
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                let result = try? ProcessRunner.run(hdiutil, arguments: ["detach", mount.path, "-force", "-quiet"], timeout: 60)
                if result?.status == 0 { break }
            }
            detachAll(of: dmg)   // anything still open from this image
            try? fm.removeItem(at: mount)
        }

        let source = mount.appendingPathComponent(appName)
        guard fm.fileExists(atPath: source.path) else { detach(); throw Problem.noAppInDiskImage }

        let staging = destinationParent.appendingPathComponent(".AnyWhere-update-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let staged = staging.appendingPathComponent(appName)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            let copy = try ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: [source.path, staged.path], timeout: 120)
            guard copy.status == 0 else { throw Problem.copyFailed(copy.errorSummary) }
        } catch {
            detach()
            try? fm.removeItem(at: staging)
            throw (error as? Problem) ?? Problem.copyFailed(SpoofSession.firstLine(of: error))
        }
        detach()

        do {
            let verify = try ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/codesign"),
                                               arguments: ["--verify", "--deep", "--strict", staged.path], timeout: 60)
            guard verify.status == 0 else { throw Problem.badSignature }
            try selfTest(staged)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        return staged
    }

    /// Runs the app's launch self-test (see SelfTest in the app). Exit 0 and `SELF-TEST-OK` mean it started.
    private static let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")

    private static func attachArguments(_ dmg: URL, at mount: URL) -> [String] {
        ["attach", dmg.path, "-nobrowse", "-readonly", "-noverify", "-mountpoint", mount.path, "-quiet"]
    }

    /// Closes every device still open from `dmg` (`hdiutil info` lists them by image path).
    static func detachAll(of dmg: URL) {
        for device in attachedDevices(of: dmg) {
            _ = try? ProcessRunner.run(hdiutil, arguments: ["detach", device, "-force", "-quiet"], timeout: 60)
        }
    }

    /// The whole-disk devices (`/dev/diskN`) open from `dmg`, from `hdiutil info -plist`.
    static func attachedDevices(of dmg: URL) -> [String] {
        guard let info = try? ProcessRunner.run(hdiutil, arguments: ["info", "-plist"], timeout: 30), info.status == 0,
              let plist = try? PropertyListSerialization.propertyList(from: Data(info.stdout.utf8), format: nil)
                as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return [] }
        let wanted = dmg.resolvingSymlinksInPath().path
        return images.compactMap { image -> String? in
            guard let path = image["image-path"] as? String,
                  URL(fileURLWithPath: path).resolvingSymlinksInPath().path == wanted,
                  let entities = image["system-entities"] as? [[String: Any]] else { return nil }
            // The shortest dev-entry is the whole disk; detaching it closes its volumes too.
            return entities.compactMap { $0["dev-entry"] as? String }.min { $0.count < $1.count }
        }
    }

    public static func runSelfTest(of app: URL, appName: String = "AnyWhere") throws {
        let executable = app.appendingPathComponent("Contents/MacOS/\(appName)")
        var environment = ProcessInfo.processInfo.environment
        environment["ANYWHERE_SELF_TEST"] = "1"
        environment["ANYWHERE_SELF_TEST_SECONDS"] = "5"
        let result: ProcessResult
        do {
            result = try ProcessRunner.run(executable, arguments: [], timeout: 120, environment: environment)
        } catch {
            throw Problem.selfTestFailed(SpoofSession.firstLine(of: error))
        }
        guard result.status == 0, result.stdout.contains("SELF-TEST-OK") else {
            throw Problem.selfTestFailed("It ended with status \(result.status).")
        }
    }

    // MARK: Swapping

    /// Puts `staged` where `current` is. The old app moves to a backup first and is put back if
    /// the move fails. Returns the backup's folder, to delete once the new app has opened.
    @discardableResult
    public static func swap(current: URL, with staged: URL) throws -> URL {
        let fm = FileManager.default
        let backupFolder = current.deletingLastPathComponent()
            .appendingPathComponent(".AnyWhere-old-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let backup = backupFolder.appendingPathComponent(current.lastPathComponent)
        do {
            try fm.createDirectory(at: backupFolder, withIntermediateDirectories: true)
            try fm.moveItem(at: current, to: backup)
        } catch {
            try? fm.removeItem(at: backupFolder)
            throw Problem.swapFailed(SpoofSession.firstLine(of: error))
        }
        do {
            try fm.moveItem(at: staged, to: current)
        } catch {
            // Put the old one back.
            try? fm.moveItem(at: backup, to: current)
            try? fm.removeItem(at: backupFolder)
            throw Problem.swapFailed(SpoofSession.firstLine(of: error))
        }
        // The staging folder is now empty.
        try? fm.removeItem(at: staged.deletingLastPathComponent())
        return backupFolder
    }
}
