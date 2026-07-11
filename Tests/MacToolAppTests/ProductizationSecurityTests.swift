import AppKit
import CryptoKit
import Foundation
import MacToolBridge
import MacToolCore
import XCTest
@testable import MacToolApp

final class FinderActionCodecTests: XCTestCase {
    private let key = Data(repeating: 0x42, count: 32)
    private let actions: Set<String> = ["copyPath", "smartExtractAndDelete"]

    func testValidRequestRoundTrips() throws {
        let request = FinderActionRequest(
            id: UUID(uuidString: "0F7A709F-6B2F-421C-9B95-50D621260CBB")!,
            issuedAt: 1_700_000_000,
            action: "copyPath",
            paths: ["/tmp/a"]
        )
        let signed = try FinderActionCodec.sign(request, keyData: key)
        let decoded = try FinderActionCodec.verify(
            payload: signed.payload,
            signature: signed.signature,
            keyData: key,
            now: Date(timeIntervalSince1970: 1_700_000_010),
            allowedActions: actions
        )
        XCTAssertEqual(decoded, request)
    }

    func testTamperedSignatureIsRejected() throws {
        let signed = try FinderActionCodec.sign(
            FinderActionRequest(action: "copyPath", paths: ["/tmp/a"]),
            keyData: key
        )
        XCTAssertThrowsError(try FinderActionCodec.verify(
            payload: signed.payload,
            signature: signed.signature + "A",
            keyData: key,
            allowedActions: actions
        )) { XCTAssertEqual($0 as? FinderActionRequestError, .invalidSignature) }
    }

    func testPastAndFutureRequestsAreRejected() throws {
        for issuedAt in [1_699_999_969, 1_700_000_031] {
            let signed = try FinderActionCodec.sign(
                FinderActionRequest(issuedAt: Int64(issuedAt), action: "copyPath", paths: ["/tmp/a"]),
                keyData: key
            )
            XCTAssertThrowsError(try FinderActionCodec.verify(
                payload: signed.payload,
                signature: signed.signature,
                keyData: key,
                now: Date(timeIntervalSince1970: 1_700_000_000),
                allowedActions: actions
            )) { XCTAssertEqual($0 as? FinderActionRequestError, .expired) }
        }
    }

    func testUnknownActionEmptyPathsAndPathLimitAreRejected() throws {
        let cases: [(FinderActionRequest, FinderActionRequestError)] = [
            (FinderActionRequest(action: "unknown", paths: ["/tmp/a"]), .unknownAction),
            (FinderActionRequest(action: "copyPath", paths: []), .invalidPath),
            (FinderActionRequest(action: "copyPath", paths: (0...100).map { "/tmp/\($0)" }), .tooManyPaths)
        ]
        for (request, expected) in cases {
            let signed = try FinderActionCodec.sign(request, keyData: key)
            XCTAssertThrowsError(try FinderActionCodec.verify(
                payload: signed.payload,
                signature: signed.signature,
                keyData: key,
                allowedActions: actions
            )) { XCTAssertEqual($0 as? FinderActionRequestError, expected) }
        }
    }

    func testMissingKeyAndRelativePathAreRejected() throws {
        XCTAssertThrowsError(try FinderActionCodec.sign(
            FinderActionRequest(action: "copyPath", paths: ["/tmp/a"]),
            keyData: Data()
        )) { XCTAssertEqual($0 as? FinderActionRequestError, .missingCredential) }

        let request = FinderActionRequest(action: "copyPath", paths: ["/tmp/a"])
        let object: [String: Any] = [
            "version": request.version,
            "id": request.id.uuidString,
            "issuedAt": request.issuedAt,
            "action": request.action,
            "paths": ["relative/path"]
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let signature = Data(HMAC<SHA256>.authenticationCode(for: payloadData, using: SymmetricKey(data: key)))
        XCTAssertThrowsError(try FinderActionCodec.verify(
            payload: base64URL(payloadData),
            signature: base64URL(signature),
            keyData: key,
            allowedActions: actions
        )) { XCTAssertEqual($0 as? FinderActionRequestError, .invalidPath) }
    }

    func testURLCreationUnsupportedVersionAndInvalidEncoding() throws {
        let request = FinderActionRequest(action: "copyPath", paths: ["/tmp/a"])
        let url = try FinderActionCodec.makeURL(request: request, keyData: key)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(url.scheme, "macassistant")
        XCTAssertEqual(url.host, "context-menu")
        XCTAssertEqual(Set(components.queryItems?.map(\.name) ?? []), ["payload", "signature"])

        let unsupported = FinderActionRequest(version: 99, action: "copyPath", paths: ["/tmp/a"])
        let signed = try FinderActionCodec.sign(unsupported, keyData: key)
        XCTAssertThrowsError(try FinderActionCodec.verify(
            payload: signed.payload,
            signature: signed.signature,
            keyData: key,
            allowedActions: actions
        )) { XCTAssertEqual($0 as? FinderActionRequestError, .unsupportedVersion) }
        XCTAssertThrowsError(try FinderActionCodec.verify(
            payload: "not-base64!",
            signature: "bad!",
            keyData: key,
            allowedActions: actions
        )) { XCTAssertEqual($0 as? FinderActionRequestError, .invalidEncoding) }
    }

    func testCredentialFileIsStableAndPrivate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("bridge.key")
        let first = try BridgeCredentialFile.createIfMissing(at: url)
        let second = try BridgeCredentialFile.createIfMissing(at: url)
        XCTAssertEqual(first.count, 32)
        XCTAssertEqual(first, second)
        XCTAssertEqual(try BridgeCredentialFile.read(at: url), first)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

final class ProductSafetyTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryDirectories { try? FileManager.default.removeItem(at: url) }
        try super.tearDownWithError()
    }

