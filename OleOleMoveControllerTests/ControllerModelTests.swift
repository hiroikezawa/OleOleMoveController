//
//  ControllerModelTests.swift
//  OleOleMoveControllerTests
//

import XCTest
@testable import OleOleMoveController

@MainActor
final class ControllerModelTests: XCTestCase {

    func testSliderRelativeDrag() {
        let k = KnobModel(index: 0, configuration: KnobConfiguration(name: "S1", assignment: .init(channel: 1, controller: 20), value: 64))
        // 高さ300ptのスライダーで、上へ半分 → +63.5 → 127 にクランプ
        k.drag(delta: 150, fullRange: 300)
        XCTAssertEqual(k.value, 127)
        k.endDrag()
        // 新しいドラッグは現在値から相対的に始まる（タッチ位置で値が飛ばない）
        k.drag(delta: 0, fullRange: 300)
        XCTAssertEqual(k.value, 127)
        k.drag(delta: -300, fullRange: 300)
        XCTAssertEqual(k.value, 0)
        k.endDrag()
    }

    func testSliderFineAdjustment() {
        let k = KnobModel(index: 0, configuration: KnobConfiguration(name: "S1", assignment: .init(channel: 1, controller: 20), value: 10))
        let onePoint = 400.0 / 127
        k.drag(delta: onePoint, fullRange: 400)
        XCTAssertEqual(k.value, 11)
        k.drag(delta: onePoint * 3, fullRange: 400)
        XCTAssertEqual(k.value, 13)
        k.endDrag()
    }

    func testPadTouchMappingAndReverse() {
        let p = XYPadModel(index: 0, configuration: .default(index: 0))
        let size = CGSize(width: 300, height: 300)
        p.touch(at: CGPoint(x: 300, y: 300), in: size)    // 右下
        XCTAssertEqual(p.xValue, 127)
        XCTAssertEqual(p.yValue, 0)
        XCTAssertTrue(p.isTouching)
        p.endTouch(at: CGPoint(x: 0, y: 0), in: size)     // 左上
        XCTAssertFalse(p.isTouching)
        XCTAssertEqual(p.xValue, 0)
        XCTAssertEqual(p.yValue, 127)
        // 指を離しても位置を保持
        XCTAssertEqual(p.x, 0)
        XCTAssertEqual(p.y, 1)

        p.reverseX = true
        p.reverseY = true
        XCTAssertEqual(p.xValue, 127)
        XCTAssertEqual(p.yValue, 0)
        XCTAssertEqual(p.xMessage.bytes, [0xB0, 24, 127])
        XCTAssertEqual(p.yMessage.bytes, [0xB0, 25, 0])
    }

    func testPadCenter() {
        let p = XYPadModel(index: 1, configuration: .default(index: 1))
        p.touch(at: .zero, in: CGSize(width: 100, height: 100))
        p.center()
        XCTAssertEqual(p.xValue, 64)
        XCTAssertEqual(p.yValue, 64)
    }

    func testIndependentAxisAssignments() {
        let p = XYPadModel(index: 0, configuration: .default(index: 0))
        p.xAssignment = CCAssignment(channel: 2, controller: 74)
        p.yAssignment = CCAssignment(channel: 9, controller: 71)
        p.endTouch(at: CGPoint(x: 50, y: 50), in: CGSize(width: 100, height: 100))
        XCTAssertEqual(p.xMessage.bytes, [0xB1, 74, 64])
        XCTAssertEqual(p.yMessage.bytes, [0xB8, 71, 64])
    }

