//
//  MIDIMessageTests.swift
//  OleOleMoveControllerTests
//

import XCTest
import CoreMIDI
@testable import OleOleMoveController

final class MIDIMessageTests: XCTestCase {

    // MARK: Status / data bytes

    func testStatusByteForChannel1() {
        let m = ControlChange(channel: 1, controller: 20, value: 64)
        XCTAssertEqual(m.statusByte, 0xB0)
        XCTAssertEqual(m.data1, 20)
        XCTAssertEqual(m.data2, 64)
        XCTAssertEqual(m.bytes, [0xB0, 0x14, 0x40])
    }

    func testStatusByteForEveryChannel() {
        for ch in 1...16 {
            let m = ControlChange(channel: ch, controller: 0, value: 0)
            XCTAssertEqual(m.statusByte, 0xB0 | UInt8(ch - 1), "channel \(ch)")
        }
        XCTAssertEqual(ControlChange(channel: 16, controller: 127, value: 127).bytes, [0xBF, 0x7F, 0x7F])
    }

    func testDataBytesAreSevenBit() {
        for v in [0, 1, 63, 64, 126, 127] {
            let m = ControlChange(channel: 3, controller: v, value: v)
            XCTAssertEqual(m.data1 & 0x80, 0)
            XCTAssertEqual(m.data2 & 0x80, 0)
            XCTAssertEqual(Int(m.data1), v)
            XCTAssertEqual(Int(m.data2), v)
        }
    }

    func testOutOfRangeValuesAreClamped() {
        let m = ControlChange(channel: 0, controller: 200, value: -5)
        XCTAssertEqual(m.channel, 1)
        XCTAssertEqual(m.controller, 127)
        XCTAssertEqual(m.value, 0)
        XCTAssertEqual(m.bytes, [0xB0, 0x7F, 0x00])

        let m2 = ControlChange(channel: 17, controller: -1, value: 128)
        XCTAssertEqual(m2.bytes, [0xBF, 0x00, 0x7F])
    }

    func testUMPWordMIDI1ChannelVoice() {
        let m = ControlChange(channel: 2, controller: 21, value: 100)
        // MT=2, group=0, status=B1, data1=0x15, data2=0x64
        XCTAssertEqual(m.umpWord(), 0x20B1_1564)
        XCTAssertEqual(m.umpWord(group: 3), 0x23B1_1564)
    }

    func testEventListContainsExpectedWord() {
        let m = ControlChange(channel: 1, controller: 24, value: 127)
        var list = MIDIEventList()
        var word = m.umpWord()
        let packet = MIDIEventListInit(&list, ._1_0)
        _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &word)
        XCTAssertEqual(list.numPackets, 1)
        XCTAssertEqual(list.packet.wordCount, 1)
        XCTAssertEqual(list.packet.words.0, 0x20B0_187F)
    }

    // MARK: Value mapping

    func testNormalizedToMIDI() {
        XCTAssertEqual(CCValueMapper.midiValue(fromNormalized: 0), 0)
        XCTAssertEqual(CCValueMapper.midiValue(fromNormalized: 1), 127)
        XCTAssertEqual(CCValueMapper.midiValue(fromNormalized: 0.5), 64)
        XCTAssertEqual(CCValueMapper.midiValue(fromNormalized: 64.0 / 127.0), 64)
        XCTAssertEqual(CCValueMapper.midiValue(fromNormalized: -0.3), 0)
        XCTAssertEqual(CCValueMapper.midiValue(fromNormalized: 1.7), 127)
        XCTAssertEqual(CCValueMapper.midiValue(fromNormalized: .nan), 0)
    }

    func testReverse() {
        XCTAssertEqual(CCValueMapper.midiValue(fromNormalized: 0, reversed: true), 127)
        XCTAssertEqual(CCValueMapper.midiValue(fromNormalized: 1, reversed: true), 0)
        XCTAssertEqual(CCValueMapper.midiValue(fromNormalized: 0.25, reversed: true),
                       127 - CCValueMapper.midiValue(fromNormalized: 0.25))
    }

    func testPadCoordinates() {
        let size = CGSize(width: 400, height: 400)
        // 左下 = (0,0)、右上 = (127,127)
        let bl = CCValueMapper.normalizedPoint(location: CGPoint(x: 0, y: 400), in: size)
        XCTAssertEqual(CCValueMapper.midiValue(fromNormalized: bl.x), 0)
        XCTAssertEqual(CCValueMapper.midiValue(fromNormalized: bl.y), 0)
        let tr = CCValueMapper.normalizedPoint(location: CGPoint(x: 400, y: 0), in: size)
        XCTAssertEqual(CCValueMapper.midiValue(fromNormalized: tr.x), 127)
        XCTAssertEqual(CCValueMapper.midiValue(fromNormalized: tr.y), 127)
        // 範囲外へのドラッグはクランプ
        let out = CCValueMapper.normalizedPoint(location: CGPoint(x: -50, y: 900), in: size)
        XCTAssertEqual(out.x, 0)
        XCTAssertEqual(out.y, 0)
        let mid = CCValueMapper.normalizedPoint(location: CGPoint(x: 200, y: 200), in: size)
        XCTAssertEqual(CCValueMapper.midiValue(fromNormalized: mid.x), 64)
        XCTAssertEqual(CCValueMapper.midiValue(fromNormalized: mid.y), 64)
        // ゼロサイズでもクラッシュしない
        let zero = CCValueMapper.normalizedPoint(location: .zero, in: .zero)
        XCTAssertEqual(zero.x, 0)
    }
}

