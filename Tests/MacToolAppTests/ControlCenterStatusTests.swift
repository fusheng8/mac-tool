import XCTest
import MacToolCore
@testable import MacToolApp

final class ControlCenterStatusTests: XCTestCase {
    func testHealthySnapshotHasNoIssues() {
        let snapshot = ControlCenterStatusSnapshot.make(input: healthyInput())

        XCTAssertEqual(snapshot.level, .normal)
        XCTAssertEqual(snapshot.headline, "所有核心服务均正常")
        XCTAssertTrue(snapshot.issues.isEmpty)
        XCTAssertEqual(snapshot.services.map(\.id), ["clipboard", "finder", "display", "archive"])
    }

    func testFinderAuthorizationCreatesPreferencesIssue() throws {
        var input = healthyInput()
        input.finderExtensionEnabled = false

        let snapshot = ControlCenterStatusSnapshot.make(input: input)
        let issue = try XCTUnwrap(snapshot.issues.first)

        XCTAssertEqual(snapshot.level, .attention)
        XCTAssertEqual(issue.id, "finder-extension")
        XCTAssertEqual(issue.route, .preferences)
    }

    func testDisplayRecoveryHasPriorityOverWarnings() throws {
        var input = healthyInput()
        input.clipboardPaused = true
        input.pendingDisplayRecoveryCount = 2

        let snapshot = ControlCenterStatusSnapshot.make(input: input)

        XCTAssertEqual(snapshot.level, .critical)
        XCTAssertEqual(snapshot.issues.count, 2)
        XCTAssertEqual(snapshot.issues.first(where: { $0.id == "display-recovery" })?.level, .critical)
    }

    func testPrivacyExclusionsAreVisibleWithoutCreatingAnIssue() throws {
        var input = healthyInput()
        input.clipboardPrivacyExclusionsActive = true

        let snapshot = ControlCenterStatusSnapshot.make(input: input)
        let clipboard = try XCTUnwrap(snapshot.services.first(where: { $0.id == "clipboard" }))

        XCTAssertEqual(clipboard.detail, "正在记录 · 隐私排除生效")
        XCTAssertFalse(snapshot.issues.contains(where: { $0.id == "clipboard" }))
    }

    private func healthyInput() -> ControlCenterStatusInput {
        ControlCenterStatusInput(
            clipboardEnabled: true,
            clipboardPaused: false,
            clipboardPrivacyExclusionsActive: false,
            finderFeatureEnabled: true,
            finderExtensionEnabled: true,
            connectedDisplayCount: 2,
            pendingDisplayRecoveryCount: 0,
            archiveFormatCount: 10
        )
    }
}

final class ControlCenterConfigurationMigrationTests: XCTestCase {
    func testV2ConfigurationNormalizesToV3() throws {
        let legacy = AppConfig(
            schemaVersion: 2,
            profiles: [],
            clipboard: .defaultValue,
            archive: .defaultValue,
            contextMenu: .defaultValue
        )

        let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(legacy))
        let migrated = decoded.normalized()

        XCTAssertEqual(decoded.schemaVersion, 2)
        XCTAssertEqual(migrated.schemaVersion, 3)
        XCTAssertEqual(migrated.contextMenu.items.map(\.id), ContextMenuConfig.defaultValue.items.map(\.id))
    }

    func testFinderCustomizationKeepsOrderAndValidTarget() throws {
        let target = FinderTargetApplication(
            bundleIdentifier: "com.example.Editor",
            displayName: " Example Editor ",
            lastKnownPath: "/Applications/Example Editor.app"
        )
        let config = ContextMenuConfig(
            enabled: true,
            items: [
                ContextMenuItemConfig(id: .copyPath, customTitle: " 复制完整路径 ", targetApplication: target),
                ContextMenuItemConfig(
                    id: .open,
                    children: [
                        ContextMenuItemConfig(id: .openWithVSCode, customTitle: " 用编辑器打开 ", targetApplication: target)
                    ]
                )
            ]
        ).normalized()

        XCTAssertEqual(config.items.first?.id, .copyPath)
        XCTAssertEqual(config.item(for: .copyPath)?.displayTitle, "复制完整路径")
        XCTAssertNil(config.item(for: .copyPath)?.targetApplication)
        XCTAssertEqual(config.item(for: .openWithVSCode)?.displayTitle, "用编辑器打开")
        XCTAssertEqual(config.item(for: .openWithVSCode)?.targetApplication?.bundleIdentifier, "com.example.Editor")
    }

    func testLegacyFinderItemDecodesWithoutNewFields() throws {
        let data = Data(#"{"id":"copyPath","enabled":true,"children":[]}"#.utf8)
        let item = try JSONDecoder().decode(ContextMenuItemConfig.self, from: data)

        XCTAssertEqual(item.displayTitle, "拷贝路径")
        XCTAssertNil(item.customTitle)
        XCTAssertNil(item.targetApplication)
    }
}

