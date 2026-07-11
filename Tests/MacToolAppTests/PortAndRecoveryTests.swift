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
