//
//  ConfigurationTests.swift
//  OleOleMoveControllerTests
//

import XCTest
@testable import OleOleMoveController

final class ConfigurationTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDefaultAssignments() {
        let c = AppConfiguration.default
        XCTAssertEqual(c.knobs.map(\.assignment), (20...23).map { CCAssignment(channel: 1, controller: $0) })
        XCTAssertEqual(c.knobs.map(\.name), ["S1", "S2", "S3", "S4"])
        XCTAssertEqual(c.pads.count, 4)
        // XY1〜4 = CC24/25, 26/27, 28/29, 30/31
        for (i, pad) in c.pads.enumerated() {
            XCTAssertEqual(pad.presets.count, 1)
            XCTAssertEqual(pad.presets[0].xAssignment, CCAssignment(channel: 1, controller: 24 + i * 2))
            XCTAssertEqual(pad.presets[0].yAssignment, CCAssignment(channel: 1, controller: 25 + i * 2))
            XCTAssertFalse(pad.presets[0].reverseX)
            XCTAssertFalse(pad.presets[0].reverseY)
        }
        XCTAssertTrue(c.pads.allSatisfy(\.isEnabled))
        XCTAssertEqual(c.mirrorURL, "http://172.16.254.1:7681")  // USB-C 経由
        XCTAssertTrue(c.mirrorWifiFallback)
        XCTAssertNil(c.midiDestination)
    }

    func testStoreRoundTrip() {
        let store = ConfigurationStore(defaults: defaults, key: "k")
        var c = AppConfiguration.default
        c.knobs[2] = KnobConfiguration(name: "CUTOFF", assignment: CCAssignment(channel: 7, controller: 74), value: 99)
        c.pads[1].presets[0].xAssignment = CCAssignment(channel: 3, controller: 1)
        c.pads[1].presets[0].yAssignment = CCAssignment(channel: 4, controller: 2)
        c.pads[1].presets[0].x = 0.25
        c.pads[1].presets[0].y = 0.75
        c.pads[1].presets[0].reverseY = true
        c.pads[1].presets.append(XYPadPreset(name: "Filter", xAssignment: .init(channel: 9, controller: 74),
                                             yAssignment: .init(channel: 9, controller: 71)))
        c.pads[1].selectedPreset = 1
        c.pads[1].isEnabled = false
        c.midiDestination = MIDIDestinationIdentity(uniqueID: 12345, name: "Move")
        c.mirrorURL = "http://192.168.1.100:7681"
        c.stopwatch = StopwatchState(runningSince: Date(timeIntervalSince1970: 1000), accumulated: 12, showsMilliseconds: true)
        store.saveNow(c)

        let loaded = ConfigurationStore(defaults: defaults, key: "k").load()
        XCTAssertEqual(loaded, c)
    }

    func testMissingDataGivesDefaults() {
        XCTAssertEqual(ConfigurationStore(defaults: defaults, key: "none").load(), .default)
    }

    func testCorruptDataGivesDefaults() {
        defaults.set(Data("garbage".utf8), forKey: "bad")
        XCTAssertEqual(ConfigurationStore(defaults: defaults, key: "bad").load(), .default)
    }

    func testPartialJSONFillsMissingKeys() throws {
        let json = #"{"mirrorURL":"http://10.0.0.5:7681","knobs":[{"name":"A","assignment":{"channel":2,"controller":5},"value":3}]}"#
        let c = try JSONDecoder().decode(AppConfiguration.self, from: Data(json.utf8))
        XCTAssertEqual(c.mirrorURL, "http://10.0.0.5:7681")
        XCTAssertEqual(c.knobs.count, 4)
        XCTAssertEqual(c.knobs[0].name, "A")
        XCTAssertEqual(c.knobs[1], KnobConfiguration.default(index: 1))
        XCTAssertEqual(c.pads, AppConfiguration.default.pads)
    }

    func testDebouncedSaveWritesLatest() {
        let store = ConfigurationStore(defaults: defaults, key: "d", debounce: 0.05)
        var c = AppConfiguration.default
        for v in 0..<10 {
            c.knobs[0].value = v
            let snapshot = c
            store.scheduleSave { snapshot }
        }
        let exp = expectation(description: "saved")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(store.load().knobs[0].value, 9)
    }

    func testLegacyMoveLocalDefaultMigratesToUSB() throws {
        let legacy = #"{"mirrorURL":"http://move.local:7681"}"#
        XCTAssertEqual(try JSONDecoder().decode(AppConfiguration.self, from: Data(legacy.utf8)).mirrorURL,
                       "http://172.16.254.1:7681")
        // ユーザーが明示的に指定したIPはそのまま
        let custom = #"{"mirrorURL":"http://192.168.1.100:7681"}"#
        XCTAssertEqual(try JSONDecoder().decode(AppConfiguration.self, from: Data(custom.utf8)).mirrorURL,
                       "http://192.168.1.100:7681")
    }

    /// 旧形式（パッド2つ、MIDI設定1つ、ノブ名 "KNOB n"）の保存データから移行できる。
    func testLegacyPadAndKnobDataMigrates() throws {
        let json = #"""
        {"knobs":[{"name":"KNOB 1","assignment":{"channel":1,"controller":20},"value":5},
                  {"name":"CUTOFF","assignment":{"channel":2,"controller":74},"value":9}],
         "pads":[{"name":"XY PAD 1","xAssignment":{"channel":3,"controller":40},"yAssignment":{"channel":4,"controller":41},
                  "x":0.1,"y":0.9,"isEnabled":false,"reverseX":true,"reverseY":false}]}
        """#
        let c = try JSONDecoder().decode(AppConfiguration.self, from: Data(json.utf8))
        XCTAssertEqual(c.knobs[0].name, "S1")
        XCTAssertEqual(c.knobs[1].name, "CUTOFF")       // ユーザーが付けた名前はそのまま
        XCTAssertEqual(c.pads.count, 4)                  // 足りない分は既定値
        let p = c.pads[0]
        XCTAssertEqual(p.name, "XY 1")
        XCTAssertFalse(p.isEnabled)
        XCTAssertEqual(p.presets.count, 1)
        XCTAssertEqual(p.presets[0].name, "MIDI 1")
        XCTAssertEqual(p.presets[0].xAssignment, CCAssignment(channel: 3, controller: 40))
        XCTAssertEqual(p.presets[0].yAssignment, CCAssignment(channel: 4, controller: 41))
        XCTAssertTrue(p.presets[0].reverseX)
        XCTAssertEqual(p.presets[0].x, 0.1)
        XCTAssertEqual(p.presets[0].y, 0.9)
        XCTAssertEqual(c.pads[3], XYPadConfiguration.default(index: 3))
    }

    func testMirrorURLValidation() {
        XCTAssertEqual(MirrorController.validatedURL("http://move.local:7681")?.port, 7681)
        XCTAssertEqual(MirrorController.validatedURL("192.168.1.100:7681")?.absoluteString, "http://192.168.1.100:7681")
        XCTAssertEqual(MirrorController.validatedURL("  http://10.0.0.2:7681 ")?.host, "10.0.0.2")
        XCTAssertNil(MirrorController.validatedURL(""))
        XCTAssertNil(MirrorController.validatedURL("ftp://move.local"))
        XCTAssertNil(MirrorController.validatedURL("http://"))
    }
}

final class StopwatchTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testStartStopAccumulates() {
        var s = StopwatchState.default
        s.start(at: t0)
        XCTAssertEqual(s.elapsed(at: t0.addingTimeInterval(10)), 10, accuracy: 1e-9)
        s.stop(at: t0.addingTimeInterval(10))
        XCTAssertEqual(s.elapsed(at: t0.addingTimeInterval(500)), 10, accuracy: 1e-9) // 停止中は増えない
        s.start(at: t0.addingTimeInterval(100))
        XCTAssertEqual(s.elapsed(at: t0.addingTimeInterval(105)), 15, accuracy: 1e-9)
    }

    func testElapsedIsComputedFromTimeNotTicks() {
        // バックグラウンドで1時間経過しても、時刻から正しく求まる
        var s = StopwatchState.default
        s.start(at: t0)
        XCTAssertEqual(s.elapsed(at: t0.addingTimeInterval(3600 + 61)), 3661, accuracy: 1e-9)
    }

    func testResetWhileRunningRestartsFromZero() {
        var s = StopwatchState.default
        s.start(at: t0)
        s.reset(at: t0.addingTimeInterval(30))
        XCTAssertTrue(s.isRunning)
        XCTAssertEqual(s.elapsed(at: t0.addingTimeInterval(32)), 2, accuracy: 1e-9)
    }

    func testResetWhileStopped() {
        var s = StopwatchState.default
        s.start(at: t0)
        s.stop(at: t0.addingTimeInterval(5))
        s.reset(at: t0.addingTimeInterval(6))
        XCTAssertFalse(s.isRunning)
        XCTAssertEqual(s.elapsed(at: t0.addingTimeInterval(100)), 0)
    }

    func testDoubleStartIsIgnored() {
        var s = StopwatchState.default
        s.start(at: t0)
        s.start(at: t0.addingTimeInterval(50))
        XCTAssertEqual(s.elapsed(at: t0.addingTimeInterval(60)), 60, accuracy: 1e-9)
    }

    func testClockGoingBackwardsDoesNotGoNegative() {
        var s = StopwatchState.default
        s.start(at: t0)
        XCTAssertEqual(s.elapsed(at: t0.addingTimeInterval(-10)), 0)
    }

    func testFormatting() {
        XCTAssertEqual(StopwatchFormatter.string(0, milliseconds: false), "00:00:00")
        XCTAssertEqual(StopwatchFormatter.string(3661.789, milliseconds: false), "01:01:01")
        XCTAssertEqual(StopwatchFormatter.string(3661.789, milliseconds: true), "01:01:01.789")
        XCTAssertEqual(StopwatchFormatter.string(59.9999, milliseconds: false), "00:00:59")
        XCTAssertEqual(StopwatchFormatter.string(100 * 3600, milliseconds: false), "100:00:00")
    }
}

final class LayoutTests: XCTestCase {
    /// 主要なiPadの横画面サイズ（pt）
    let sizes: [CGSize] = [
        CGSize(width: 1133, height: 744),   // iPad mini
        CGSize(width: 1180, height: 820),   // iPad 10th / Air 11"
        CGSize(width: 1194, height: 834),   // iPad Pro 11"
        CGSize(width: 1210, height: 834),   // iPad Pro 11" (M4)
        CGSize(width: 1366, height: 1024),  // iPad Pro 12.9"
        CGSize(width: 1376, height: 1032),  // iPad Pro 13" (M4)
    ]

    func testEverythingFitsWithoutScrolling() {
        for size in sizes {
            let l = ControllerLayout(size: size)
            // 縦：上段 + 上エリア + XYパッド段
            let totalH = l.margin * 2 + l.topBarHeight + l.topAreaHeight + l.padBlockHeight + l.spacing * 2
            XCTAssertLessThanOrEqual(totalH, size.height + 0.5, "height \(size)")
            XCTAssertLessThanOrEqual(l.mirrorHeight, l.topAreaHeight, "mirror height \(size)")
            // 横：左列（Move画面 / XYパッド2つ）+ 右列
            let leftW = max(l.mirrorWidth, l.padSetWidth)
            XCTAssertLessThanOrEqual(l.margin * 2 + leftW + l.columnGap + l.rightColumnWidth, size.width + 0.5,
                                     "width \(size)")
            XCTAssertEqual(l.mirrorWidth, l.mirrorHeight * 2)
            XCTAssertEqual(l.mirrorHeight.truncatingRemainder(dividingBy: 32), 0)
            XCTAssertGreaterThanOrEqual(l.mirrorHeight, 288, "mirror should be large on \(size)")
            XCTAssertLessThanOrEqual(ControllerLayout.sliderHeight + 38, l.topAreaHeight, "sliders fit on \(size)")
            // 横：スライダー（KICK / HAT / S1〜S4）が右列からはみ出さない
            let n = ControllerLayout.sliderCount
            XCTAssertLessThanOrEqual(ControllerLayout.sliderWidth * n + l.sliderSpacing * (n - 1),
                                     l.rightColumnWidth + 0.5, "sliders width \(size)")
            XCTAssertGreaterThanOrEqual(l.sliderSpacing, ControllerLayout.minSliderSpacing)
        }
        XCTAssertEqual(ControllerLayout.padSize, 180, "参考アプリと同じサイズ")
        XCTAssertEqual(ControllerLayout.sliderWidth, 800 / 16 * 1.3, "参考アプリの ModWheel と同じ幅")
        XCTAssertEqual(ControllerLayout.sliderHeight, 150 * 1.4, "参考アプリの ModWheel と同じ高さ")
    }
}