    func testFreshDefaultsAreSafe() {
        XCTAssertTrue(AppConfig.defaultValue.profiles.isEmpty)
        XCTAssertEqual(AppConfig.defaultValue.schemaVersion, AppConfig.currentSchemaVersion)
        XCTAssertTrue(ClipboardConfig.defaultValue.enabled)
        XCTAssertEqual(ClipboardConfig.defaultValue.retentionDays, 30)
        XCTAssertFalse(DisconnectConfig.defaultValue.enabled)
        XCTAssertFalse(DisconnectConfig.defaultValue.allowSoftDisconnect)
        XCTAssertTrue(DisconnectConfig.defaultValue.externalOnly)
        XCTAssertTrue(DisconnectConfig.defaultValue.confirmBeforeDisconnect)
    }

    func testSensitivePasteboardMarkersAreExcluded() {
        XCTAssertTrue(ClipboardHistoryController.containsSensitiveMarker(["org.nspasteboard.ConcealedType"]))
        XCTAssertTrue(ClipboardHistoryController.containsSensitiveMarker(["org.nspasteboard.TransientType"]))
        XCTAssertTrue(ClipboardHistoryController.containsSensitiveMarker(["org.nspasteboard.AutoGeneratedType"]))
        XCTAssertFalse(ClipboardHistoryController.containsSensitiveMarker([NSPasteboard.PasteboardType.string.rawValue]))
    }

    func testCriticalSafetyPolicies() throws {
        XCTAssertTrue(DisplaySafetyPolicy.isAutomationEligible(profileEnabled: true, disconnectEnabled: true, allowSoftDisconnect: true))
        XCTAssertFalse(DisplaySafetyPolicy.isAutomationEligible(profileEnabled: false, disconnectEnabled: true, allowSoftDisconnect: true))
        XCTAssertEqual(DisplaySafetyPolicy.retryDelay(afterAttempt: 1), 0.2, accuracy: 0.001)
        XCTAssertEqual(DisplaySafetyPolicy.retryDelay(afterAttempt: 3), 0.8, accuracy: 0.001)
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(DisplaySafetyPolicy.shouldSuppressEvent(lastMutation: now.addingTimeInterval(-1), now: now))
        XCTAssertFalse(DisplaySafetyPolicy.shouldSuppressEvent(lastMutation: nil, now: now))
        XCTAssertFalse(DisplaySafetyPolicy.shouldSuppressEvent(lastMutation: now.addingTimeInterval(-3), now: now))
        XCTAssertEqual(DisplaySafetyPolicy.circuitOpenUntil(failureDate: now).timeIntervalSince1970, 1300)

        XCTAssertEqual(ClipboardPrivacyPolicy.defaultRetentionDays, 30)
        XCTAssertEqual(ClipboardPrivacyPolicy.batchRanges(itemCount: 0), [])
        XCTAssertEqual(ClipboardPrivacyPolicy.batchRanges(itemCount: 101), [0..<50, 50..<100, 100..<101])
        XCTAssertTrue(ClipboardPrivacyPolicy.containsSensitiveMarker(["org.nspasteboard.ConcealedType"]))
        XCTAssertFalse(ClipboardPrivacyPolicy.containsSensitiveMarker(["public.utf8-plain-text"]))

        XCTAssertTrue(ConfigurationRecoveryPolicy.requiresMigration(schemaVersion: 1, currentVersion: 2))
        XCTAssertFalse(ConfigurationRecoveryPolicy.requiresMigration(schemaVersion: 2, currentVersion: 2))
        XCTAssertTrue(ConfigurationRecoveryPolicy.canImport(schemaVersion: 2, currentVersion: 2))
        XCTAssertFalse(ConfigurationRecoveryPolicy.canImport(schemaVersion: 3, currentVersion: 2))
        XCTAssertEqual(ConfigurationRecoveryPolicy.directoryPermissions, 0o700)
        XCTAssertEqual(ConfigurationRecoveryPolicy.filePermissions, 0o600)

        XCTAssertEqual(PortEndpointParser.port(from: "127.0.0.1:8080 (LISTEN)"), 8080)
        XCTAssertEqual(PortEndpointParser.port(from: "[::1]:443"), 443)
        XCTAssertNil(PortEndpointParser.port(from: "localhost"))
        XCTAssertEqual(PortEndpointParser.inferredProtocol(from: "*:5353 UDP"), "UDP")
        let cipher = ClipboardCipher(keyData: Data(repeating: 0x5A, count: 32))
        let plaintext = Data("private clipboard".utf8)
        let sealed = try cipher.seal(plaintext)
        XCTAssertNotEqual(sealed, plaintext)
        XCTAssertEqual(try cipher.open(sealed), plaintext)
        XCTAssertEqual(cipher.authenticationHash(plaintext).count, 64)
        XCTAssertThrowsError(try cipher.open(Data("invalid".utf8)))
    }

