import XCTest
@testable import Awake

/// The phone app's lines in the right-click menu and in Settings.
@MainActor
final class PhoneAppUITests: XCTestCase {
    private func items(phone: (text: String, isWarning: Bool)?) -> [StatusMenu.Item] {
        StatusMenu.items(
            sessionActive: false,
            sleepHeld: false,
            machine: nil,
            actions: nil,
            throttledBrowsers: [],
            error: nil,
            phone: phone
        )
    }

    func testMenuHasNoPhoneLinesWhileThePhoneAppIsOff() {
        let titles = items(phone: nil).map(\.title)
        XCTAssertFalse(titles.contains(StatusMenu.pairPhoneTitle))
        XCTAssertFalse(titles.contains { $0.hasPrefix("Phone app") })
    }

    func testMenuShowsThePhoneLineAndThePairingItem() {
        let out = items(phone: ("Phone app: 1 phone paired", false))
        let line = out.first { $0.title == "Phone app: 1 phone paired" }
        XCTAssertEqual(line?.kind, .info)
        XCTAssertEqual(out.first { $0.title == StatusMenu.pairPhoneTitle }?.kind, .pairPhone)
    }

    func testMenuWarnsWhenTailscaleIsNotFound() {
        let line = PhoneAppController.menuLine(
            enabled: true,
            listening: [PhoneServer.loopback],
            tailscale: Tailscale.Addresses(),
            paired: 0,
            pairingCode: nil
        )
        XCTAssertEqual(line?.text, "Phone app: Tailscale not found")
        XCTAssertEqual(line?.isWarning, true)
        let out = items(phone: line)
        XCTAssertEqual(out.first { $0.title == "Phone app: Tailscale not found" }?.kind, .warning)
    }

    func testMenuShowsThePairingCodeWhileAWindowIsOpen() {
        let line = PhoneAppController.menuLine(
            enabled: true,
            listening: [PhoneServer.loopback],
            tailscale: Tailscale.Addresses(),
            paired: 0,
            pairingCode: "123456"
        )
        XCTAssertEqual(line?.text, "Phone app: pairing code 123456")
        XCTAssertNil(PhoneAppController.menuLine(enabled: false, listening: [], tailscale: Tailscale.Addresses(), paired: 2, pairingCode: "123456"))
    }

    func testPairingCodeIsSpacedForReading() {
        XCTAssertEqual(PhoneAppSettings.spaced("123456"), "123 456")
        XCTAssertEqual(PhoneAppSettings.spaced("12"), "12")
    }

    func testExpiryLineCountsDownAndNamesTheTriesLeft() {
        let now = Date(timeIntervalSince1970: 1_000)
        var window = PhonePairing.Window(code: "123456", expiresAt: now.addingTimeInterval(300), attemptsLeft: 5)
        XCTAssertEqual(PhoneAppSettings.expiry(window, now: now), "Expires in 5:00. 5 tries left.")
        window.attemptsLeft = 1
        XCTAssertEqual(PhoneAppSettings.expiry(window, now: now.addingTimeInterval(235)), "Expires in 1:05. 1 try left.")
        XCTAssertEqual(PhoneAppSettings.expiry(window, now: now.addingTimeInterval(400)), "Expires in 0:00. 1 try left.")
    }

    func testDeviceLineSaysWhenThePhoneWasLastSeen() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var device = PhoneDevice(id: "ab", name: "iPhone", salt: "", hash: "", createdAt: now.addingTimeInterval(-86_400), lastSeenAt: nil)
        XCTAssertTrue(PhoneAppSettings.deviceLine(device, now: now).hasPrefix("paired "))
        XCTAssertFalse(PhoneAppSettings.deviceLine(device, now: now).contains("seen"))
        device.lastSeenAt = now.addingTimeInterval(-30)
        XCTAssertTrue(PhoneAppSettings.deviceLine(device, now: now).hasSuffix("connected now"))
        device.lastSeenAt = now.addingTimeInterval(-7_200)
        XCTAssertTrue(PhoneAppSettings.deviceLine(device, now: now).contains("last seen"))
    }

    func testConfigKeepsThePhoneAppOffByDefaultAndReadsOldFiles() throws {
        let fresh = Config()
        XCTAssertFalse(fresh.phoneApp)
        XCTAssertEqual(fresh.phonePort, 7788)
        let old = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertFalse(old.phoneApp)
        XCTAssertEqual(old.phonePort, 7788)
    }
}
