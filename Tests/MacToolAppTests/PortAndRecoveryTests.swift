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

    private func display(id: UInt32, edid: String, name: String, serial: String) -> DisplaySnapshot {
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
            isActive: true,
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