    /// Core MIDI を実際に通す結合テスト：仮想Destination（ループバック）へ送信し、受信バイト列を確認する。
    func testCoreMIDILoopbackDeliversCorrectBytes() async throws {
        let midi = MIDIManager(preferred: nil)
        if case .unavailable(let reason) = midi.state {
            throw XCTSkip("Core MIDI unavailable: \(reason)")
        }
        midi.setLoopback(true)
        defer { midi.setLoopback(false) }
        XCTAssertTrue(midi.loopbackEnabled, midi.log.snapshot().map(\.text).joined(separator: "\n"))
        // MIDIサーバー側の構成変更は非同期に反映される
        var found: MIDIDestinationInfo?
        for _ in 0..<40 where found == nil {
            midi.refreshDestinations()
            found = midi.destinations.first { $0.name == MIDIManager.loopbackName }
            if found == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        guard let loop = found else {
            throw XCTSkip("Loopback destination not listed: \(midi.destinations.map(\.name))")
        }
        midi.select(loop.identity)
        XCTAssertTrue(midi.state.isConnected)

        midi.send(ControlChange(channel: 3, controller: 22, value: 99), for: .knob(2), mode: .force)
        midi.send(ControlChange(channel: 16, controller: 27, value: 0), for: .padY(1), mode: .force)

        var rx: [String] = []
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 50_000_000)
            rx = midi.log.snapshot().map(\.text).filter { $0.hasPrefix("RX") }
            if rx.count >= 2 { break }
        }
        XCTAssertTrue(rx.contains { $0.contains("[B2 16 63]") }, "got \(rx)")
        XCTAssertTrue(rx.contains { $0.contains("[BF 1B 00]") }, "got \(rx)")
    }
}

@MainActor
final class XYPadPresetTests: XCTestCase {
    private func pad() -> XYPadModel { XYPadModel(index: 0, configuration: .default(index: 0)) }

    func testAddPresetDuplicatesAndSelects() {
        let p = pad()
        p.addPreset()
        XCTAssertEqual(p.presets.count, 2)
        XCTAssertEqual(p.selectedPreset, 1)
        XCTAssertEqual(p.presetName, "MIDI 2")
        XCTAssertEqual(p.xAssignment, CCAssignment(channel: 1, controller: 26))
        XCTAssertEqual(p.yAssignment, CCAssignment(channel: 1, controller: 27))
    }

    func testSwitchingPresetChangesOutgoingCCAndKeepsPositionPerPreset() {
        let p = pad()
        let size = CGSize(width: 100, height: 100)
        p.endTouch(at: CGPoint(x: 100, y: 100), in: size)   // MIDI 1: X=127, Y=0
        p.addPreset()
        p.presetName = "Filter"
        p.xAssignment = CCAssignment(channel: 5, controller: 74)
        p.endTouch(at: CGPoint(x: 0, y: 0), in: size)       // Filter: X=0, Y=127
        XCTAssertEqual(p.xMessage.bytes, [0xB4, 74, 0])

        p.selectPreviousPreset()
        XCTAssertEqual(p.presetName, "MIDI 1")
        XCTAssertEqual(p.xValue, 127)                       // MIDI 1 の位置に戻る
        XCTAssertEqual(p.yValue, 0)
        XCTAssertEqual(p.xMessage.bytes, [0xB0, 24, 127])

        p.selectNextPreset()
        XCTAssertEqual(p.presetName, "Filter")
        XCTAssertEqual(p.xValue, 0)
        XCTAssertEqual(p.yValue, 127)
    }

    func testNextPreviousWrapAround() {
        let p = pad()
        p.addPreset(); p.addPreset()       // 3つ、選択は最後
        p.selectNextPreset()
        XCTAssertEqual(p.selectedPreset, 0)
        p.selectPreviousPreset()
        XCTAssertEqual(p.selectedPreset, 2)
    }

    func testCannotDeleteLastPreset() {
        let p = pad()
        p.deletePreset(at: 0)
        XCTAssertEqual(p.presets.count, 1)
        p.addPreset()
        p.deletePreset(at: 1)
        XCTAssertEqual(p.presets.count, 1)
        XCTAssertEqual(p.selectedPreset, 0)
    }

    func testPresetLimit() {
        let p = pad()
        for _ in 0..<40 { p.addPreset() }
        XCTAssertEqual(p.presets.count, XYPadConfiguration.maxPresets)
    }