final class CCThrottleTests: XCTestCase {
    let a = ControlChange(channel: 1, controller: 20, value: 10)
    let b = ControlChange(channel: 1, controller: 20, value: 11)
    let c = ControlChange(channel: 1, controller: 20, value: 12)

    func testFirstMessageIsSentImmediately() {
        var t = CCThrottle(minInterval: 1.0 / 60)
        XCTAssertEqual(t.submit(a, now: 100), .send(a))
    }

    func testDuplicateIsSuppressed() {
        var t = CCThrottle(minInterval: 1.0 / 60)
        _ = t.submit(a, now: 100)
        XCTAssertEqual(t.submit(a, now: 101), .none)
    }

    func testRateLimitDefersAndKeepsLatest() {
        var t = CCThrottle(minInterval: 0.02)
        XCTAssertEqual(t.submit(a, now: 1.000), .send(a))
        XCTAssertEqual(t.submit(b, now: 1.005), .schedule(at: 1.020))
        XCTAssertEqual(t.submit(c, now: 1.010), .none)       // 既にスケジュール済み
        XCTAssertEqual(t.flushPending(now: 1.020), c)          // 最新値だけ送る
        XCTAssertNil(t.flushPending(now: 1.021))
    }

    func testSendsAgainAfterInterval() {
        var t = CCThrottle(minInterval: 0.02)
        _ = t.submit(a, now: 1.0)
        XCTAssertEqual(t.submit(b, now: 1.03), .send(b))
    }

    func testReturnToLastSentValueCancelsPending() {
        var t = CCThrottle(minInterval: 0.02)
        _ = t.submit(a, now: 1.0)
        _ = t.submit(b, now: 1.005)
        XCTAssertEqual(t.submit(a, now: 1.01), .none)
        XCTAssertNil(t.flushPending(now: 1.02))
    }

    func testFinalIsNeverDroppedEvenInsideInterval() {
        var t = CCThrottle(minInterval: 0.02)
        _ = t.submit(a, now: 1.000)
        _ = t.submit(b, now: 1.001)  // 保留
        XCTAssertEqual(t.final(c, now: 1.002), c)  // 間隔内でも即時
        XCTAssertNil(t.flushPending(now: 1.02))      // 保留は破棄済み
    }

    func testFinalSameAsLastSentIsNotDuplicated() {
        var t = CCThrottle(minInterval: 0.02)
        _ = t.submit(a, now: 1.0)
        XCTAssertNil(t.final(a, now: 1.5))
    }

    func testForceAlwaysSends() {
        var t = CCThrottle(minInterval: 0.02)
        _ = t.submit(a, now: 1.0)
        XCTAssertEqual(t.force(a, now: 1.001), a)
        XCTAssertEqual(t.force(a, now: 1.002), a)
    }

