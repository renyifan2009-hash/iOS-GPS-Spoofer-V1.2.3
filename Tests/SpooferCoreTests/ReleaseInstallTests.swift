import XCTest
@testable import SpooferCore

final class ReleaseInstallTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("anywhere-release-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // A directory made read-only by a test has to be writable again to be deleted.
        _ = try? ProcessRunner.run(URL(fileURLWithPath: "/bin/chmod"), arguments: ["-R", "u+w", root.path], timeout: 20)
        try? fm.removeItem(at: root)
    }

    // MARK: Fixtures

    /// A tiny signed app whose "binary" is a shell script that prints `output` and exits with `status`.
    @discardableResult
    private func makeApp(at folder: URL, name: String = "AnyWhere", output: String = "SELF-TEST-OK", status: Int = 0,
                         marker: String = "new") throws -> URL {
        let app = folder.appendingPathComponent("\(name).app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleExecutable": name, "CFBundleIdentifier": "com.example.test",
                                    "CFBundleName": name, "CFBundlePackageType": "APPL", "CFBundleVersion": "1"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let script = "#!/bin/sh\necho '\(output)'\nexit \(status)\n"
        try script.write(to: macOS.appendingPathComponent(name), atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(URL(fileURLWithPath: "/bin/chmod"), arguments: ["+x", macOS.appendingPathComponent(name).path], timeout: 10)
        let resources = app.appendingPathComponent("Contents/Resources")
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        try marker.write(to: resources.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)
        let sign = try ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--force", "--sign", "-", app.path], timeout: 60)
        XCTAssertEqual(sign.status, 0, sign.stderr)
        return app
    }

    /// Each disk image has a name of its own, so one a failed test left open can't be mistaken for another's.
    private func makeDMG(containing folder: URL, name: String = "test-\(UUID().uuidString.prefix(8)).dmg") throws -> URL {
        let dmg = root.appendingPathComponent(name)
        let make = try ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/hdiutil"),
                                         arguments: ["create", "-volname", "AnyWhere", "-srcfolder", folder.path, "-ov", "-format", "UDZO", dmg.path, "-quiet"],
                                         timeout: 120)
        XCTAssertEqual(make.status, 0, make.stderr)
        return dmg
    }

    private func marker(of app: URL) -> String? {
        try? String(contentsOf: app.appendingPathComponent("Contents/Resources/marker.txt"), encoding: .utf8)
    }

    // MARK: Names and addresses

    func testTagFromTheLatestReleaseRedirect() {
        XCTAssertEqual(ReleaseInstall.tag(fromReleaseURL: URL(string: "https://github.com/o/r/releases/tag/v2.4.0")!), "v2.4.0")
        XCTAssertNil(ReleaseInstall.tag(fromReleaseURL: URL(string: "https://github.com/o/r/releases/latest")!))
        XCTAssertNil(ReleaseInstall.tag(fromReleaseURL: URL(string: "https://github.com/o/r/releases/tag/nightly")!), "not a version")
    }

    func testAssetNamesAndURLs() {
        XCTAssertEqual(ReleaseInstall.dmgName(version: "v2.4.0"), "AnyWhere-2.4.0.dmg")
        XCTAssertEqual(ReleaseInstall.dmgName(version: "2.4.0"), "AnyWhere-2.4.0.dmg")
        XCTAssertEqual(ReleaseInstall.assetURL(repository: "o/r", tag: "v2.4.0", name: "SHA256SUMS.txt")?.absoluteString,
                       "https://github.com/o/r/releases/download/v2.4.0/SHA256SUMS.txt")
        XCTAssertNil(ReleaseInstall.assetURL(repository: "o/r", tag: "v1", name: "../x"))
        XCTAssertNil(ReleaseInstall.assetURL(repository: "o/r", tag: "a/b", name: "x"))
        XCTAssertEqual(ReleaseInstall.latestReleaseURL(repository: "o/r")?.absoluteString, "https://github.com/o/r/releases/latest")
    }

    // MARK: Can it be replaced where it is?

    func testAnAppRunningFromADiskImageOrTranslocatedCannotBeReplaced() {
        for path in ["/Volumes/AnyWhere/AnyWhere.app", "/private/var/folders/x/AppTranslocation/ABC/d/AnyWhere.app"] {
            XCTAssertThrowsError(try ReleaseInstall.checkReplaceable(appURL: URL(fileURLWithPath: path))) {
                XCTAssertEqual($0 as? ReleaseInstall.Problem, .runningFromDiskImageOrQuarantine, path)
            }
        }
    }

    func testAWritableFolderIsFineAndAReadOnlyOneIsNot() throws {
        XCTAssertNoThrow(try ReleaseInstall.checkReplaceable(appURL: root.appendingPathComponent("AnyWhere.app")))
        let locked = root.appendingPathComponent("locked")
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        XCTAssertThrowsError(try ReleaseInstall.checkReplaceable(appURL: locked.appendingPathComponent("AnyWhere.app"))) {
            XCTAssertEqual($0 as? ReleaseInstall.Problem, .folderNotWritable("locked"))
        }
    }

    // MARK: Checking the download

    func testChecksumMustBePresentAndMatch() throws {
        let file = root.appendingPathComponent("AnyWhere-2.4.0.dmg")
        try Data("abc".utf8).write(to: file)
        let good = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  AnyWhere-2.4.0.dmg\n"
        XCTAssertNoThrow(try ReleaseInstall.verifyDownload(file, checksums: good, name: "AnyWhere-2.4.0.dmg"))

        let bad = String(repeating: "0", count: 64) + "  AnyWhere-2.4.0.dmg\n"
        XCTAssertThrowsError(try ReleaseInstall.verifyDownload(file, checksums: bad, name: "AnyWhere-2.4.0.dmg")) {
            XCTAssertEqual($0 as? ReleaseInstall.Problem, .checksumMismatch)
        }
        // No checksum file, or no line for this name: refused, never skipped.
        XCTAssertThrowsError(try ReleaseInstall.verifyDownload(file, checksums: nil, name: "AnyWhere-2.4.0.dmg")) {
            XCTAssertEqual($0 as? ReleaseInstall.Problem, .checksumMissing)
        }
        XCTAssertThrowsError(try ReleaseInstall.verifyDownload(file, checksums: good, name: "Other.dmg")) {
            XCTAssertEqual($0 as? ReleaseInstall.Problem, .checksumMissing)
        }
    }

    // MARK: Staging

    func testStagesASignedAppFromARealDiskImageAndRunsTheSelfTest() throws {
        let source = root.appendingPathComponent("src")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try makeApp(at: source, marker: "from-dmg")
        let dmg = try makeDMG(containing: source)
        let destination = root.appendingPathComponent("Applications")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        var testedApp: URL?
        let staged = try ReleaseInstall.stage(dmg: dmg, beside: destination) { testedApp = $0 }

        XCTAssertEqual(testedApp, staged, "the self-test runs on the copy that will be installed")
        XCTAssertEqual(staged.lastPathComponent, "AnyWhere.app")
        XCTAssertEqual(staged.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path,
                       destination.standardizedFileURL.path, "staged beside the destination, so the final move is a rename")
        XCTAssertEqual(marker(of: staged), "from-dmg")
        // The disk image is closed again.
        let info = try ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), arguments: ["info"], timeout: 30)
        XCTAssertFalse(info.stdout.contains(dmg.lastPathComponent), "the DMG should be detached")
        XCTAssertEqual(ReleaseInstall.attachedDevices(of: dmg), [])
    }

    /// What `stage` cleans up with: the devices open from one image, found by its path.
    func testFindsTheDevicesOpenFromADiskImage() throws {
        let source = root.appendingPathComponent("src")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try makeApp(at: source)
        let dmg = try makeDMG(containing: source)
        let mount = root.appendingPathComponent("mnt")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        let attach = try ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/hdiutil"),
                                           arguments: ["attach", dmg.path, "-nobrowse", "-readonly", "-noverify",
                                                       "-mountpoint", mount.path, "-quiet"], timeout: 120)
        try XCTSkipIf(attach.status != 0, "hdiutil couldn't open a disk image here")
        let devices = ReleaseInstall.attachedDevices(of: dmg)
        XCTAssertEqual(devices.count, 1)
        XCTAssertTrue(devices.first?.hasPrefix("/dev/disk") == true)
        ReleaseInstall.detachAll(of: dmg)
        XCTAssertEqual(ReleaseInstall.attachedDevices(of: dmg), [], "closed")
    }

    func testAFailingSelfTestLeavesNothingBehind() throws {
        let source = root.appendingPathComponent("src")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try makeApp(at: source)
        let dmg = try makeDMG(containing: source)
        let destination = root.appendingPathComponent("Applications")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        XCTAssertThrowsError(try ReleaseInstall.stage(dmg: dmg, beside: destination) { _ in
            throw ReleaseInstall.Problem.selfTestFailed("crashed")
        }) { XCTAssertEqual($0 as? ReleaseInstall.Problem, .selfTestFailed("crashed")) }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: destination.path), [], "the staging folder is cleaned up")
    }

    func testADiskImageWithoutTheAppIsRefused() throws {
        let source = root.appendingPathComponent("src")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try "hi".write(to: source.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        let dmg = try makeDMG(containing: source)
        let destination = root.appendingPathComponent("Applications")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ReleaseInstall.stage(dmg: dmg, beside: destination) { _ in }) {
            XCTAssertEqual($0 as? ReleaseInstall.Problem, .noAppInDiskImage)
        }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: destination.path), [])
    }

    func testSomethingThatIsNotADiskImageIsRefused() throws {
        let junk = root.appendingPathComponent("junk.dmg")
        try Data("not a disk image".utf8).write(to: junk)
        XCTAssertThrowsError(try ReleaseInstall.stage(dmg: junk, beside: root) { _ in }) {
            guard case .couldNotMount = $0 as? ReleaseInstall.Problem else { return XCTFail("\($0)") }
        }
    }

    func testAnAppWithABadSignatureIsRefused() throws {
        let source = root.appendingPathComponent("src")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        let app = try makeApp(at: source)
        // Change a file after signing: the seal no longer matches.
        try "tampered".write(to: app.appendingPathComponent("Contents/Resources/marker.txt"), atomically: true, encoding: .utf8)
        let dmg = try makeDMG(containing: source)
        let destination = root.appendingPathComponent("Applications")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ReleaseInstall.stage(dmg: dmg, beside: destination) { _ in XCTFail("self-test must not run") }) {
            XCTAssertEqual($0 as? ReleaseInstall.Problem, .badSignature)
        }
    }

    // MARK: The self-test itself

    func testSelfTestPassesWhenTheAppSaysOK() throws {
        let app = try makeApp(at: root)
        XCTAssertNoThrow(try ReleaseInstall.runSelfTest(of: app))
    }

    func testSelfTestFailsOnACrashOrSilence() throws {
        let crash = try makeApp(at: root.appendingPathComponent("a", isDirectory: true).createdFolder(), output: "boom", status: 3)
        XCTAssertThrowsError(try ReleaseInstall.runSelfTest(of: crash)) {
            guard case .selfTestFailed = $0 as? ReleaseInstall.Problem else { return XCTFail("\($0)") }
        }
        // Exits 0 but never prints the OK line (so it didn't actually run the app).
        let silent = try makeApp(at: root.appendingPathComponent("b", isDirectory: true).createdFolder(), output: "hello", status: 0)
        XCTAssertThrowsError(try ReleaseInstall.runSelfTest(of: silent))
    }

    // MARK: Swapping

    func testSwapPutsTheNewAppInPlaceAndKeepsTheOldOneAsABackup() throws {
        let apps = root.appendingPathComponent("Applications")
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        let current = try makeApp(at: apps, marker: "old")
        let staging = apps.appendingPathComponent(".stage")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let staged = try makeApp(at: staging, marker: "new")

        let backupFolder = try ReleaseInstall.swap(current: current, with: staged)

        XCTAssertEqual(marker(of: current), "new")
        XCTAssertEqual(marker(of: backupFolder.appendingPathComponent("AnyWhere.app")), "old")
        XCTAssertFalse(fm.fileExists(atPath: staging.path), "the staging folder is gone")
    }

    func testSwapPutsTheOldAppBackWhenTheNewOneCannotBeMoved() throws {
        let apps = root.appendingPathComponent("Applications")
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        let current = try makeApp(at: apps, marker: "old")
        let missing = apps.appendingPathComponent(".nothing/AnyWhere.app")

        XCTAssertThrowsError(try ReleaseInstall.swap(current: current, with: missing)) {
            guard case .swapFailed = $0 as? ReleaseInstall.Problem else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(marker(of: current), "old", "the working app is back")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: apps.path), ["AnyWhere.app"], "no backup folder is left over")
    }
}

private extension URL {
    @discardableResult
    func createdFolder() throws -> URL {
        try FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
        return self
    }
}