final class ArchivePresetTests: XCTestCase {
    func testUniversalZipPresetMapsToSafeDefaults() throws {
        let options = try XCTUnwrap(
            ArchivePreset.preset(.universalZip).compressionOptions(archiveName: "资料", wrapInFolder: true)
        )
        XCTAssertEqual(options.format, .zip)
        XCTAssertEqual(options.compressionLevel, 6)
        XCTAssertTrue(options.stripMacMetadata)
        XCTAssertTrue(options.wrapInFolder)
        XCTAssertNil(options.password)
    }

    func testSourcePresetMapsToTarGzip() throws {
        let options = try XCTUnwrap(
            ArchivePreset.preset(.sourcePackage).compressionOptions(archiveName: "source", wrapInFolder: false)
        )
        XCTAssertEqual(options.format, .tarGzip)
        XCTAssertEqual(options.compressionLevel, 6)
        XCTAssertTrue(options.stripMacMetadata)
    }

    func testInteractivePresetsDoNotInventCompressionOptions() {
        XCTAssertNil(ArchivePreset.preset(.encryptedArchive).compressionOptions(archiveName: "secure", wrapInFolder: false))
        XCTAssertNil(ArchivePreset.preset(.custom).compressionOptions(archiveName: "custom", wrapInFolder: false))
    }
}

final class PortProcessGroupingTests: XCTestCase {
    func testGroupsMultiplePortsByPIDAndEscalatesScope() throws {
        let usages = [
            makeUsage(port: 3000, protocolName: "TCP", endpoint: "127.0.0.1:3000", pid: 42),
            makeUsage(port: 3001, protocolName: "UDP", endpoint: "*:3001", pid: 42),
            makeUsage(port: 8080, protocolName: "TCP", endpoint: "127.0.0.1:8080", pid: 77)
        ]

        let groups = PortProcessGroup.grouped(usages)
        let first = try XCTUnwrap(groups.first(where: { $0.pid == 42 }))

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(first.ports, [3000, 3001])
        XCTAssertEqual(first.protocols, ["TCP", "UDP"])
        XCTAssertEqual(first.addressScope, .network)
    }

    func testGroupSearchMatchesHiddenDetails() throws {
        let group = try XCTUnwrap(PortProcessGroup.grouped([
            makeUsage(port: 8443, protocolName: "TCP", endpoint: "0.0.0.0:8443", pid: 99)
        ]).first)

        XCTAssertTrue(group.matches("8443"))
        XCTAssertTrue(group.matches("example-server"))
        XCTAssertTrue(group.matches("/usr/local/bin/example"))
        XCTAssertFalse(group.matches("not-present"))
    }

    private func makeUsage(
        port: Int,
        protocolName: String,
        endpoint: String,
        pid: Int32
    ) -> PortUsage {
        PortUsage(
            port: port,
            protocolName: protocolName,
            endpoint: endpoint,
            pid: pid,
            command: "example-server",
            user: "tester",
            executablePath: "/usr/local/bin/example",
            bundlePath: nil,
            processIdentity: nil
        )
    }
}