    func testChannelOrCCChangeIsNotTreatedAsDuplicate() {
        var t = CCThrottle(minInterval: 0)
        _ = t.submit(a, now: 1.0)
        let other = ControlChange(channel: 2, controller: 20, value: 10)
        XCTAssertEqual(t.submit(other, now: 2.0), .send(other))
    }

    func testResetAllowsResend() {
        var t = CCThrottle(minInterval: 0.02)
        _ = t.submit(a, now: 1.0)
        t.reset()
        XCTAssertEqual(t.submit(a, now: 1.001), .send(a))
    }
}

final class MIDISendEngineTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        var sent: [(ControlChange, MIDIEndpointRef)] = []
        func append(_ m: ControlChange, _ e: MIDIEndpointRef) { lock.withLock { sent.append((m, e)) } }
        var messages: [ControlChange] { lock.withLock { sent.map(\.0) } }
    }

    func testBurstThenFinalDeliversFinalValue() {
        let rec = Recorder()
        let engine = MIDISendEngine(log: MIDILog(), minInterval: 1.0 / 60) { m, e in rec.append(m, e); return noErr }
        engine.setEndpoint(42, name: "Fake")
        for v in 0...100 {
            engine.submit(ControlChange(channel: 1, controller: 24, value: v), for: .padX(0), mode: .continuous)
        }
        engine.submit(ControlChange(channel: 1, controller: 24, value: 101), for: .padX(0), mode: .final)
        engine.waitUntilIdle()
        let msgs = rec.messages
        XCTAssertEqual(msgs.first?.value, 0)
        XCTAssertEqual(msgs.last?.value, 101, "最終値は必ず送信される")
        XCTAssertLessThan(msgs.count, 20, "高速な連続値は間引かれる")
        XCTAssertTrue(rec.sent.allSatisfy { $0.1 == 42 })
    }

    func testPendingValueIsFlushedAfterInterval() {
        let rec = Recorder()
        let engine = MIDISendEngine(log: MIDILog(), minInterval: 0.05) { m, e in rec.append(m, e); return noErr }
        engine.setEndpoint(1, name: "Fake")
        engine.submit(ControlChange(channel: 1, controller: 20, value: 1), for: .knob(0), mode: .continuous)
        engine.submit(ControlChange(channel: 1, controller: 20, value: 2), for: .knob(0), mode: .continuous)
        engine.submit(ControlChange(channel: 1, controller: 20, value: 3), for: .knob(0), mode: .continuous)
        let exp = expectation(description: "flush")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        wait(for: [exp], timeout: 1)
        engine.waitUntilIdle()
        XCTAssertEqual(rec.messages.map(\.value), [1, 3])
    }

    func testControlsAreThrottledIndependently() {
        let rec = Recorder()
        let engine = MIDISendEngine(log: MIDILog(), minInterval: 10) { m, e in rec.append(m, e); return noErr }
        engine.setEndpoint(1, name: "Fake")
        engine.submit(ControlChange(channel: 1, controller: 24, value: 5), for: .padX(0), mode: .continuous)
        engine.submit(ControlChange(channel: 1, controller: 25, value: 6), for: .padY(0), mode: .continuous)
        engine.submit(ControlChange(channel: 1, controller: 26, value: 7), for: .padX(1), mode: .continuous)
        engine.waitUntilIdle()
        XCTAssertEqual(rec.messages.map(\.controller), [24, 25, 26])
    }

    func testNoDestinationDropsSafelyAndResumesAfterReconnect() {
        let rec = Recorder()
        let log = MIDILog()
        let engine = MIDISendEngine(log: log, minInterval: 0) { m, e in rec.append(m, e); return noErr }
        let m = ControlChange(channel: 1, controller: 20, value: 64)
        engine.setEndpoint(0, name: "")
        engine.submit(m, for: .knob(0), mode: .final)
        engine.waitUntilIdle()
        XCTAssertTrue(rec.messages.isEmpty)
        XCTAssertEqual(log.counters.dropped, 1)

        engine.setEndpoint(7, name: "Move")
        engine.submit(m, for: .knob(0), mode: .final)   // 同じ値でも再接続後は送られる
        engine.waitUntilIdle()
        XCTAssertEqual(rec.messages, [m])
    }

    func testSendErrorIsLoggedAndRetried() {
        let rec = Recorder()
        let log = MIDILog()
        var fail = true
        let engine = MIDISendEngine(log: log, minInterval: 0) { m, e in
            if fail { return OSStatus(kMIDIObjectNotFound) }
            rec.append(m, e); return noErr
        }
        engine.setEndpoint(3, name: "X")
        let m = ControlChange(channel: 1, controller: 20, value: 9)
        engine.submit(m, for: .knob(0), mode: .final)
        engine.waitUntilIdle()
        XCTAssertEqual(log.counters.dropped, 1)
        engine.queue.sync { fail = false }
        engine.submit(m, for: .knob(0), mode: .final)
        engine.waitUntilIdle()
        XCTAssertEqual(rec.messages, [m])
    }

    func testForceSendsDuplicates() {
        let rec = Recorder()
        let engine = MIDISendEngine(log: MIDILog(), minInterval: 0) { m, e in rec.append(m, e); return noErr }
        engine.setEndpoint(1, name: "Fake")
        let m = ControlChange(channel: 5, controller: 30, value: 30)
        engine.submit(m, for: .knob(1), mode: .force)
        engine.submit(m, for: .knob(1), mode: .force)
        engine.waitUntilIdle()
        XCTAssertEqual(rec.messages.count, 2)
        XCTAssertEqual(rec.messages.first?.bytes, [0xB4, 30, 30])
    }
}

