//
//  MIDIMessage.swift
//  OleOleMoveController
//
//  Core MIDI に依存しない純粋なMIDIロジック。ユニットテストの対象。
//

import Foundation

// MARK: - Control Change

/// MIDI 1.0 Control Change メッセージ。
/// channel は人間向けの 1〜16、controller / value は 0〜127。
struct ControlChange: Equatable, Hashable, Sendable {
    let channel: Int
    let controller: Int
    let value: Int

    /// 範囲外の値はクランプして生成する（UIから不正値が来てもMIDIを壊さない）。
    init(channel: Int, controller: Int, value: Int) {
        self.channel = MIDIRange.clampChannel(channel)
        self.controller = MIDIRange.clamp7bit(controller)
        self.value = MIDIRange.clamp7bit(value)
    }

    /// Status = 0xB0 | (channel - 1)
    var statusByte: UInt8 { 0xB0 | UInt8(channel - 1) }
    /// Data1 = CC number
    var data1: UInt8 { UInt8(controller) }
    /// Data2 = CC value
    var data2: UInt8 { UInt8(value) }

    /// MIDI 1.0 バイト列 [status, data1, data2]
    var bytes: [UInt8] { [statusByte, data1, data2] }

    /// Universal MIDI Packet (MIDI 1.0 Channel Voice, Message Type 0x2) の32bitワード。
    /// MIDISendEventList(MIDIProtocolID._1_0) で送信する。
    func umpWord(group: UInt8 = 0) -> UInt32 {
        (UInt32(0x2) << 28)
            | (UInt32(group & 0x0F) << 24)
            | (UInt32(statusByte) << 16)
            | (UInt32(data1) << 8)
            | UInt32(data2)
    }

    var debugDescription: String {
        String(format: "CH%2d CC%3d = %3d  [%02X %02X %02X]",
               channel, controller, value, statusByte, data1, data2)
    }
}

enum MIDIRange {
    static let channels = 1...16
    static let sevenBit = 0...127

    static func clampChannel(_ v: Int) -> Int { min(max(v, 1), 16) }
    static func clamp7bit(_ v: Int) -> Int { min(max(v, 0), 127) }
}

// MARK: - Value mapping

/// 正規化値(0.0〜1.0) と MIDI値(0〜127) の相互変換。
enum CCValueMapper {
    /// 0.0→0, 1.0→127。範囲外はクランプ。reverse で 127 - v。
    static func midiValue(fromNormalized n: Double, reversed: Bool = false) -> Int {
        let clamped = n.isFinite ? min(max(n, 0), 1) : 0
        let v = Int((clamped * 127).rounded())
        return reversed ? 127 - v : v
    }

    static func normalized(fromMIDI v: Int) -> Double {
        Double(MIDIRange.clamp7bit(v)) / 127.0
    }

    /// XYパッドのタッチ座標 → 正規化座標。
    /// 左端X=0 / 右端X=1、下端Y=0 / 上端Y=1（画面座標はYが下向きなので反転する）。
    static func normalizedPoint(location: CGPoint, in size: CGSize) -> (x: Double, y: Double) {
        guard size.width > 0, size.height > 0 else { return (0, 0) }
        let x = Double(location.x / size.width)
        let y = Double((size.height - location.y) / size.height)
        return (min(max(x, 0), 1), min(max(y, 0), 1))
    }
}

// MARK: - Throttle

/// 1つのコントロール（ノブ1個 / XY軸1本）ごとの送信間引き状態。
///
/// - 同じメッセージの連続送信を抑制
/// - 最小送信間隔 (既定 1/60 秒) を超える頻度は保留し、最新値だけを後で送る
/// - `final` (タッチ終了) は間隔に関係なく即時送信し、最終値を落とさない
/// - `force` (SENDボタン) は重複でも必ず送信
///
/// 時刻は外部から与える純粋な構造体なので、テストで決定的に検証できる。
struct CCThrottle: Equatable {
    enum Action: Equatable {
        case send(ControlChange)
        case schedule(at: TimeInterval)
        case none
    }

    let minInterval: TimeInterval
    private(set) var lastSent: ControlChange?
    private(set) var lastSendTime: TimeInterval = -.infinity
    private(set) var pending: ControlChange?

    init(minInterval: TimeInterval = 1.0 / 60.0) {
        self.minInterval = minInterval
    }

    /// ドラッグ中の連続値。
    mutating func submit(_ message: ControlChange, now: TimeInterval) -> Action {
        if message == lastSent {
            // 保留中の別値より新しい値が「最後に送った値」に戻った → 保留は不要
            pending = nil
            return .none
        }
        if now - lastSendTime >= minInterval {
            pending = nil
            markSent(message, now)
            return .send(message)
        }
        let alreadyScheduled = pending != nil
        pending = message
        return alreadyScheduled ? .none : .schedule(at: lastSendTime + minInterval)
    }

    /// スケジュールされた時刻に呼ぶ。送るべき保留値があれば返す。
    mutating func flushPending(now: TimeInterval) -> ControlChange? {
        guard let p = pending else { return nil }
        pending = nil
        if p == lastSent { return nil }
        markSent(p, now)
        return p
    }

    /// タッチ終了時の最終値。間隔に関係なく即時。既に同値を送信済みなら不要。
    mutating func final(_ message: ControlChange, now: TimeInterval) -> ControlChange? {
        pending = nil
        if message == lastSent { return nil }
        markSent(message, now)
        return message
    }

    /// SEND / TEST 等の明示的送信。重複でも必ず送る。
    mutating func force(_ message: ControlChange, now: TimeInterval) -> ControlChange {
        pending = nil
        markSent(message, now)
        return message
    }

    /// 接続断・接続先変更時。次回は必ず送信されるよう記憶を消す。
    mutating func reset() {
        lastSent = nil
        pending = nil
        lastSendTime = -.infinity
    }

    private mutating func markSent(_ m: ControlChange, _ now: TimeInterval) {
        lastSent = m
        lastSendTime = now
    }
}
