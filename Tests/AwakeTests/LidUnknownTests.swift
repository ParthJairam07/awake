import XCTest
@testable import Awake

/// On a Mac whose lid state cannot be read (a desktop, a virtual machine)
/// the menu and `awake status` said "Lid: open" while the phone's Machine
/// tab said "unknown". Unknown is not open, and every surface says so.
@MainActor
final class LidUnknownTests: XCTestCase {
    private func services(home: TempHome, lid: Bool?) -> AppServices {
        AppServices(
            paths: home.paths,
            notifier: RecordingNotifier(),
            audio: FakeAudioControl(),
            processControl: FakeProcessControl(),
            locationPermission: LocationPermission(authorizationStatus: .authorizedAlways),
            lidSimulation: nil,
            lidSimulationEnabled: false,
            clamshell: { lid }
        )
    }

    func testTheMenuLineSaysUnknown() {
        XCTAssertEqual(
            StatusLines.machine(lidClosed: false, lidKnown: false, watts: nil, wifiSSID: nil, batteryPercent: nil, isCharging: false),
            "Lid: unknown"
        )
        XCTAssertEqual(StatusLines.lidText(closed: true, onDesk: false, known: false), "unknown")
        XCTAssertEqual(StatusLines.lidText(closed: false, onDesk: false, known: true), "open")
        XCTAssertEqual(StatusLines.lidText(closed: true, onDesk: true, known: true), "closed, external display")
    }

    /// An unreadable lid reaches the menu and status.json as unknown, at
    /// launch and when the menu refreshes.
    func testAnUnreadableLidIsUnknownInTheMenuAndStatusJSON() throws {
        let home = TempHome()
        defer { home.destroy() }
        let s = services(home: home, lid: nil)
        XCTAssertTrue(s.status.lidKnown, "nothing read yet")
        s.logStartupSnapshot()
        XCTAssertFalse(s.status.lidKnown)
        s.refreshInstant()
        XCTAssertFalse(s.status.lidKnown)

        let source = LiveStatusSource(services: s)
        XCTAssertFalse(source.lidKnown)
        let h = Harness()
        defer { h.home.destroy() }
        let titles = StatusItemController.menuItems(manager: h.makeManager(), status: source).map(\.title)
        XCTAssertTrue(titles.contains { $0.hasPrefix("Lid: unknown") }, "\(titles)")
        XCTAssertFalse(titles.contains { $0.contains("Lid: open") }, "\(titles)")

        let snapshot = s.snapshot()
        XCTAssertFalse(snapshot.lidKnown)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: StatusSnapshot.encode(snapshot)) as? [String: Any])
        XCTAssertEqual(object["lidKnown"] as? Bool, false)
    }

    func testAReadableLidIsKnown() {
        let home = TempHome()
        defer { home.destroy() }
        let open = services(home: home, lid: false)
        open.logStartupSnapshot()
        XCTAssertTrue(open.status.lidKnown)
        XCTAssertFalse(open.status.lidClosed)
        let closed = services(home: home, lid: true)
        closed.refreshInstant()
        XCTAssertTrue(closed.status.lidKnown)
        XCTAssertTrue(closed.status.lidClosed)
        XCTAssertTrue(closed.snapshot().lidKnown)
    }

    func testAStatusJSONFromBeforeTheKeyReadsAsKnown() throws {
        let old = #"{"active":false,"chargerDraining":false,"dockerPaused":false,"frozenCount":0,"isCharging":false,"lidClosed":true,"lidOnDesk":false,"lowPowerSetByUs":false,"thermalState":"nominal","updatedAt":"2027-01-15T07:59:30Z"}"#
        let decoded = try Store.makeDecoder().decode(StatusSnapshot.self, from: Data(old.utf8))
        XCTAssertTrue(decoded.lidKnown)
        XCTAssertTrue(decoded.lidClosed)
    }

    /// The phone page, run in JavaScriptCore: the Session tab (status.json)
    /// and the Machine tab (a nil reading) both say "unknown".
    func testThePhoneSaysUnknownOnBothTabs() throws {
        let js = try PhoneScript()
        func lid(_ args: String) -> String { js.call("lidText", args) }
        XCTAssertEqual(lid("false, false, false"), "\"unknown\"", "Session tab, lidKnown false")
        XCTAssertEqual(lid("null, false, true"), "\"unknown\"", "Machine tab, no reading")
        XCTAssertEqual(lid("false, false, undefined"), "\"open\"", "a status from before lidKnown")
        XCTAssertEqual(lid("false, false, true"), "\"open\"")
        XCTAssertEqual(lid("true, false, true"), "\"closed\"")
        XCTAssertEqual(lid("true, true, true"), "\"closed, external display\"")
        let script = String(decoding: PhoneWebAsset.script.data, as: UTF8.self)
        XCTAssertTrue(script.contains("fact(facts, 'Lid', lidText(status.lidClosed, status.lidOnDesk, status.lidKnown))"))
        XCTAssertTrue(script.contains("fact(list, 'Lid', lidText(m.lidClosed, false, true))"))
    }
}
