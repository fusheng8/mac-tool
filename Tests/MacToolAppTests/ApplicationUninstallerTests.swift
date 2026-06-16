import Foundation
import XCTest
@testable import MacToolApp

final class ApplicationUninstallerTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testScanCoversConfiguredApplicationRootsAndSafetySkips() throws {
        let fixture = try makeFixture()
        try makeApp(at: fixture.applications.appendingPathComponent("TestApp.app"), bundleID: "com.example.TestApp", displayName: "TestApp")
        try makeApp(at: fixture.homeApplications.appendingPathComponent("HomeOnly.app"), bundleID: "com.example.HomeOnly", displayName: "HomeOnly")
        try makeApp(at: fixture.systemInputMethods.appendingPathComponent("Input.app"), bundleID: "com.example.Input", displayName: "Input")
        try makeApp(at: fixture.userInputMethods.appendingPathComponent("UserInput.app"), bundleID: "com.example.UserInput", displayName: "UserInput")
        try makeApp(at: fixture.volumeApplications.appendingPathComponent("VolumeApp.app"), bundleID: "com.example.VolumeApp", displayName: "VolumeApp")
        try makeApp(at: fixture.applications.appendingPathComponent("Safari.app"), bundleID: "com.apple.Safari", displayName: "Safari")
        try makeApp(at: fixture.applications.appendingPathComponent("Background.app"), bundleID: "com.example.Background", displayName: "Background", extraPlist: ["LSBackgroundOnly": true])
        try makeApp(at: fixture.applications.appendingPathComponent("Outer.app"), bundleID: "com.example.Outer", displayName: "Outer")
        try makeApp(at: fixture.applications.appendingPathComponent("Outer.app/Contents/Helpers/Nested.app"), bundleID: "com.example.Nested", displayName: "Nested")

        let apps = fixture.uninstaller.scanApplications()
        let bundleIDs = Set(apps.map(\.bundleID))