    func testProfileStoreBacksUpCorruptConfigAndUsesSecurePermissions() throws {
        let root = try temporaryDirectory()
        let config = root.appendingPathComponent("config.json")
        let state = root.appendingPathComponent("state.json")
        try Data("not-json".utf8).write(to: config)
        let store = ProfileStore(configURL: config, stateURL: state, finderSyncConfigURL: nil)

        XCTAssertNotNil(store.recoveryNotice)
        XCTAssertTrue(store.profiles.isEmpty)
        let backups = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("config.json.corrupt-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testProfileStoreSerializesConcurrentTransactions() throws {
        let root = try temporaryDirectory()
        let store = ProfileStore(
            configURL: root.appendingPathComponent("config.json"),
            stateURL: root.appendingPathComponent("state.json"),
            finderSyncConfigURL: nil
        )
        let queue = DispatchQueue(label: "profile-test", attributes: .concurrent)
        let group = DispatchGroup()
        let capturedErrors = LockedErrors()
        for index in 0..<25 {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    try store.updateConfig { config in
                        config.profiles.append(Self.profile(id: "p-\(index)"))
                    }
                } catch {
                    capturedErrors.append(error)
                }
            }
        }
        group.wait()
        XCTAssertTrue(capturedErrors.isEmpty)
        XCTAssertEqual(Set(store.profiles.map(\.id)).count, 25)
    }

    func testBackgroundTasksRequireCompletedPrivacyNotice() throws {
        let root = try temporaryDirectory()
        let store = ProfileStore(
            configURL: root.appendingPathComponent("config.json"),
            stateURL: root.appendingPathComponent("state.json"),
            finderSyncConfigURL: nil
        )
        XCTAssertFalse(store.backgroundTasksAllowed)
        XCTAssertFalse(store.displayAutomationAllowed)
        try store.completeOnboarding(clipboardEnabled: true, displayAutomationApproved: false)
        XCTAssertTrue(store.backgroundTasksAllowed)
        XCTAssertFalse(store.displayAutomationAllowed)
    }

    func testUnavailableDisplayBackendIsReportedAndDisabledProfileIsIgnored() {
        let controller = SoftDisconnectController(
            detector: DisplayDetector(),
            backend: UnavailableDisplayBackend(reason: "测试不可用")
        )
        XCTAssertFalse(controller.backendAvailability.available)
        XCTAssertEqual(controller.backendAvailability.reason, "测试不可用")
        XCTAssertFalse(controller.desiredCloseEnabled(profile: Self.profile(id: "disabled", enabled: false)))
    }

    @MainActor
    func testCustomControlsExposeAccessibilityRoles() {
        let button = MacTextButton(title: "继续")
        let toggle = MacSwitchControl()
        let search = MacSearchField()
        let slider = MacSliderControl(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
        XCTAssertEqual(button.accessibilityRole(), .button)
        XCTAssertEqual(button.accessibilityLabel(), "继续")
        XCTAssertEqual(toggle.accessibilityRole(), .checkBox)
        XCTAssertEqual(search.accessibilityRole(), .textField)
        XCTAssertEqual(slider.accessibilityRole(), .slider)
        XCTAssertTrue(button.acceptsFirstResponder)
        XCTAssertTrue(toggle.acceptsFirstResponder)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private static func profile(id: String, enabled: Bool = true) -> DisplayProfile {
        DisplayProfile(
            id: id,
            enabled: enabled,
            name: id,
            matchMode: .strict,
            match: .empty,
            colorLock: .p3Default,
            disconnect: DisconnectConfig(
                enabled: true,
                allowSoftDisconnect: true,
                autoReconnect: true,
                autoReconnectDelaySeconds: 30,
                externalOnly: true
            ),
            automationEnabled: false
        )
    }
}

private final class LockedErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Error] = []

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return values.isEmpty
    }

    func append(_ error: Error) {
        lock.lock(); values.append(error); lock.unlock()
    }
}
