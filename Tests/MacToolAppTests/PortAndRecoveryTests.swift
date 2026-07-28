import CoreGraphics
import Foundation
import XCTest
@testable import MacToolApp

final class PortCommandRunnerTests: XCTestCase {
    func testDrainsLargeStdoutAndStderrWithoutDeadlock() throws {
        let result = try PortCommandRunner().run(
            executableURL: URL(fileURLWithPath: "/usr/bin/awk"),
            arguments: ["BEGIN { for (i = 0; i < 20000; i++) { print \"stdout-\" i; print \"stderr-\" i > \"/dev/stderr\" } }"],
            timeout: 10,
            outputLimit: 2 * 1_024 * 1_024
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertGreaterThan(result.stdout.count, 64 * 1_024)
        XCTAssertGreaterThan(result.stderr.count, 64 * 1_024)
    }

    func testTimeoutTerminatesChildPromptly() {
        let started = Date()
        XCTAssertThrowsError(try PortCommandRunner().run(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["5"],
            timeout: 0.1,
            outputLimit: 1_024
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("超时"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testOutputLimitFailsInsteadOfGrowingWithoutBound() {
        XCTAssertThrowsError(try PortCommandRunner().run(
            executableURL: URL(fileURLWithPath: "/usr/bin/awk"),
            arguments: ["BEGIN { for (i = 0; i < 10000; i++) print \"entry-\" i }"],
            timeout: 10,
            outputLimit: 1_024
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("安全限制"))
        }
    }

    func testChildKeepingPipeOpenFailsWithoutHanging() {
        let started = Date()
        XCTAssertThrowsError(try PortCommandRunner().run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 5 &"],
            timeout: 10,
            outputLimit: 1_024
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("输出管道"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }
}

final class DisplayMatchingTests: XCTestCase {
    func testActiveRuntimeAliasIsMergedIntoUniquePhysicalDisplay() {
        let physical = display(id: 2, edid: "EDID-A", name: "Studio", serial: "0", active: false)
        let alias = display(id: 33, edid: "", name: "外接显示器", serial: "0", active: true)

        let reconciled = DisplayDetector.reconciledDisplays(
            online: [physical],
            active: [alias]
        )

        XCTAssertEqual(reconciled.count, 1)
        XCTAssertEqual(reconciled[0].runtimeDisplayID, physical.runtimeDisplayID)
        XCTAssertTrue(reconciled[0].isActive)
        XCTAssertEqual(reconciled[0].edidUUID, physical.edidUUID)
    }

    func testActiveRuntimeAliasIsNotMergedWhenHardwareIdentityIsAmbiguous() {
        let first = display(id: 2, edid: "EDID-A", name: "Studio A", serial: "0", active: false)
        let second = display(id: 3, edid: "EDID-B", name: "Studio B", serial: "0", active: false)
        let alias = display(id: 33, edid: "", name: "外接显示器", serial: "0", active: true)

        let reconciled = DisplayDetector.reconciledDisplays(
            online: [first, second],
            active: [alias]
        )

        XCTAssertEqual(reconciled.count, 3)
        XCTAssertFalse(reconciled[0].isActive)
        XCTAssertFalse(reconciled[1].isActive)
    }

    func testSafetyReconciliationDropsOrphanActiveAliasAfterPhysicalDisplayRemoval() {
        let builtIn = display(id: 1, edid: "BUILT-IN", name: "内置显示屏", serial: "1", active: false)
        var removedExternalAlias = display(
            id: 49,
            edid: "",
            name: "外接显示器",
            serial: "0",
            active: true
        )
        removedExternalAlias.vendorId = "0xabcd"
        removedExternalAlias.modelId = "0xef01"

        let reconciled = DisplayDetector.reconciledDisplays(
            online: [builtIn],
            active: [removedExternalAlias],
            includeUnmatchedActiveAliases: false
        )

        XCTAssertEqual(reconciled.count, 1)
        XCTAssertEqual(reconciled[0].runtimeDisplayID, builtIn.runtimeDisplayID)
        XCTAssertFalse(reconciled[0].isActive)
    }

    func testStrictModeDoesNotFallBackToNameAfterEDIDMismatch() {
        let detector = DisplayDetector()
        let candidate = display(id: 1, edid: "EDID-B", name: "Same Model", serial: "200")
        let profile = profile(mode: .strict, edid: "EDID-A", name: "Same Model", serial: "100")

        XCTAssertFalse(detector.matchScore(display: candidate, profile: profile).matches)
        XCTAssertFalse(candidate.hasSameStableIdentity(as: display(id: 2, edid: "EDID-A", name: "Same Model", serial: "100")))
    }

    func testWeightedModeUsesThresholdAndIgnoresPlaceholderSerial() {
        let detector = DisplayDetector()
        let candidate = display(id: 1, edid: "", name: "Studio", serial: "123")
        let matching = profile(mode: .weighted, edid: "different", name: "Studio", serial: "123")
        XCTAssertTrue(detector.matchScore(display: candidate, profile: matching).matches)

        let placeholder = display(id: 2, edid: "", name: "Studio", serial: "0")
        let placeholderProfile = profile(mode: .weighted, edid: "", name: "Studio", serial: "0")
        XCTAssertEqual(detector.matchScore(display: placeholder, profile: placeholderProfile).score, 20)
        XCTAssertFalse(detector.matchScore(display: placeholder, profile: placeholderProfile).matches)
    }

    func testAmbiguousHighestScoreReturnsNoDisplay() {
        let displays = [
            display(id: 1, edid: "A", name: "Studio", serial: "123"),
            display(id: 2, edid: "B", name: "Studio", serial: "123")
        ]
        let detector = DisplayDetector(displayProvider: { displays })
        let ambiguous = profile(mode: .weighted, edid: "", name: "Studio", serial: "123")
        XCTAssertNil(detector.findDisplay(for: ambiguous))
    }

    private func display(
        id: UInt32,
        edid: String,
        name: String,
        serial: String,
        active: Bool = true
    ) -> DisplaySnapshot {
        DisplaySnapshot(
            runtimeDisplayID: id,
            displayName: name,
            edidUUID: edid,
            vendorId: "0x1234",
            modelId: "0x5678",
            serialNumber: serial,
            manufacturer: "Test",
            alphanumericSerial: "",
            isBuiltIn: false,
            isActive: active,
            ioLocation: ""
        )
    }

    private func profile(mode: MatchMode, edid: String, name: String, serial: String) -> DisplayProfile {
        DisplayProfile(
            id: "profile",
            enabled: true,
            name: name,
            matchMode: mode,
            match: DisplayMatchRule(
                displayName: name,
                edidUUID: edid,
                vendorId: "0x1234",
                modelId: "0x5678",
                serialNumber: serial,
                manufacturer: "Test",
                alphanumericSerial: "",
                matchThreshold: 80
            ),
            colorLock: .p3Default,
            disconnect: .defaultValue,
            automationEnabled: false
        )
    }
}

final class DisplayDisconnectSafetyTests: XCTestCase {
    func testReconnectTreatsAnAlreadyActiveLiveDisplayAsSuccess() throws {
        let staleBuiltIn = display(id: 1, name: "内置显示屏", builtIn: true, active: false)
        var liveBuiltIn = staleBuiltIn
        liveBuiltIn.runtimeDisplayID = 9
        liveBuiltIn.isActive = true
        let detector = DisplayDetector(displayProvider: { [liveBuiltIn] })
        let backend = RecordingDisplayBackend()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(
            configURL: root.appendingPathComponent("config.json"),
            stateURL: root.appendingPathComponent("state.json"),
            finderSyncConfigURL: nil
        )
        try store.rememberAppDisconnectedDisplay(staleBuiltIn.runtimeDisplayID)
        let controller = SoftDisconnectController(detector: detector, backend: backend, store: store)

        try controller.reconnect(
            profile: profile(for: staleBuiltIn),
            fallbackDisplay: staleBuiltIn
        )

        XCTAssertTrue(backend.mutations.isEmpty)
        XCTAssertTrue(store.state.appDisconnectedDisplayIDs.isEmpty)
    }

    func testManualDisplayRecoveryDoesNotRequireAutomationConsent() {
        XCTAssertTrue(DisplayBackgroundWorkPolicy.shouldMonitor(
            displayAutomationAllowed: false,
            hasDesiredClose: true,
            hasPendingReconnect: false,
            hasAppDisconnectedDisplays: true
        ))
        XCTAssertFalse(DisplayBackgroundWorkPolicy.shouldApplyAutomation(
            displayAutomationAllowed: false,
            hasDesiredClose: true,
            hasPendingReconnect: false
        ))
        XCTAssertFalse(DisplayBackgroundWorkPolicy.shouldMonitor(
            displayAutomationAllowed: false,
            hasDesiredClose: true,
            hasPendingReconnect: false,
            hasAppDisconnectedDisplays: false
        ))
    }

    func testTopologyChangesAreNotSuppressedByRecentAppMutation() {
        XCTAssertTrue(DisplayReconfigurationPolicy.shouldHandle(
            flags: [.removeFlag],
            shouldSuppressRecentMutation: true
        ))
        XCTAssertTrue(DisplayReconfigurationPolicy.shouldHandle(
            flags: [.addFlag],
            shouldSuppressRecentMutation: true
        ))
        XCTAssertFalse(DisplayReconfigurationPolicy.shouldHandle(
            flags: [.disabledFlag],
            shouldSuppressRecentMutation: true
        ))
        XCTAssertTrue(DisplayReconfigurationPolicy.requiresSettledSafetyCheck(flags: [.removeFlag]))
        XCTAssertFalse(DisplayReconfigurationPolicy.requiresSettledSafetyCheck(flags: [.addFlag]))
    }

    func testManualBuiltInCloseUsesCurrentActiveDisplaysInsteadOfOtherDesiredProfiles() throws {
        let builtIn = display(id: 1, name: "内置显示屏", builtIn: true)
        let external = display(id: 3, name: "外接显示器", builtIn: false)
        let detector = DisplayDetector(displayProvider: { [builtIn, external] })
        let controller = SoftDisconnectController(detector: detector, backend: AvailableDisplayBackend())
        let builtInProfile = profile(for: builtIn)
        let externalProfile = profile(for: external)

        let selected = try controller.validateCanDisconnect(
            profile: builtInProfile,
            allProfiles: [builtInProfile, externalProfile]
        )

        XCTAssertEqual(selected.runtimeDisplayID, builtIn.runtimeDisplayID)
    }

    func testManualCloseStillRejectsTheLastActiveDisplay() {
        let builtIn = display(id: 1, name: "内置显示屏", builtIn: true)
        let detector = DisplayDetector(displayProvider: { [builtIn] })
        let controller = SoftDisconnectController(detector: detector, backend: AvailableDisplayBackend())
        let builtInProfile = profile(for: builtIn)

        XCTAssertThrowsError(try controller.validateCanDisconnect(
            profile: builtInProfile,
            allProfiles: [builtInProfile]
        )) { error in
            guard case SoftDisconnectError.notEnoughActiveDisplays = error else {
                return XCTFail("Expected notEnoughActiveDisplays, got \(error)")
            }
        }
    }

    func testSafetyGuardDoesNotReopenClosedBuiltInDisplayWhileExternalDisplayIsActive() throws {
        let builtIn = display(id: 1, name: "内置显示屏", builtIn: true, active: false)
        let external = display(id: 3, name: "外接显示器", builtIn: false)
        let detector = DisplayDetector(displayProvider: { [builtIn, external] })
        let backend = RecordingDisplayBackend()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(
            configURL: root.appendingPathComponent("config.json"),
            stateURL: root.appendingPathComponent("state.json"),
            finderSyncConfigURL: nil
        )
        store.profiles = [profile(for: builtIn), profile(for: external)]
        let controller = SoftDisconnectController(detector: detector, backend: backend)

        controller.enforceDisplaySafety(store: store, reason: "test")

        XCTAssertTrue(backend.mutations.isEmpty)
    }

    func testSafetyGuardReopensBuiltInDisplayAfterExternalDisplayIsRemoved() throws {
        let builtIn = display(id: 1, name: "内置显示屏", builtIn: true, active: false)
        let detector = DisplayDetector(displayProvider: { [builtIn] })
        let backend = RecordingDisplayBackend()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(
            configURL: root.appendingPathComponent("config.json"),
            stateURL: root.appendingPathComponent("state.json"),
            finderSyncConfigURL: nil
        )
        store.profiles = [profile(for: builtIn)]
        try store.rememberAppDisconnectedDisplay(builtIn.runtimeDisplayID)
        let controller = SoftDisconnectController(detector: detector, backend: backend, store: store)

        controller.enforceDisplaySafety(store: store, reason: "external-removed")

        XCTAssertEqual(backend.mutations.count, 1)
        XCTAssertEqual(backend.mutations.first?.0, builtIn.runtimeDisplayID)
        XCTAssertEqual(backend.mutations.first?.1, true)
    }

    func testSafetyGuardDoesNotTrustRememberedActiveStateForOwnedDisplay() throws {
        let rememberedBuiltIn = display(id: 1, name: "内置显示屏", builtIn: true, active: true)
        let detector = DisplayDetector(
            displayProvider: { [] },
            safetyDisplayProvider: { [] }
        )
        let backend = RecordingDisplayBackend()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(
            configURL: root.appendingPathComponent("config.json"),
            stateURL: root.appendingPathComponent("state.json"),
            finderSyncConfigURL: nil
        )
        store.rememberDisplays([rememberedBuiltIn])
        try store.rememberAppDisconnectedDisplay(rememberedBuiltIn.runtimeDisplayID)
        let controller = SoftDisconnectController(detector: detector, backend: backend, store: store)

        controller.enforceDisplaySafety(store: store, reason: "external-removed")

        XCTAssertEqual(backend.mutations.count, 1)
        XCTAssertEqual(backend.mutations.first?.0, rememberedBuiltIn.runtimeDisplayID)
        XCTAssertEqual(backend.mutations.first?.1, true)
    }

    private func display(id: UInt32, name: String, builtIn: Bool, active: Bool = true) -> DisplaySnapshot {
        DisplaySnapshot(
            runtimeDisplayID: id,
            displayName: name,
            edidUUID: "EDID-\(id)",
            vendorId: "0x1234",
            modelId: "0x\(id)",
            serialNumber: "\(id)",
            manufacturer: "Test",
            alphanumericSerial: "SERIAL-\(id)",
            isBuiltIn: builtIn,
            isActive: active,
            ioLocation: "display-\(id)"
        )
    }

    private func profile(for display: DisplaySnapshot) -> DisplayProfile {
        DisplayProfile(
            id: "profile-\(display.runtimeDisplayID)",
            enabled: true,
            name: display.displayName,
            matchMode: .strict,
            match: DisplayMatchRule(
                displayName: display.displayName,
                edidUUID: display.edidUUID,
                vendorId: display.vendorId,
                modelId: display.modelId,
                serialNumber: display.serialNumber,
                manufacturer: display.manufacturer,
                alphanumericSerial: display.alphanumericSerial,
                ioLocation: display.ioLocation,
                matchThreshold: 80
            ),
            colorLock: .p3Default,
            disconnect: DisconnectConfig(
                enabled: true,
                allowSoftDisconnect: true,
                autoReconnect: false,
                autoReconnectDelaySeconds: 30,
                externalOnly: false,
                confirmBeforeDisconnect: false
            ),
            automationEnabled: false
        )
    }
}

private struct AvailableDisplayBackend: DisplayBackend {
    let isAvailable = true
    let unavailableReason: String? = nil

    func setDisplayEnabled(_ displayID: UInt32, enabled: Bool) throws {}
}

private final class RecordingDisplayBackend: DisplayBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedMutations: [(UInt32, Bool)] = []
    let isAvailable = true
    let unavailableReason: String? = nil

    var mutations: [(UInt32, Bool)] {
        lock.lock()
        defer { lock.unlock() }
        return recordedMutations
    }

    func setDisplayEnabled(_ displayID: UInt32, enabled: Bool) throws {
        lock.lock()
        recordedMutations.append((displayID, enabled))
        lock.unlock()
    }
}

final class PortSafetyTests: XCTestCase {
    func testConnectedUDPSocketIsNotReportedAsListening() throws {
        let identity = PortProcessIdentity(pid: 100, startTimeMicroseconds: 1, executablePath: "/tmp/test")
        let runner = StubPortCommandRunner(
            tcpOutput: "",
            udpOutput: "p100\nctest\nLuser\nPUDP\nn127.0.0.1:50000->1.1.1.1:443\nn*:5353\n"
        )
        let manager = PortManager(commandRunner: runner, processInspector: StubPortProcessInspector(identity: identity))

        let usages = try manager.listListeningPorts()
        XCTAssertEqual(usages.map(\.port), [5353])
        XCTAssertEqual(usages.first?.endpoint, "*:5353")
    }

    func testStopRejectsReusedPIDAndAllowsUnchangedIdentity() throws {
        let original = PortProcessIdentity(pid: 100, startTimeMicroseconds: 1, executablePath: "/tmp/test")
        let inspector = StubPortProcessInspector(identity: original)
        let output = "p100\nctest\nLuser\nPTCP\nn127.0.0.1:8080\n"
        let runner = StubPortCommandRunner(tcpOutput: output, udpOutput: "", validationOutput: output)
        let signals = StubPortSignalSender()
        let manager = PortManager(commandRunner: runner, processInspector: inspector, signalSender: signals)
        let usage = try XCTUnwrap(manager.listListeningPorts().first)

        inspector.currentIdentity = PortProcessIdentity(pid: 100, startTimeMicroseconds: 2, executablePath: "/tmp/other")
        XCTAssertThrowsError(try manager.stop(usage, method: .terminate))
        XCTAssertTrue(signals.sent.isEmpty)

        inspector.currentIdentity = original
        try manager.stop(usage, method: .terminate)
        XCTAssertEqual(signals.sent.count, 1)
        XCTAssertEqual(signals.sent.first?.pid, 100)
    }
}

private final class StubPortCommandRunner: PortCommandRunning {
    let tcpOutput: String
    let udpOutput: String
    let validationOutput: String

    init(tcpOutput: String, udpOutput: String, validationOutput: String? = nil) {
        self.tcpOutput = tcpOutput
        self.udpOutput = udpOutput
        self.validationOutput = validationOutput ?? tcpOutput
    }

    func run(executableURL: URL, arguments: [String], timeout: TimeInterval, outputLimit: Int) throws -> PortCommandOutput {
        let output: String
        if arguments.contains("-p") {
            output = validationOutput
        } else if arguments.contains("-iUDP") {
            output = udpOutput
        } else {
            output = tcpOutput
        }
        return PortCommandOutput(exitCode: 0, stdout: Data(output.utf8), stderr: Data())
    }
}

private final class StubPortProcessInspector: PortProcessInspecting {
    var currentIdentity: PortProcessIdentity?
    init(identity: PortProcessIdentity?) { currentIdentity = identity }
    func identity(pid: Int32) -> PortProcessIdentity? { currentIdentity }
}

private final class StubPortSignalSender: PortSignalSending {
    private(set) var sent: [(signal: Int32, pid: Int32)] = []
    func send(_ signal: Int32, to pid: Int32) throws { sent.append((signal, pid)) }
}

final class RecoveryCountdownRegistryTests: XCTestCase {
    func testReplacementTokenInvalidatesPreviousTimer() {
        let registry = RecoveryCountdownRegistry()
        let first = DispatchSource.makeTimerSource()
        let second = DispatchSource.makeTimerSource()
        first.schedule(deadline: .now() + 60)
        second.schedule(deadline: .now() + 60)
        let firstToken = UUID()
        let secondToken = UUID()

        XCTAssertNil(registry.install(profileID: "display", deadline: Date(), timer: first, token: firstToken))
        let replaced = registry.install(profileID: "display", deadline: Date(), timer: second, token: secondToken)
        replaced?.cancel()

        XCTAssertFalse(registry.isCurrent(profileID: "display", token: firstToken))
        XCTAssertTrue(registry.isCurrent(profileID: "display", token: secondToken))
        registry.remove(profileID: "display")?.cancel()
    }

    func testConcurrentReplaceReadAndRemoveLeavesConsistentState() {
        let registry = RecoveryCountdownRegistry()
        let queue = DispatchQueue(label: "recovery-countdown-test", attributes: .concurrent)
        let group = DispatchGroup()

        for index in 0..<200 {
            group.enter()
            queue.async {
                let timer = DispatchSource.makeTimerSource()
                timer.schedule(deadline: .now() + 60)
                registry.install(
                    profileID: "display-\(index % 4)",
                    deadline: Date().addingTimeInterval(60),
                    timer: timer,
                    token: UUID()
                )?.cancel()
                _ = registry.deadline(profileID: "display-\(index % 4)")
                if index.isMultiple(of: 3) {
                    registry.remove(profileID: "display-\(index % 4)")?.cancel()
                }
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        registry.removeAll().forEach { $0.cancel() }
        for index in 0..<4 {
            XCTAssertNil(registry.deadline(profileID: "display-\(index)"))
        }
    }
}
