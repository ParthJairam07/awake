import XCTest
@testable import Awake

final class ExternalDisplaysTests: XCTestCase {
    func testOnlyTheBuiltInPanelIsNotExternal() {
        XCTAssertFalse(ExternalDisplays.online(among: [1], isBuiltIn: { $0 == 1 }))
    }

    func testAnyOtherDisplayIsExternal() {
        XCTAssertTrue(ExternalDisplays.online(among: [1, 7], isBuiltIn: { $0 == 1 }))
        XCTAssertTrue(ExternalDisplays.online(among: [7], isBuiltIn: { $0 == 1 }), "clamshell: the panel is offline")
    }

    func testNoDisplaysIsNotExternal() {
        XCTAssertFalse(ExternalDisplays.online(among: [], isBuiltIn: { _ in true }))
    }

    @MainActor
    func testObserverReportsTheInjectedReader() {
        XCTAssertEqual(DisplayObserver(reader: { true }).externalOnline, true)
        XCTAssertEqual(DisplayObserver(reader: { nil }).externalOnline, nil)
    }
}

final class LidPolicyTests: XCTestCase {
    func testClosedWithAnExternalDisplayIsADesk() {
        XCTAssertEqual(LidPolicy.decide(closed: true, externalOnline: true, config: Config()), .desk)
    }

    func testClosedWithoutOneIsAClose() {
        XCTAssertEqual(LidPolicy.decide(closed: true, externalOnline: false, config: Config()), .close)
    }

    func testUnreadableDisplaysFailClosed() {
        XCTAssertEqual(LidPolicy.decide(closed: true, externalOnline: nil, config: Config()), .close)
    }

    func testTheSettingTurnsDeskModeOff() {
        var config = Config()
        config.skipLidActionsOnExternalDisplay = false
        XCTAssertEqual(LidPolicy.decide(closed: true, externalOnline: true, config: config), .close)
    }

    func testOpenIsOpenWhateverTheDisplays() {
        XCTAssertEqual(LidPolicy.decide(closed: false, externalOnline: true, config: Config()), .open)
        XCTAssertEqual(LidPolicy.decide(closed: false, externalOnline: nil, config: Config()), .open)
    }
}