        XCTAssertTrue(bundleIDs.contains("com.example.TestApp"))
        XCTAssertTrue(bundleIDs.contains("com.example.HomeOnly"))
        XCTAssertTrue(bundleIDs.contains("com.example.Input"))
        XCTAssertTrue(bundleIDs.contains("com.example.UserInput"))
        XCTAssertTrue(bundleIDs.contains("com.example.VolumeApp"))
        XCTAssertTrue(bundleIDs.contains("com.example.Outer"))
        XCTAssertFalse(bundleIDs.contains("com.example.Nested"))
        XCTAssertNotNil(apps.first(where: { $0.bundleID == "com.apple.Safari" })?.protectedReason)
        XCTAssertNotNil(apps.first(where: { $0.bundleID == "com.example.Background" })?.protectedReason)
    }

    func testPlanFindsUserRemnantsAndKeepsSystemRemnantsReviewOnly() throws {
        let fixture = try makeFixture()
        let appURL = fixture.applications.appendingPathComponent("TestApp.app")
        try makeApp(at: appURL, bundleID: "com.example.TestApp", displayName: "TestApp")

        let userPaths = [
            fixture.home.appendingPathComponent("Library/Application Support/TestApp"),
            fixture.home.appendingPathComponent("Library/Caches/com.example.TestApp"),
            fixture.home.appendingPathComponent("Library/Preferences/com.example.TestApp.plist"),
            fixture.home.appendingPathComponent("Library/Preferences/ByHost/com.example.TestApp.123.plist"),
            fixture.home.appendingPathComponent("Library/Saved Application State/com.example.TestApp.savedState"),
            fixture.home.appendingPathComponent("Library/Containers/com.example.TestApp"),
            fixture.home.appendingPathComponent("Library/LaunchAgents/com.example.TestApp.helper.plist"),
            fixture.home.appendingPathComponent(".cache/testapp")
        ]
        for path in userPaths {
            try createFileOrDirectory(path)
        }
        let systemPaths = [
            fixture.systemLibrary.appendingPathComponent("Application Support/TestApp"),
            fixture.systemLibrary.appendingPathComponent("LaunchDaemons/com.example.TestApp.helper.plist")
        ]
        for path in systemPaths {
            try createFileOrDirectory(path)
        }

        let app = try XCTUnwrap(fixture.uninstaller.scanApplications().first { $0.bundleID == "com.example.TestApp" })
        let plan = fixture.uninstaller.makePlan(for: app)
        let trashPaths = Set(plan.trashItems.compactMap { $0.url?.path })
        let reviewPaths = Set(plan.reviewOnlyItems.compactMap { $0.url?.path })

        XCTAssertTrue(trashPaths.contains(appURL.path))
        for path in userPaths {
            XCTAssertTrue(trashPaths.contains(path.path), "Missing user remnant \(path.path)")
        }
        for path in systemPaths {
            XCTAssertTrue(reviewPaths.contains(path.path), "Missing review-only remnant \(path.path)")
            XCTAssertFalse(trashPaths.contains(path.path), "System remnant must not be deletable by default")
        }
    }

    func testLaunchAgentBoundaryDoesNotMatchSiblingVendor() throws {
        let fixture = try makeFixture()
        try makeApp(at: fixture.applications.appendingPathComponent("Foo.app"), bundleID: "com.foo", displayName: "Foo")
        let matched = [
            fixture.systemLibrary.appendingPathComponent("LaunchDaemons/com.foo.plist"),
            fixture.systemLibrary.appendingPathComponent("LaunchDaemons/com.foo.helper.plist")
        ]
        let sibling = fixture.systemLibrary.appendingPathComponent("LaunchDaemons/com.foobar.plist")
        for path in matched + [sibling] {
            try createFileOrDirectory(path)
        }

        let app = try XCTUnwrap(fixture.uninstaller.scanApplications().first { $0.bundleID == "com.foo" })
        let plan = fixture.uninstaller.makePlan(for: app)
        let reviewPaths = Set(plan.reviewOnlyItems.compactMap { $0.url?.path })

        for path in matched {
            XCTAssertTrue(reviewPaths.contains(path.path))
        }
        XCTAssertFalse(reviewPaths.contains(sibling.path))
    }

    func testExecuteMovesOnlyTrashItemsAndLeavesReviewOnlySystemFiles() throws {
        let fixture = try makeFixture()
        let appURL = fixture.applications.appendingPathComponent("TestApp.app")
        try makeApp(at: appURL, bundleID: "com.example.TestApp", displayName: "TestApp")
        let userCache = fixture.home.appendingPathComponent("Library/Caches/com.example.TestApp")
        let systemDaemon = fixture.systemLibrary.appendingPathComponent("LaunchDaemons/com.example.TestApp.helper.plist")
        try createFileOrDirectory(userCache)
        try createFileOrDirectory(systemDaemon)

        let app = try XCTUnwrap(fixture.uninstaller.scanApplications().first { $0.bundleID == "com.example.TestApp" })
        let plan = fixture.uninstaller.makePlan(for: app)
        let result = try fixture.uninstaller.execute(plan: plan)

        XCTAssertTrue(result.succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: appURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: userCache.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.trash.appendingPathComponent("TestApp.app").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.trash.appendingPathComponent("com.example.TestApp").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemDaemon.path))
    }

    func testPlanWarnsForLocalNetworkAndLoginItemHelpers() throws {
        let fixture = try makeFixture()
        let appURL = fixture.applications.appendingPathComponent("NetworkApp.app")
        try makeApp(
            at: appURL,
            bundleID: "com.example.NetworkApp",
            displayName: "NetworkApp",
            extraPlist: [
                "NSLocalNetworkUsageDescription": "Find devices",
                "NSBonjourServices": ["_http._tcp"]
            ]
        )
        try makeApp(
            at: appURL.appendingPathComponent("Contents/Library/LoginItems/NetworkHelper.app"),
            bundleID: "com.example.NetworkApp.helper",
            displayName: "NetworkHelper"
        )

        let app = try XCTUnwrap(fixture.uninstaller.scanApplications().first { $0.bundleID == "com.example.NetworkApp" })
        let plan = fixture.uninstaller.makePlan(for: app)
        let warningText = plan.warnings.joined(separator: "\n")

        XCTAssertTrue(warningText.contains("Local Network"))
        XCTAssertTrue(warningText.contains("com.example.NetworkApp.helper"))
    }

    func testOfficialUninstallerRulesBlockEnterpriseAgents() throws {
        let fixture = try makeFixture()
        try makeApp(at: fixture.applications.appendingPathComponent("Falcon.app"), bundleID: "com.crowdstrike.falcon.App", displayName: "Falcon")

        let app = try XCTUnwrap(fixture.uninstaller.scanApplications().first { $0.bundleID == "com.crowdstrike.falcon.App" })
        let plan = fixture.uninstaller.makePlan(for: app)

        XCTAssertEqual(app.officialUninstallerVendor, "CrowdStrike")
        XCTAssertTrue(plan.isBlocked)
        XCTAssertTrue(plan.warnings.joined(separator: "\n").contains("官方卸载器"))
    }

    func testSensitiveApplicationsWarnWithoutBlockingTrashPlan() throws {
        let fixture = try makeFixture()
        let appURL = fixture.applications.appendingPathComponent("Code.app")
        try makeApp(at: appURL, bundleID: "com.microsoft.VSCode", displayName: "Code")

        let app = try XCTUnwrap(fixture.uninstaller.scanApplications().first { $0.bundleID == "com.microsoft.VSCode" })
        let plan = fixture.uninstaller.makePlan(for: app)

        XCTAssertFalse(plan.isBlocked)
        XCTAssertTrue(plan.trashItems.contains { $0.url?.path == appURL.path })
        XCTAssertTrue(plan.warnings.joined(separator: "\n").contains("敏感数据"))
    }

    func testSymlinkToCriticalSystemPathIsSkipped() throws {
        let fixture = try makeFixture()
        let link = fixture.applications.appendingPathComponent("SystemLink.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/System/Applications/Safari.app"))

        let apps = fixture.uninstaller.scanApplications()

        XCTAssertFalse(apps.contains { $0.path == link })
    }

    func testDiagnosticReportsAreMatchedByExecutablePrefix() throws {
        let fixture = try makeFixture()
        let appURL = fixture.applications.appendingPathComponent("Crashy.app")
        try makeApp(at: appURL, bundleID: "com.example.Crashy", displayName: "Crashy")
        let report = fixture.home.appendingPathComponent("Library/Logs/DiagnosticReports/Crashy_2026-06-15.crash")
        try createFileOrDirectory(report)

        let app = try XCTUnwrap(fixture.uninstaller.scanApplications().first { $0.bundleID == "com.example.Crashy" })
        let plan = fixture.uninstaller.makePlan(for: app)

        XCTAssertTrue(plan.trashItems.contains { $0.url?.path == report.path && $0.category == .diagnosticReport })
    }

    func testDisplayNamePathComponentsDoNotRedirectRemnantScan() throws {
        let fixture = try makeFixture()
        let appURL = fixture.applications.appendingPathComponent("Traversal.app")
        try makeApp(at: appURL, bundleID: "com.example.Traversal", displayName: "../Victim")
        let unrelated = fixture.home.appendingPathComponent("Library/Victim", isDirectory: true)
        try createFileOrDirectory(unrelated)

        let app = try XCTUnwrap(fixture.uninstaller.scanApplications().first { $0.bundleID == "com.example.Traversal" })
        let plan = fixture.uninstaller.makePlan(for: app)

        XCTAssertEqual(app.displayName, "Traversal")
        XCTAssertFalse(plan.trashItems.contains { $0.url?.standardizedFileURL.path == unrelated.standardizedFileURL.path })
    }

    func testHomebrewCaskRefusesManualFallbackWhenBrewStillTracksCask() throws {
        let runner = StubCommandRunner { executable, arguments, _, _ in
            if executable.lastPathComponent == "brew" {
                if arguments == ["list", "--cask"] {
                    return CommandOutput(exitCode: 0, stdout: "cool-app\n", stderr: "")
                }
                if arguments == ["uninstall", "--cask", "--zap", "cool-app"] {
                    return CommandOutput(exitCode: 1, stdout: "", stderr: "failed")
                }
            }
            return CommandOutput(exitCode: 0, stdout: "", stderr: "")
        }
        let fixture = try makeFixture(runExternalCommands: true, runner: runner)
        let brew = fixture.brewBin.appendingPathComponent("brew")
        try "#!/bin/sh\n".write(to: brew, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path)

        let caskApp = fixture.caskroom.appendingPathComponent("cool-app/1.0/Cool App.app")
        try makeApp(at: caskApp, bundleID: "com.example.CoolApp", displayName: "Cool App")
        let linkedApp = fixture.applications.appendingPathComponent("Cool App.app")
        try FileManager.default.createSymbolicLink(at: linkedApp, withDestinationURL: caskApp)

        let app = try XCTUnwrap(fixture.uninstaller.scanApplications().first { $0.bundleID == "com.example.CoolApp" })
        XCTAssertEqual(app.source, .homebrewCask)
        XCTAssertEqual(app.homebrewCask, "cool-app")

        let plan = fixture.uninstaller.makePlan(for: app)
        let result = try fixture.uninstaller.execute(plan: plan)

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: linkedApp.path))
        XCTAssertTrue(plan.items.contains { $0.category == .homebrew && $0.action == .command })
        XCTAssertTrue(result.warnings.joined(separator: "\n").contains("拒绝手动删除"))
    }

    func testHomebrewCaskDetectionRequiresSelectedAppToPointIntoCaskroom() throws {
        let runner = StubCommandRunner { executable, arguments, _, _ in
            if executable.lastPathComponent == "brew", arguments == ["list", "--cask"] {
                return CommandOutput(exitCode: 0, stdout: "cool-app\n", stderr: "")
            }
            return CommandOutput(exitCode: 0, stdout: "", stderr: "")
        }
        let fixture = try makeFixture(runExternalCommands: true, runner: runner)
        let brew = fixture.brewBin.appendingPathComponent("brew")
        try "#!/bin/sh\n".write(to: brew, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path)

        let caskApp = fixture.caskroom.appendingPathComponent("cool-app/1.0/Cool App.app")
        try makeApp(at: caskApp, bundleID: "com.example.CoolApp", displayName: "Cool App")
        let selectedApp = fixture.applications.appendingPathComponent("Cool App.app")
        try makeApp(at: selectedApp, bundleID: "com.example.CoolApp", displayName: "Cool App")

        let selectedPath = selectedApp.standardizedFileURL.path
        let app = try XCTUnwrap(fixture.uninstaller.scanApplications().first { $0.path.standardizedFileURL.path == selectedPath })
        let plan = fixture.uninstaller.makePlan(for: app)

        XCTAssertEqual(app.source, .applicationBundle)
        XCTAssertNil(app.homebrewCask)
        XCTAssertFalse(plan.commandItems.contains { $0.category == .homebrew })
    }

    func testConfiguredTrashSymlinkIsRejectedWithoutMovingApp() throws {
        let fixture = try makeFixture()
        try FileManager.default.removeItem(at: fixture.trash)
        let redirectedTrash = fixture.root.appendingPathComponent("RedirectedTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: redirectedTrash, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.trash, withDestinationURL: redirectedTrash)

        let appURL = fixture.applications.appendingPathComponent("TrashGuard.app")
        try makeApp(at: appURL, bundleID: "com.example.TrashGuard", displayName: "TrashGuard")

        let app = try XCTUnwrap(fixture.uninstaller.scanApplications().first { $0.bundleID == "com.example.TrashGuard" })
        let plan = fixture.uninstaller.makePlan(for: app)
        let result = try fixture.uninstaller.execute(plan: plan)

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: appURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: redirectedTrash.appendingPathComponent("TrashGuard.app").path))
        XCTAssertTrue(result.itemResults.contains { !$0.success && $0.message.contains("废纸篓不是普通目录") })
    }

    func testPkgReceiptAppsOutsideAllowlistAreIgnored() throws {
        let badApp = "Untrusted/Bad.app"
        let runner = pkgutilRunner(files: ["\(badApp)/Contents/Info.plist"], installLocation: { self.fixturePathMarker })
        let fixture = try makeFixture(runExternalCommands: true, runner: runner)
        try makeApp(at: fixture.root.appendingPathComponent(badApp), bundleID: "com.example.Bad", displayName: "Bad")
        fixturePathMarker = fixture.root.path

        let apps = fixture.uninstaller.scanApplications()

        XCTAssertFalse(apps.contains { $0.bundleID == "com.example.Bad" })
    }

    func testPkgReceiptAppsInsideAllowlistCanRemoveBundle() throws {
        let receiptPath = "Vendor/ReceiptApp.app"
        let runner = pkgutilRunner(files: ["\(receiptPath)/Contents/Info.plist"], installLocation: { self.fixturePathMarker })
        let fixture = try makeFixture(runExternalCommands: true, runner: runner)
        try makeApp(at: fixture.opt.appendingPathComponent(receiptPath), bundleID: "com.example.ReceiptApp", displayName: "ReceiptApp")
        fixturePathMarker = fixture.opt.path

        let app = try XCTUnwrap(fixture.uninstaller.scanApplications().first { $0.bundleID == "com.example.ReceiptApp" })
        let plan = fixture.uninstaller.makePlan(for: app)

        XCTAssertFalse(plan.isBlocked)
        XCTAssertTrue(plan.trashItems.contains { $0.url?.path == fixture.opt.appendingPathComponent(receiptPath).path })
    }

    func testDryRunDoesNotMoveFilesAndWritesAudit() throws {
        let fixture = try makeFixture()
        let appURL = fixture.applications.appendingPathComponent("DryRun.app")
        let cache = fixture.home.appendingPathComponent("Library/Caches/com.example.DryRun")
        try makeApp(at: appURL, bundleID: "com.example.DryRun", displayName: "DryRun")
        try createFileOrDirectory(cache)

        let app = try XCTUnwrap(fixture.uninstaller.scanApplications().first { $0.bundleID == "com.example.DryRun" })
        let plan = fixture.uninstaller.makePlan(for: app)
        let result = try fixture.uninstaller.execute(plan: plan, options: .dryRun())

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: appURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.trash.appendingPathComponent("DryRun.app").path))
        let audit = try String(contentsOf: fixture.root.appendingPathComponent("Logs/uninstall-audit.log"))
        XCTAssertTrue(audit.contains(#""status":"dry-run""#))
        XCTAssertTrue(audit.contains(#""mode":"dry-run""#))
    }

    func testHomebrewUnknownStateRefusesManualFallbackAndUsesNonInteractiveEnvironment() throws {
        var uninstallEnvironment: [String: String] = [:]
        let runner = StubCommandRunner { executable, arguments, _, environment in
            if executable.lastPathComponent == "brew" {
                if arguments == ["uninstall", "--cask", "--zap", "cool-app"] {
                    uninstallEnvironment = environment
                    return CommandOutput(exitCode: 1, stdout: "", stderr: "failed")
                }
                if arguments == ["list", "--cask"] {
                    return CommandOutput(exitCode: 2, stdout: "", stderr: "brew unavailable")
                }
            }
            return CommandOutput(exitCode: 0, stdout: "", stderr: "")
        }
        let fixture = try makeFixture(runExternalCommands: true, runner: runner)
        let brew = fixture.brewBin.appendingPathComponent("brew")
        try "#!/bin/sh\n".write(to: brew, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path)

        let appURL = fixture.applications.appendingPathComponent("Cool App.app")
        try makeApp(at: appURL, bundleID: "com.example.CoolApp", displayName: "Cool App")
        let app = InstalledApplication(
            id: appURL.path,
            displayName: "Cool App",
            bundleID: "com.example.CoolApp",
            version: "1.0",
            path: appURL,
            source: .homebrewCask,
            homebrewCask: "cool-app",
            sizeBytes: 0,
            lastUsedDate: nil,
            requiresAdmin: false,
            protectedReason: nil,
            officialUninstallerVendor: nil,
            isRunning: false
        )

        let plan = fixture.uninstaller.makePlan(for: app)
        let result = try fixture.uninstaller.execute(plan: plan)

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: appURL.path))
        XCTAssertEqual(uninstallEnvironment["HOMEBREW_NO_ENV_HINTS"], "1")
        XCTAssertEqual(uninstallEnvironment["HOMEBREW_NO_AUTO_UPDATE"], "1")
        XCTAssertEqual(uninstallEnvironment["NONINTERACTIVE"], "1")
        XCTAssertTrue(result.warnings.joined(separator: "\n").contains("无法确认 Homebrew cask 状态"))
    }

    func testAndroidStudioOnlyAddsRegenerableCaches() throws {
        let fixture = try makeFixture()
        let appURL = fixture.applications.appendingPathComponent("Android Studio.app")
        try makeApp(at: appURL, bundleID: "com.google.android.studio", displayName: "Android Studio")
        let allowed = [
            fixture.home.appendingPathComponent(".android/cache"),
            fixture.home.appendingPathComponent(".android/build-cache"),
            fixture.home.appendingPathComponent(".android/breakpad")
        ]
        let protected = [
            fixture.home.appendingPathComponent(".android/adbkey"),
            fixture.home.appendingPathComponent(".android/debug.keystore"),
            fixture.home.appendingPathComponent(".android/avd"),
            fixture.home.appendingPathComponent("Library/Android"),
            fixture.home.appendingPathComponent(".gradle/caches/modules-2/files-2.1/com.android.tools.build")
        ]
        for path in allowed + protected {
            try createFileOrDirectory(path)
        }

        let app = try XCTUnwrap(fixture.uninstaller.scanApplications().first { $0.bundleID == "com.google.android.studio" })
        let plan = fixture.uninstaller.makePlan(for: app)
        let trashPaths = Set(plan.trashItems.compactMap { $0.url?.path })

        for path in allowed {
            XCTAssertTrue(trashPaths.contains(path.path), "Missing regenerable cache \(path.path)")
        }
        for path in protected {
            XCTAssertFalse(trashPaths.contains(path.path), "Protected Android state must not be trashable \(path.path)")
        }
    }

    func testXcodeSpecialRemnantsExcludeArchivesAndUserData() throws {
        let fixture = try makeFixture()
        let appURL = fixture.applications.appendingPathComponent("Xcode.app")
        try makeApp(at: appURL, bundleID: "com.apple.dt.Xcode", displayName: "Xcode")
        let allowed = [
            fixture.home.appendingPathComponent("Library/Developer/Xcode/DerivedData"),
            fixture.home.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport"),
            fixture.home.appendingPathComponent("Library/Developer/CoreSimulator/Caches")
        ]
        let protected = [
            fixture.home.appendingPathComponent("Library/Developer/Xcode/Archives"),
            fixture.home.appendingPathComponent("Library/Developer/Xcode/UserData"),
            fixture.home.appendingPathComponent("Library/Developer/CoreSimulator/Devices"),
            fixture.home.appendingPathComponent("Library/MobileDevice/Provisioning Profiles")
        ]
        for path in allowed + protected {
            try createFileOrDirectory(path)
        }

        let app = InstalledApplication(
            id: appURL.path,
            displayName: "Xcode",
            bundleID: "com.apple.dt.Xcode",
            version: "1.0",
            path: appURL,
            source: .applicationBundle,
            homebrewCask: nil,
            sizeBytes: 0,
            lastUsedDate: nil,
            requiresAdmin: false,
            protectedReason: nil,
            officialUninstallerVendor: nil,
            isRunning: false
        )
        let plan = fixture.uninstaller.makePlan(for: app)
        let trashPaths = Set(plan.trashItems.compactMap { $0.url?.path })

        for path in allowed {
            XCTAssertTrue(trashPaths.contains(path.path), "Missing Xcode regenerable cache \(path.path)")
        }
        for path in protected {
            XCTAssertFalse(trashPaths.contains(path.path), "Protected Xcode state must not be trashable \(path.path)")
        }
    }

    func testJetBrainsOnlyMatchesCurrentProductCachesAndLogs() throws {
        let fixture = try makeFixture()
        let appURL = fixture.applications.appendingPathComponent("IntelliJ IDEA.app")
        try makeApp(at: appURL, bundleID: "com.jetbrains.intellij", displayName: "IntelliJ IDEA")
        let intellijCache = fixture.home.appendingPathComponent("Library/Caches/JetBrains/IntelliJIdea2026.1")
        let intellijLog = fixture.home.appendingPathComponent("Library/Logs/JetBrains/IntelliJIdea2026.1")
        let support = fixture.home.appendingPathComponent("Library/Application Support/JetBrains/IntelliJIdea2026.1")
        let pycharmCache = fixture.home.appendingPathComponent("Library/Caches/JetBrains/PyCharm2026.1")
        let preferences = fixture.home.appendingPathComponent("Library/Preferences/com.jetbrains.intellij.plist")
        for path in [intellijCache, intellijLog, support, pycharmCache, preferences] {
            try createFileOrDirectory(path)
        }

        let app = try XCTUnwrap(fixture.uninstaller.scanApplications().first { $0.bundleID == "com.jetbrains.intellij" })
        let plan = fixture.uninstaller.makePlan(for: app)
        let trashPaths = Set(plan.trashItems.compactMap { $0.url?.path })

        XCTAssertTrue(trashPaths.contains(intellijCache.path))
        XCTAssertTrue(trashPaths.contains(intellijLog.path))
        XCTAssertFalse(trashPaths.contains(support.path))
        XCTAssertFalse(trashPaths.contains(pycharmCache.path))
        XCTAssertFalse(trashPaths.contains(preferences.path))
    }

    func testNamesakeCliRootsAreExcludedFromPlan() throws {
        let fixture = try makeFixture()
        let appURL = fixture.applications.appendingPathComponent("Claude.app")
        try makeApp(at: appURL, bundleID: "com.anthropic.claude", displayName: "Claude")
        let cliRoots = [
            fixture.home.appendingPathComponent(".claude"),
            fixture.home.appendingPathComponent(".config/claude"),
            fixture.home.appendingPathComponent(".cache/claude"),
            fixture.home.appendingPathComponent(".local/share/claude")
        ]
        for path in cliRoots {
            try createFileOrDirectory(path)
        }

        let app = try XCTUnwrap(fixture.uninstaller.scanApplications().first { $0.bundleID == "com.anthropic.claude" })
        let plan = fixture.uninstaller.makePlan(for: app)
        let trashPaths = Set(plan.trashItems.compactMap { $0.url?.path })
        let reviewPaths = Set(plan.reviewOnlyItems.compactMap { $0.url?.path })

        for path in cliRoots {
            XCTAssertFalse(trashPaths.contains(path.path))
            XCTAssertFalse(reviewPaths.contains(path.path))
        }
    }

    func testInjectedProtectedDeveloperDataPathFailsAtExecute() throws {
        let fixture = try makeFixture()
        let appURL = fixture.applications.appendingPathComponent("Injected.app")
        let protectedPath = fixture.home.appendingPathComponent("Library/Developer/Xcode/Archives")
        try makeApp(at: appURL, bundleID: "com.example.Injected", displayName: "Injected")
        try createFileOrDirectory(protectedPath)
        let app = try XCTUnwrap(fixture.uninstaller.scanApplications().first { $0.bundleID == "com.example.Injected" })
        let item = ApplicationUninstallItem(
            id: "injected",
            url: protectedPath,
            displayName: protectedPath.path,
            category: .userSupport,
            action: .moveToTrash,
            requiresAdmin: false,
            sizeBytes: 0,
            detail: nil
        )
        let plan = ApplicationUninstallPlan(
            id: UUID(),
            application: app,
            items: [item],
            warnings: [],
            blockedReason: nil,
            estimatedRecoverableBytes: 0,
            estimatedReviewOnlyBytes: 0
        )

        let result = try fixture.uninstaller.execute(plan: plan)

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: protectedPath.path))
        XCTAssertTrue(result.itemResults.contains { !$0.success && $0.message.contains("路径不安全") })
    }

    func testInjectedApplicationBundleIsRejectedUnlessItIsThePlannedAppBundle() throws {
        let fixture = try makeFixture()
        let appURL = fixture.applications.appendingPathComponent("Primary.app")
        let injectedApp = fixture.applications.appendingPathComponent("InjectedOther.app")
        try makeApp(at: appURL, bundleID: "com.example.Primary", displayName: "Primary")
        try makeApp(at: injectedApp, bundleID: "com.example.InjectedOther", displayName: "InjectedOther")
        let app = try XCTUnwrap(fixture.uninstaller.scanApplications().first { $0.bundleID == "com.example.Primary" })
        let item = ApplicationUninstallItem(
            id: "injected-app",
            url: injectedApp,
            displayName: injectedApp.path,
            category: .userSupport,
            action: .moveToTrash,
            requiresAdmin: false,
            sizeBytes: 0,
            detail: nil
        )
        let plan = ApplicationUninstallPlan(
            id: UUID(),
            application: app,
            items: [item],
            warnings: [],
            blockedReason: nil,
            estimatedRecoverableBytes: 0,
            estimatedReviewOnlyBytes: 0
        )

        let result = try fixture.uninstaller.execute(plan: plan)

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: injectedApp.path))
        XCTAssertTrue(result.itemResults.contains { !$0.success && $0.message.contains("路径不安全") })
    }

    func testProtectedUserStateRootsRejectInjectedTrashItems() throws {
        let fixture = try makeFixture()
        let appURL = fixture.applications.appendingPathComponent("StateGuard.app")
        try makeApp(at: appURL, bundleID: "com.example.StateGuard", displayName: "StateGuard")
        let protectedPaths = [
            fixture.home.appendingPathComponent("Library/Keychains/login.keychain-db"),
            fixture.home.appendingPathComponent("Library/Accounts/Accounts4.sqlite"),
            fixture.home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs"),
            fixture.home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db"),
            fixture.home.appendingPathComponent("Library/Application Support/CloudDocs/session.db"),
            fixture.home.appendingPathComponent("Library/Preferences/com.apple.dock.plist"),
            fixture.home.appendingPathComponent("Library/Preferences/com.apple.systemuiserver.plist")
        ]
        for path in protectedPaths {
            try createFileOrDirectory(path)
        }
        let app = try XCTUnwrap(fixture.uninstaller.scanApplications().first { $0.bundleID == "com.example.StateGuard" })
        let items = protectedPaths.map {
            ApplicationUninstallItem(
                id: "protected-\($0.path)",
                url: $0,
                displayName: $0.path,
                category: .userSupport,
                action: .moveToTrash,
                requiresAdmin: false,
                sizeBytes: 0,
                detail: nil
            )
        }
        let plan = ApplicationUninstallPlan(
            id: UUID(),
            application: app,
            items: items,
            warnings: [],
            blockedReason: nil,
            estimatedRecoverableBytes: 0,
            estimatedReviewOnlyBytes: 0
        )

        let result = try fixture.uninstaller.execute(plan: plan)

        XCTAssertFalse(result.succeeded)
        for path in protectedPaths {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path.path), "Protected path moved: \(path.path)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.trash.appendingPathComponent(path.lastPathComponent).path))
        }
        XCTAssertEqual(result.itemResults.filter { !$0.success && $0.message.contains("路径不安全") }.count, protectedPaths.count)
        let audit = try String(contentsOf: fixture.root.appendingPathComponent("Logs/uninstall-audit.log"))
        XCTAssertFalse(audit.contains(#""status":"trashed""#))
    }

    func testSharedFileListSystemUIStateIsReviewOnly() throws {
        let fixture = try makeFixture()
        let appURL = fixture.applications.appendingPathComponent("RecentDoc.app")
        try makeApp(at: appURL, bundleID: "com.example.RecentDoc", displayName: "RecentDoc")
        let sharedFileList = fixture.home
            .appendingPathComponent("Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/com.example.RecentDoc.sfl4")
        try createFileOrDirectory(sharedFileList)

        let app = try XCTUnwrap(fixture.uninstaller.scanApplications().first { $0.bundleID == "com.example.RecentDoc" })
        let plan = fixture.uninstaller.makePlan(for: app)

        XCTAssertFalse(plan.trashItems.contains { $0.url?.path == sharedFileList.path })
        XCTAssertTrue(plan.reviewOnlyItems.contains { $0.url?.path == sharedFileList.path })
    }

    func testCodexGeminiOpenCodeCliRootsAreExcludedFromPlan() throws {
        let fixture = try makeFixture()
        let cases = [
            ("Codex", "com.openai.codex", "codex"),
            ("Gemini", "com.google.gemini", "gemini"),
            ("OpenCode", "ai.opencode.desktop", "opencode")
        ]
        for (displayName, bundleID, cliName) in cases {
            let appURL = fixture.applications.appendingPathComponent("\(displayName).app")
            try makeApp(at: appURL, bundleID: bundleID, displayName: displayName)
            let cliRoots = [
                fixture.home.appendingPathComponent(".\(cliName)"),
                fixture.home.appendingPathComponent(".config/\(cliName)"),
                fixture.home.appendingPathComponent(".cache/\(cliName)"),
                fixture.home.appendingPathComponent(".local/share/\(cliName)"),
                fixture.home.appendingPathComponent("Library/Application Support/\(cliName)")
            ]
            for path in cliRoots {
                try createFileOrDirectory(path)
            }
        }

        let apps = fixture.uninstaller.scanApplications()
        for (displayName, bundleID, cliName) in cases {
            let app = try XCTUnwrap(apps.first { $0.bundleID == bundleID }, displayName)
            let plan = fixture.uninstaller.makePlan(for: app)
            let planned = Set((plan.trashItems + plan.reviewOnlyItems).compactMap { $0.url?.path })
            for path in [
                fixture.home.appendingPathComponent(".\(cliName)"),
                fixture.home.appendingPathComponent(".config/\(cliName)"),
                fixture.home.appendingPathComponent(".cache/\(cliName)"),
                fixture.home.appendingPathComponent(".local/share/\(cliName)"),
                fixture.home.appendingPathComponent("Library/Application Support/\(cliName)")
            ] {
                XCTAssertFalse(planned.contains(path.path), "\(displayName) should not plan CLI root \(path.path)")
            }
        }
    }

    func testReceiptPayloadSanitizesTraversalAndCollapsedRoots() throws {
        let fixture = try makeFixture()
        let invalid = [
            "../Library/LaunchDaemons/com.example.App.plist",
            "./../../Library/LaunchDaemons/com.example.App.plist",
            "/Library",
            "/private/var/db/receipts",
            "/Library/LaunchDaemons/bad\u{0000}.plist"
        ]
        for raw in invalid {
            XCTAssertNil(fixture.uninstaller.sanitizeReceiptPayloadPath(raw), raw)
        }
        XCTAssertEqual(
            fixture.uninstaller.sanitizeReceiptPayloadPath("./Library/LaunchDaemons/com.example.App.helper.plist")?.path,
            "/Library/LaunchDaemons/com.example.App.helper.plist"
        )
        XCTAssertEqual(
            fixture.uninstaller.sanitizeReceiptPayloadPath("/Library//Receipts///com.example.App.bom")?.path,
            "/Library/Receipts/com.example.App.bom"
        )
    }

    func testPkgReceiptUsesFreshCacheWithoutCallingPkgutil() throws {
        var pkgutilCalls = 0
        let runner = StubCommandRunner { executable, _, _, _ in
            if executable.lastPathComponent == "pkgutil" {
                pkgutilCalls += 1
            }
            return CommandOutput(exitCode: 0, stdout: "", stderr: "")
        }
        let fixture = try makeFixture(runExternalCommands: true, runner: runner)
        let cachedApp = fixture.opt.appendingPathComponent("Vendor/Cached.app")
        let badApp = fixture.root.appendingPathComponent("Untrusted/Bad.app")
        try makeApp(at: cachedApp, bundleID: "com.example.Cached", displayName: "Cached")
        try makeApp(at: badApp, bundleID: "com.example.Bad", displayName: "Bad")
        try writePackageReceiptCache(
            paths: [
                cachedApp.path,
                badApp.path,
                fixture.opt.appendingPathComponent("Vendor/NotApp").path
            ],
            to: fixture.root.appendingPathComponent("Caches/pkg-receipt-apps.json")
        )

        let apps = fixture.uninstaller.scanApplications()

        XCTAssertTrue(apps.contains { $0.bundleID == "com.example.Cached" })
        XCTAssertFalse(apps.contains { $0.bundleID == "com.example.Bad" })
        XCTAssertEqual(pkgutilCalls, 0)
    }

    func testApplicationMetadataCacheOnlyReusesLowRiskFields() throws {
        let fixture = try makeFixture()
        let appURL = fixture.applications.appendingPathComponent("Metadata.app")
        try makeApp(at: appURL, bundleID: "com.example.LiveMetadata", displayName: "LiveMetadata")
        try writeApplicationMetadataCache(
            path: appURL,
            displayName: "CachedMetadata",
            bundleID: "com.example.CachedMetadata",
            to: fixture.root.appendingPathComponent("Caches/application-metadata-cache.json")
        )

        let apps = fixture.uninstaller.scanApplications()

        let app = try XCTUnwrap(apps.first { $0.path.standardizedFileURL.path == appURL.standardizedFileURL.path })
        XCTAssertEqual(app.displayName, "LiveMetadata")
        XCTAssertEqual(app.bundleID, "com.example.LiveMetadata")
        XCTAssertEqual(app.sizeBytes, 123)
    }

    func testApplicationMetadataCacheDoesNotOverrideProtectionRules() throws {
        let fixture = try makeFixture()
        let appURL = fixture.applications.appendingPathComponent("Safari.app")
        try makeApp(at: appURL, bundleID: "com.apple.Safari", displayName: "Safari")
        try writeApplicationMetadataCache(
            path: appURL,
            displayName: "CachedSafeName",
            bundleID: "com.example.Safe",
            to: fixture.root.appendingPathComponent("Caches/application-metadata-cache.json")
        )

        let apps = fixture.uninstaller.scanApplications()

        let app = try XCTUnwrap(apps.first { $0.path.standardizedFileURL.path == appURL.standardizedFileURL.path })
        XCTAssertEqual(app.displayName, "Safari")
        XCTAssertEqual(app.bundleID, "com.apple.Safari")
        XCTAssertNotNil(app.protectedReason)
        XCTAssertFalse(app.canUninstall)
    }

    func testPlanExposesOnlyConservativeNonTrashSideEffectsAsCommandItems() throws {
        let fixture = try makeFixture()
        let appURL = fixture.applications.appendingPathComponent("SideEffects.app")
        try makeApp(at: appURL, bundleID: "com.example.SideEffects", displayName: "SideEffects")

        let app = try XCTUnwrap(fixture.uninstaller.scanApplications().first { $0.bundleID == "com.example.SideEffects" })
        let plan = fixture.uninstaller.makePlan(for: app)
        let commandCategories = Set(plan.commandItems.map(\.category))

        XCTAssertTrue(commandCategories.contains(.launchServices))
        XCTAssertTrue(commandCategories.contains(.dockEntry))
        XCTAssertFalse(commandCategories.contains(.defaultsDomain))
        XCTAssertFalse(plan.commandItems.contains { $0.id.hasPrefix("loginitem-") })
        XCTAssertFalse(plan.commandItems.contains { $0.id.hasPrefix("byhost-") })
    }

    func testTrashPreflightPreventsExternalCommandsWhenTrashIsUnsafe() throws {
        var externalCalls: [[String]] = []
        let runner = StubCommandRunner { _, arguments, _, _ in
            externalCalls.append(arguments)
            return CommandOutput(exitCode: 0, stdout: "", stderr: "")
        }
        let fixture = try makeFixture(runExternalCommands: true, runner: runner)
        try FileManager.default.removeItem(at: fixture.trash)
        let redirectedTrash = fixture.root.appendingPathComponent("RedirectedTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: redirectedTrash, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.trash, withDestinationURL: redirectedTrash)
        let appURL = fixture.applications.appendingPathComponent("UnsafeTrash.app")
        try makeApp(at: appURL, bundleID: "com.example.UnsafeTrash", displayName: "UnsafeTrash")

        let app = try XCTUnwrap(fixture.uninstaller.scanApplications().first { $0.bundleID == "com.example.UnsafeTrash" })
        let plan = fixture.uninstaller.makePlan(for: app)
        externalCalls.removeAll()
        let result = try fixture.uninstaller.execute(plan: plan)

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: appURL.path))
        XCTAssertTrue(externalCalls.isEmpty)
    }

    func testAdminMoveWithSystemTrashPreflightsConfiguredTrashBeforeCommands() throws {
        var externalCalls: [[String]] = []
        let runner = StubCommandRunner { _, arguments, _, _ in
            externalCalls.append(arguments)
            return CommandOutput(exitCode: 0, stdout: "", stderr: "")
        }
        let fixture = try makeFixture(runExternalCommands: true, runner: runner, useSystemTrash: true)
        try FileManager.default.removeItem(at: fixture.trash)
        let redirectedTrash = fixture.root.appendingPathComponent("RedirectedTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: redirectedTrash, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.trash, withDestinationURL: redirectedTrash)
        let appURL = fixture.applications.appendingPathComponent("AdminUnsafeTrash.app")
        try makeApp(at: appURL, bundleID: "com.example.AdminUnsafeTrash", displayName: "AdminUnsafeTrash")
        let app = InstalledApplication(
            id: appURL.path,
            displayName: "AdminUnsafeTrash",
            bundleID: "com.example.AdminUnsafeTrash",
            version: "1.0",
            path: appURL,
            source: .homebrewCask,
            homebrewCask: "admin-unsafe-trash",
            sizeBytes: 0,
            lastUsedDate: nil,
            requiresAdmin: true,
            protectedReason: nil,
            officialUninstallerVendor: nil,
            isRunning: false
        )

        let result = try fixture.uninstaller.execute(plan: fixture.uninstaller.makePlan(for: app))

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: appURL.path))
        XCTAssertTrue(externalCalls.isEmpty)
    }

    func testHomebrewSuccessDoesNotRunAutoremove() throws {
        var appURL: URL?
        var brewArguments: [[String]] = []
        let runner = StubCommandRunner { executable, arguments, _, _ in
            guard executable.lastPathComponent == "brew" else {
                return CommandOutput(exitCode: 0, stdout: "", stderr: "")
            }
            brewArguments.append(arguments)
            if arguments == ["uninstall", "--cask", "--zap", "cool-app"] {
                if let appURL {
                    try? FileManager.default.removeItem(at: appURL)
                }
                return CommandOutput(exitCode: 0, stdout: "", stderr: "")
            }
            if arguments == ["list", "--cask"] {
                return CommandOutput(exitCode: 0, stdout: "", stderr: "")
            }
            return CommandOutput(exitCode: 0, stdout: "", stderr: "")
        }
        let fixture = try makeFixture(runExternalCommands: true, runner: runner)
        let brew = fixture.brewBin.appendingPathComponent("brew")
        try "#!/bin/sh\n".write(to: brew, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path)
        let createdAppURL = fixture.applications.appendingPathComponent("Cool App.app")
        appURL = createdAppURL
        try makeApp(at: createdAppURL, bundleID: "com.example.CoolApp", displayName: "Cool App")
        let app = InstalledApplication(
            id: createdAppURL.path,
            displayName: "Cool App",
            bundleID: "com.example.CoolApp",
            version: "1.0",
            path: createdAppURL,
            source: .homebrewCask,
            homebrewCask: "cool-app",
            sizeBytes: 0,
            lastUsedDate: nil,
            requiresAdmin: false,
            protectedReason: nil,
            officialUninstallerVendor: nil,
            isRunning: false
        )

        let result = try fixture.uninstaller.execute(plan: fixture.uninstaller.makePlan(for: app))

        XCTAssertTrue(result.itemResults.contains { $0.item.category == .homebrew && $0.success })
        XCTAssertFalse(brewArguments.contains(["autoremove"]))
    }

    func testLoginItemDeletionCommandIsNotGenerated() throws {
        var commandBodies: [String] = []
        let runner = StubCommandRunner { executable, arguments, _, _ in
            commandBodies.append(([executable.lastPathComponent] + arguments).joined(separator: "\n"))
            return CommandOutput(exitCode: 0, stdout: "", stderr: "")
        }
        let fixture = try makeFixture(runExternalCommands: true, runner: runner)
        let appURL = fixture.applications.appendingPathComponent("LoginSafe.app")
        try makeApp(at: appURL, bundleID: "com.example.LoginSafe", displayName: "LoginSafe")
        let app = InstalledApplication(
            id: appURL.path,
            displayName: "LoginSafe",
            bundleID: "com.example.LoginSafe",
            version: "1.0",
            path: appURL,
            source: .applicationBundle,
            homebrewCask: nil,
            sizeBytes: 0,
            lastUsedDate: nil,
            requiresAdmin: false,
            protectedReason: nil,
            officialUninstallerVendor: nil,
            isRunning: false
        )

        let plan = fixture.uninstaller.makePlan(for: app)
        XCTAssertFalse(plan.commandItems.contains { $0.id.hasPrefix("loginitem-") })
        _ = try fixture.uninstaller.execute(plan: plan)

        XCTAssertFalse(commandBodies.contains { $0.contains("login items") })
    }

    func testMultipleExecutionsShareProvidedBatchIDWithDistinctRunIDs() throws {
        let fixture = try makeFixture()
        let firstURL = fixture.applications.appendingPathComponent("First.app")
        let secondURL = fixture.applications.appendingPathComponent("Second.app")
        try makeApp(at: firstURL, bundleID: "com.example.First", displayName: "First")
        try makeApp(at: secondURL, bundleID: "com.example.Second", displayName: "Second")
        let apps = fixture.uninstaller.scanApplications()
        let plans = try ["com.example.First", "com.example.Second"].map { bundleID in
            fixture.uninstaller.makePlan(for: try XCTUnwrap(apps.first { $0.bundleID == bundleID }))
        }
        let batchID = UUID()

        for plan in plans {
            _ = try fixture.uninstaller.execute(plan: plan, options: .dryRun(batchID: batchID))
        }

        let records = try auditRecords(at: fixture.root.appendingPathComponent("Logs/uninstall-audit.log"))
        let batchIDs = Set(records.compactMap { $0["batchID"] as? String })
        let startedRunIDs = Set(records.compactMap { record -> String? in
            (record["status"] as? String) == "started" ? record["runID"] as? String : nil
        })
        XCTAssertEqual(batchIDs, [batchID.uuidString])
        XCTAssertEqual(startedRunIDs.count, 2)
        XCTAssertEqual(records.filter { ($0["status"] as? String) == "dry-run" }.count, plans.flatMap(\.items).count)
    }

    func testDockCleanupOnlyRemovesExactTargetEntry() throws {
        let fixture = try makeFixture()
        let appURL = fixture.applications.appendingPathComponent("Foo.app")
        try makeApp(at: appURL, bundleID: "com.example.Foo", displayName: "Foo")
        let siblingPath = "/Applications/My Foo.app Backup.app"
        let dockPlist = fixture.home.appendingPathComponent("Library/Preferences/com.apple.dock.plist")
        try writeDockPlist(
            [
                makeDockEntry(bundleID: "com.example.Foo", fileURL: appURL.path),
                makeDockEntry(bundleID: "com.example.Other", fileURL: siblingPath)
            ],
            to: dockPlist
        )

        let app = try XCTUnwrap(fixture.uninstaller.scanApplications().first { $0.bundleID == "com.example.Foo" })
        let plan = fixture.uninstaller.makePlan(for: app)
        let result = try fixture.uninstaller.execute(plan: plan)

        XCTAssertTrue(result.succeeded)
        let remaining = try dockEntries(at: dockPlist)
        XCTAssertEqual(remaining.count, 1)
        let fileData = try XCTUnwrap((remaining[0]["tile-data"] as? [String: Any])?["file-data"] as? [String: Any])
        XCTAssertEqual(fileData["_CFURLString"] as? String, siblingPath)
    }

    func testProcessCommandRunnerTimesOutWithoutHangingOnWaitUntilExit() throws {
        let runner = ProcessCommandRunner()
        let start = Date()

        XCTAssertThrowsError(
            try runner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM INT; while :; do :; done"],
                timeout: 0.2
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("超时"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testProcessCommandRunnerFailsWhenChildKeepsOutputPipeOpen() throws {
        let runner = ProcessCommandRunner()
        let start = Date()

        XCTAssertThrowsError(
            try runner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 3 & exit 0"],
                timeout: 1
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("管道") || error.localizedDescription.contains("超时"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }

    private struct Fixture {
        let root: URL
        let home: URL
        let applications: URL
        let homeApplications: URL
        let systemLibrary: URL
        let systemInputMethods: URL
        let userInputMethods: URL
        let volumes: URL
        let volumeApplications: URL
        let usrLocal: URL
        let opt: URL
        let brewBin: URL
        let caskroom: URL
        let trash: URL
        let uninstaller: ApplicationUninstaller
    }

    private var fixturePathMarker = "__FIXTURE_PATH__"

    private func makeFixture(
        runExternalCommands: Bool = false,
        runner: CommandRunning = StubCommandRunner(),
        useSystemTrash: Bool = false
    ) throws -> Fixture {
        let root = try makeTemporaryDirectory()
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        let homeApplications = home.appendingPathComponent("Applications", isDirectory: true)
        let systemLibrary = root.appendingPathComponent("Library", isDirectory: true)
        let systemInputMethods = systemLibrary.appendingPathComponent("Input Methods", isDirectory: true)
        let userInputMethods = home.appendingPathComponent("Library/Input Methods", isDirectory: true)
        let volumes = root.appendingPathComponent("Volumes", isDirectory: true)
        let volumeApplications = volumes.appendingPathComponent("Data/Applications", isDirectory: true)
        let usrLocal = root.appendingPathComponent("usr/local", isDirectory: true)
        let opt = root.appendingPathComponent("opt", isDirectory: true)
        let brewBin = root.appendingPathComponent("Homebrew/bin", isDirectory: true)
        let caskroom = root.appendingPathComponent("Homebrew/Caskroom", isDirectory: true)
        let trash = home.appendingPathComponent(".Trash", isDirectory: true)
        for directory in [home, applications, homeApplications, systemLibrary, systemInputMethods, userInputMethods, volumes, volumeApplications, usrLocal, opt, brewBin, caskroom, trash] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let environment = ApplicationUninstaller.Environment(
            homeDirectory: home,
            applicationDirectories: [applications, homeApplications, systemInputMethods, userInputMethods],
            volumesDirectory: volumes,
            systemLibraryDirectory: systemLibrary,
            systemApplicationsDirectory: root.appendingPathComponent("System/Applications", isDirectory: true),
            trashDirectory: trash,
            receiptApplicationDirectories: [usrLocal, opt],
            homebrewBinaryDirectories: [brewBin],
            homebrewCaskroomDirectories: [caskroom],
            uninstallAuditLogURL: root.appendingPathComponent("Logs/uninstall-audit.log"),
            pkgReceiptCacheURL: root.appendingPathComponent("Caches/pkg-receipt-apps.json"),
            appMetadataCacheURL: root.appendingPathComponent("Caches/application-metadata-cache.json"),
            pkgReceiptCacheTTL: 86_400,
            appMetadataCacheTTL: 3_600,
            scanTimeout: 8,
            runExternalCommands: runExternalCommands,
            useSystemTrash: useSystemTrash
        )
        return Fixture(
            root: root,
            home: home,
            applications: applications,
            homeApplications: homeApplications,
            systemLibrary: systemLibrary,
            systemInputMethods: systemInputMethods,
            userInputMethods: userInputMethods,
            volumes: volumes,
            volumeApplications: volumeApplications,
            usrLocal: usrLocal,
            opt: opt,
            brewBin: brewBin,
            caskroom: caskroom,
            trash: trash,
            uninstaller: ApplicationUninstaller(environment: environment, runner: runner)
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApplicationUninstallerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func makeApp(at url: URL, bundleID: String, displayName: String, extraPlist: [String: Any] = [:]) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": displayName,
            "CFBundleDisplayName": displayName,
            "CFBundleExecutable": displayName,
            "CFBundleShortVersionString": "1.0"
        ]
        for (key, value) in extraPlist {
            plist[key] = value
        }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    private func createFileOrDirectory(_ url: URL) throws {
        if url.pathExtension.isEmpty || url.lastPathComponent.contains(".savedState") || url.lastPathComponent == "TestApp" || url.lastPathComponent == "com.example.TestApp" {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "fixture".write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func pkgutilRunner(files: [String], installLocation: @escaping () -> String) -> StubCommandRunner {
        StubCommandRunner { executable, arguments, _, _ in
            guard executable.lastPathComponent == "pkgutil" else {
                return CommandOutput(exitCode: 0, stdout: "", stderr: "")
            }
            if arguments == ["--pkgs"] {
                return CommandOutput(exitCode: 0, stdout: "com.example.pkg\n", stderr: "")
            }
            if arguments == ["--pkg-info-plist", "com.example.pkg"] {
                let plist = try self.plistString(["install-location": installLocation()])
                return CommandOutput(exitCode: 0, stdout: plist, stderr: "")
            }
            if arguments == ["--files", "com.example.pkg"] {
                return CommandOutput(exitCode: 0, stdout: files.joined(separator: "\n"), stderr: "")
            }
            return CommandOutput(exitCode: 0, stdout: "", stderr: "")
        }
    }

    private func plistString(_ value: [String: String]) throws -> String {
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private struct TestPackageReceiptCache: Codable {
        let createdAt: Date
        let paths: [String]
    }

    private struct TestApplicationMetadataCache: Codable {
        let createdAt: Date
        let entries: [String: TestApplicationMetadataCacheEntry]
    }

    private struct TestApplicationMetadataCacheEntry: Codable {
        let path: String
        let identity: String
        let contentModificationDate: Date?
        let displayName: String
        let bundleID: String
        let version: String?
        let source: String
        let homebrewCask: String?
        let sizeBytes: Int64
        let lastUsedDate: Date?
        let requiresAdmin: Bool
        let protectedReason: String?
        let officialUninstallerVendor: String?
    }

    private func writePackageReceiptCache(paths: [String], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(TestPackageReceiptCache(createdAt: Date(), paths: paths))
        try data.write(to: url)
    }

    private func writeApplicationMetadataCache(path: URL, displayName: String, bundleID: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let values = try path.resourceValues(forKeys: [.fileResourceIdentifierKey, .contentModificationDateKey])
        let identity = try XCTUnwrap(values.fileResourceIdentifier)
        let standardizedPath = path.standardizedFileURL.path
        let entry = TestApplicationMetadataCacheEntry(
            path: standardizedPath,
            identity: "inode:\(identity)",
            contentModificationDate: values.contentModificationDate,
            displayName: displayName,
            bundleID: bundleID,
            version: "9.9",
            source: InstalledApplication.Source.applicationBundle.rawValue,
            homebrewCask: nil,
            sizeBytes: 123,
            lastUsedDate: nil,
            requiresAdmin: false,
            protectedReason: nil,
            officialUninstallerVendor: nil
        )
        let cache = TestApplicationMetadataCache(createdAt: Date(), entries: [standardizedPath: entry])
        let data = try JSONEncoder().encode(cache)
        try data.write(to: url)
    }

    private func auditRecords(at url: URL) throws -> [[String: Any]] {
        let text = try String(contentsOf: url)
        return try text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                let data = Data(String(line).utf8)
                return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            }
    }

    private func makeDockEntry(bundleID: String, fileURL: String) -> [String: Any] {
        [
            "tile-data": [
                "bundle-identifier": bundleID,
                "file-data": [
                    "_CFURLString": fileURL
                ]
            ]
        ]
    }

    private func writeDockPlist(_ entries: [[String: Any]], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plist: [String: Any] = ["persistent-apps": entries]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url)
    }

    private func dockEntries(at url: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: url)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
        return try XCTUnwrap(plist["persistent-apps"] as? [[String: Any]])
    }
}

private struct StubCommandRunner: CommandRunning {
    var handler: (URL, [String], TimeInterval, [String: String]) throws -> CommandOutput = { _, _, _, _ in
        CommandOutput(exitCode: 0, stdout: "", stderr: "")
    }

    func run(executable: URL, arguments: [String], timeout: TimeInterval, environment: [String: String]) throws -> CommandOutput {
        try handler(executable, arguments, timeout, environment)
    }
}