    func testMovePresetKeepsSelection() {
        let p = pad()
        p.addPreset()                      // [MIDI 1, MIDI 2]、選択=1
        p.movePreset(from: 1, by: -1)      // [MIDI 2, MIDI 1]
        XCTAssertEqual(p.selectedPreset, 0)
        XCTAssertEqual(p.presetName, "MIDI 2")
        XCTAssertEqual(p.presets.map(\.name), ["MIDI 2", "MIDI 1"])
    }

    func testConfigurationRoundTrip() throws {
        let p = pad()
        p.addPreset()
        p.presetName = "Delay"
        let data = try JSONEncoder().encode(p.configuration)
        let decoded = try JSONDecoder().decode(XYPadConfiguration.self, from: data)
        XCTAssertEqual(decoded, p.configuration)
        XCTAssertEqual(decoded.presets.map(\.name), ["MIDI 1", "Delay"])
        XCTAssertEqual(decoded.selectedPreset, 1)
    }
}

@MainActor
final class XYPadSetTests: XCTestCase {
    private func makeSet() -> XYPadSetModel {
        XYPadSetModel(index: 0, pads: [XYPadModel(index: 0, configuration: .default(index: 0)),
                                       XYPadModel(index: 1, configuration: .default(index: 1))])
    }

    func testSwitchingChangesBothPads() {
        let set = makeSet()
        set.addPreset()
        set.presetName = "Filter"
        set.pads[0].xAssignment = CCAssignment(channel: 2, controller: 74)
        set.pads[1].yAssignment = CCAssignment(channel: 3, controller: 71)
        XCTAssertEqual(set.pads.map(\.selectedPreset), [1, 1])
        XCTAssertEqual(set.pads.map(\.presetName), ["Filter", "Filter"])

        set.selectPreviousPreset()
        XCTAssertEqual(set.pads.map(\.selectedPreset), [0, 0])
        XCTAssertEqual(set.pads[0].xAssignment, CCAssignment(channel: 1, controller: 24))
        XCTAssertEqual(set.pads[1].yAssignment, CCAssignment(channel: 1, controller: 27))

        set.selectNextPreset()
        XCTAssertEqual(set.pads[0].xAssignment, CCAssignment(channel: 2, controller: 74))
        XCTAssertEqual(set.pads[1].yAssignment, CCAssignment(channel: 3, controller: 71))
    }

    func testAddDeleteMoveKeepPadsInSync() {
        let set = makeSet()
        set.addPreset(); set.addPreset()
        XCTAssertEqual(set.pads.map(\.presets.count), [3, 3])
        set.movePreset(from: 2, by: -1)
        XCTAssertEqual(set.pads[0].presets.map(\.name), set.pads[1].presets.map(\.name))
        set.deletePreset(at: set.selectedPreset)
        XCTAssertEqual(set.pads.map(\.presets.count), [2, 2])
        XCTAssertEqual(set.pads[0].selectedPreset, set.pads[1].selectedPreset)
    }

    /// 2つのパッドでMIDI設定の数や名前が食い違った保存データでも、セットとして揃えて読み込む。
    func testMismatchedPadsAreNormalized() {
        var a = XYPadConfiguration.default(index: 0)
        a.presets.append(XYPadPreset(name: "B", xAssignment: .init(channel: 1, controller: 1),
                                     yAssignment: .init(channel: 1, controller: 2)))
        a.selectedPreset = 1
        let set = XYPadSetModel(index: 0, pads: [XYPadModel(index: 0, configuration: a),
                                                 XYPadModel(index: 1, configuration: .default(index: 1))])
        XCTAssertEqual(set.pads.map(\.presets.count), [2, 2])
        XCTAssertEqual(set.pads[1].presets.map(\.name), ["MIDI 1", "B"])
        XCTAssertEqual(set.pads.map(\.selectedPreset), [1, 1])
    }
}