final class MIDIDestinationResolverTests: XCTestCase {
    private func info(_ id: Int32, _ name: String, _ transport: MIDITransport,
                      manufacturer: String = "", offline: Bool = false) -> MIDIDestinationInfo {
        MIDIDestinationInfo(endpoint: MIDIEndpointRef(id), uniqueID: id, name: name, manufacturer: manufacturer,
                            model: "", driverOwner: "", transport: transport, isOffline: offline)
    }

    func testAutoPrefersMoveOverOtherUSB() {
        let list = [info(1, "Network Session 1", .network),
                    info(2, "USB Synth", .usb),
                    info(3, "Move", .usb, manufacturer: "Ableton")]
        XCTAssertEqual(MIDIDestinationResolver.resolve(preferred: nil, candidates: list)?.uniqueID, 3)
    }

    func testAutoPrefersMoveStandalonePort() {
        let list = [info(1, "Ableton Move Live Port", .usb, manufacturer: "Ableton"),
                    info(2, "Ableton Move User Port", .usb, manufacturer: "Ableton"),
                    info(3, "Ableton Move Standalone Port", .usb, manufacturer: "Ableton"),
                    info(4, "Ableton Move External Port", .usb, manufacturer: "Ableton")]
        XCTAssertEqual(MIDIDestinationResolver.resolve(preferred: nil, candidates: list)?.uniqueID, 3)
    }

    func testAutoFallsBackToUSB() {
        let list = [info(1, "Network Session 1", .network), info(2, "USB Synth", .usb)]
        XCTAssertEqual(MIDIDestinationResolver.resolve(preferred: nil, candidates: list)?.uniqueID, 2)
    }

    func testAutoDoesNotPickNetworkOnly() {
        let list = [info(1, "Network Session 1", .network)]
        XCTAssertNil(MIDIDestinationResolver.resolve(preferred: nil, candidates: list))
    }

    func testManualSelectionByUniqueIDThenName() {
        let list = [info(10, "Move", .usb), info(11, "Other", .usb)]
        XCTAssertEqual(MIDIDestinationResolver.resolve(
            preferred: MIDIDestinationIdentity(uniqueID: 11, name: "Other"), candidates: list)?.uniqueID, 11)
        // 抜き差しで uniqueID が変わっても名前で再接続
        XCTAssertEqual(MIDIDestinationResolver.resolve(
            preferred: MIDIDestinationIdentity(uniqueID: 999, name: "Move"), candidates: list)?.uniqueID, 10)
    }

    func testManualSelectionMissingDoesNotSwitchDevice() {
        let list = [info(10, "Move", .usb)]
        XCTAssertNil(MIDIDestinationResolver.resolve(
            preferred: MIDIDestinationIdentity(uniqueID: 5, name: "Gone"), candidates: list))
    }

    func testOfflineIsSkipped() {
        let list = [info(10, "Move", .usb, offline: true)]
        XCTAssertNil(MIDIDestinationResolver.resolve(preferred: nil, candidates: list))
    }
}
