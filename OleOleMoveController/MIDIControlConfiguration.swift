//
//  MIDIControlConfiguration.swift
//  OleOleMoveController
//
//  永続化される設定データ（Codable）。
//

import Foundation

/// 1つのCC送信先（チャンネルとCC番号）。
struct CCAssignment: Codable, Equatable, Hashable {
    var channel: Int     // 1...16
    var controller: Int  // 0...127

    init(channel: Int, controller: Int) {
        self.channel = MIDIRange.clampChannel(channel)
        self.controller = MIDIRange.clamp7bit(controller)
    }

    func message(value: Int) -> ControlChange {
        ControlChange(channel: channel, controller: controller, value: value)
    }

    var label: String { "CH \(channel) / CC \(controller)" }
}

/// スライダー（旧ノブ）1本分の設定。保存データとの互換のため型名は Knob のまま。
struct KnobConfiguration: Codable, Equatable {
    var name: String
    var assignment: CCAssignment
    var value: Int  // 0...127

    static func `default`(index: Int) -> KnobConfiguration {
        KnobConfiguration(name: "S\(index + 1)",
                          assignment: CCAssignment(channel: 1, controller: 20 + index),
                          value: 0)
    }

    init(name: String, assignment: CCAssignment, value: Int) {
        self.name = name
        self.assignment = assignment
        self.value = value
    }

    private enum CodingKeys: String, CodingKey { case name, assignment, value }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let saved = try c.decode(String.self, forKey: .name)
        // 以前の既定名 "KNOB n" はスライダー下に収まる短い既定名 "Sn" に移行
        if saved.hasPrefix("KNOB "), let n = Int(saved.dropFirst(5)) {
            name = "S\(n)"
        } else {
            name = saved
        }
        assignment = try c.decode(CCAssignment.self, forKey: .assignment)
        value = try c.decode(Int.self, forKey: .value)
    }
}

/// XYパッドの名前付きMIDI設定。パッドごとに複数持ち、ライブ中に切り替える。
/// マーカー位置もMIDI設定ごとに持つ（切り替えたときに、そのパラメーターの最後の位置に戻る）。
struct XYPadPreset: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var xAssignment: CCAssignment
    var yAssignment: CCAssignment
    var reverseX: Bool = false
    var reverseY: Bool = false
    var x: Double = 64.0 / 127.0
    var y: Double = 64.0 / 127.0
    /// セット横のフェーダー（右下のセットのみ表示）。セットの先頭パッドの値を使う。
    var faderAssignment: CCAssignment = XYPadPreset.defaultFaderAssignment
    var faderValue: Int = 0  // 0...127

    static let defaultFaderAssignment = CCAssignment(channel: 1, controller: 102)

    /// id は一覧表示用の識別子なので、内容の比較には含めない。
    static func == (a: XYPadPreset, b: XYPadPreset) -> Bool {
        a.name == b.name && a.xAssignment == b.xAssignment && a.yAssignment == b.yAssignment
            && a.reverseX == b.reverseX && a.reverseY == b.reverseY && a.x == b.x && a.y == b.y
            && a.faderAssignment == b.faderAssignment && a.faderValue == b.faderValue
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, xAssignment, yAssignment, reverseX, reverseY, x, y, faderAssignment, faderValue
    }
}

extension XYPadPreset {
    /// フェーダー追加前の保存データも読めるよう、欠けているキーは既定値で補う。
    /// （extension に置いてメンバーワイズ init を残す）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try c.decode(String.self, forKey: .name),
                  xAssignment: try c.decode(CCAssignment.self, forKey: .xAssignment),
                  yAssignment: try c.decode(CCAssignment.self, forKey: .yAssignment))
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        reverseX = try c.decodeIfPresent(Bool.self, forKey: .reverseX) ?? false
        reverseY = try c.decodeIfPresent(Bool.self, forKey: .reverseY) ?? false
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 64.0 / 127.0
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 64.0 / 127.0
        faderAssignment = try c.decodeIfPresent(CCAssignment.self, forKey: .faderAssignment)
            ?? XYPadPreset.defaultFaderAssignment
        faderValue = MIDIRange.clamp7bit(try c.decodeIfPresent(Int.self, forKey: .faderValue) ?? 0)
    }
}

struct XYPadConfiguration: Codable, Equatable {
    static let maxPresets = 16

    var name: String
    var isEnabled: Bool
    var presets: [XYPadPreset]
    var selectedPreset: Int

    static func `default`(index: Int) -> XYPadConfiguration {
        XYPadConfiguration(name: "XY \(index + 1)", isEnabled: true,
                           presets: [XYPadPreset(name: "MIDI 1",
                                                 xAssignment: CCAssignment(channel: 1, controller: 24 + index * 2),
                                                 yAssignment: CCAssignment(channel: 1, controller: 25 + index * 2))],
                           selectedPreset: 0)
    }

    init(name: String, isEnabled: Bool, presets: [XYPadPreset], selectedPreset: Int) {
        self.name = name
        self.isEnabled = isEnabled
        self.presets = presets.isEmpty ? XYPadConfiguration.default(index: 0).presets : presets
        self.selectedPreset = min(max(selectedPreset, 0), self.presets.count - 1)
    }

    private enum CodingKeys: String, CodingKey {
        case name, isEnabled, presets, selectedPreset
        // 旧形式（MIDI設定が1つだけ）のキー
        case xAssignment, yAssignment, x, y, reverseX, reverseY
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decodeIfPresent(String.self, forKey: .name) ?? "XY"
        let enabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        if let presets = try c.decodeIfPresent([XYPadPreset].self, forKey: .presets), !presets.isEmpty {
            self.init(name: name, isEnabled: enabled, presets: presets,
                      selectedPreset: try c.decodeIfPresent(Int.self, forKey: .selectedPreset) ?? 0)
        } else {
            // 旧形式から移行：既存のCH/CC・位置・反転を「MIDI 1」として引き継ぐ
            let legacy = XYPadPreset(
                name: "MIDI 1",
                xAssignment: try c.decodeIfPresent(CCAssignment.self, forKey: .xAssignment) ?? CCAssignment(channel: 1, controller: 24),
                yAssignment: try c.decodeIfPresent(CCAssignment.self, forKey: .yAssignment) ?? CCAssignment(channel: 1, controller: 25),
                reverseX: try c.decodeIfPresent(Bool.self, forKey: .reverseX) ?? false,
                reverseY: try c.decodeIfPresent(Bool.self, forKey: .reverseY) ?? false,
                x: try c.decodeIfPresent(Double.self, forKey: .x) ?? 64.0 / 127.0,
                y: try c.decodeIfPresent(Double.self, forKey: .y) ?? 64.0 / 127.0)
            self.init(name: name.hasPrefix("XY PAD ") ? "XY " + name.dropFirst(7) : name,
                      isEnabled: enabled, presets: [legacy], selectedPreset: 0)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(presets, forKey: .presets)
        try c.encode(selectedPreset, forKey: .selectedPreset)
    }
}

/// MIDI接続先の識別情報。Endpointの kMIDIPropertyUniqueID と表示名を保存する。
/// uniqueID は抜き差しで変わる場合があるので、名前でも再照合する。
struct MIDIDestinationIdentity: Codable, Equatable, Hashable {
    var uniqueID: Int32
    var name: String
}

struct StopwatchState: Codable, Equatable {
    /// 動作中なら計測開始時刻（壁時計）。停止中は nil。
    var runningSince: Date?
    /// 停止までに積算された秒数。
    var accumulated: TimeInterval
    var showsMilliseconds: Bool

    static let `default` = StopwatchState(runningSince: nil, accumulated: 0, showsMilliseconds: false)
}

struct AppConfiguration: Codable, Equatable {
    /// 既定は USB-C 経由（Move の USB ネットワークの固定アドレス）
    static let defaultMirrorURL = "http://172.16.254.1:7681"
    /// 以前の既定値。保存データにこれが残っていたら USB に移行する。
    static let legacyMirrorURL = "http://move.local:7681"
    static let knobCount = 4
    /// 左下に2つ、右下に2つ
    static let padCount = 4
    /// スライダー S1〜S4 の左に並ぶ KICK / HAT
    static let defaultDrumFaders = [
        KnobConfiguration(name: "KICK", assignment: CCAssignment(channel: 1, controller: 103), value: 0),
        KnobConfiguration(name: "HAT", assignment: CCAssignment(channel: 1, controller: 104), value: 0),
    ]

    var knobs: [KnobConfiguration]
    var drumFaders: [KnobConfiguration]
    var pads: [XYPadConfiguration]
    /// nil = 自動選択（Moveらしきポート優先）
    var midiDestination: MIDIDestinationIdentity?
    var mirrorURL: String
    var mirrorTint: Bool
    var mirrorWifiFallback: Bool
    var stopwatch: StopwatchState
    var midiLogEnabled: Bool

    static var `default`: AppConfiguration {
        AppConfiguration(knobs: (0..<knobCount).map { KnobConfiguration.default(index: $0) },
                         pads: (0..<padCount).map { XYPadConfiguration.default(index: $0) },
                         drumFaders: defaultDrumFaders,
                         midiDestination: nil,
                         mirrorURL: defaultMirrorURL,
                         mirrorTint: true,
                         mirrorWifiFallback: true,
                         stopwatch: .default,
                         midiLogEnabled: true)
    }

    init(knobs: [KnobConfiguration], pads: [XYPadConfiguration], drumFaders: [KnobConfiguration],
         midiDestination: MIDIDestinationIdentity?,
         mirrorURL: String, mirrorTint: Bool, mirrorWifiFallback: Bool, stopwatch: StopwatchState, midiLogEnabled: Bool) {
        self.knobs = knobs
        self.pads = pads
        self.drumFaders = drumFaders
        self.midiDestination = midiDestination
        self.mirrorURL = mirrorURL
        self.mirrorTint = mirrorTint
        self.mirrorWifiFallback = mirrorWifiFallback
        self.stopwatch = stopwatch
        self.midiLogEnabled = midiLogEnabled
    }

    // 将来キーが増減しても既存の保存データを壊さないよう、欠けているキーは既定値で補う。
    private enum CodingKeys: String, CodingKey {
        case knobs, pads, drumFaders, midiDestination, mirrorURL, mirrorTint, mirrorWifiFallback, stopwatch, midiLogEnabled
    }

    init(from decoder: Decoder) throws {
        let d = AppConfiguration.default
        let c = try decoder.container(keyedBy: CodingKeys.self)
        knobs = Self.normalized(try c.decodeIfPresent([KnobConfiguration].self, forKey: .knobs),
                                defaults: d.knobs)
        pads = Self.normalized(try c.decodeIfPresent([XYPadConfiguration].self, forKey: .pads),
                               defaults: d.pads)
        drumFaders = Self.normalized(try c.decodeIfPresent([KnobConfiguration].self, forKey: .drumFaders),
                                     defaults: d.drumFaders)
        midiDestination = try c.decodeIfPresent(MIDIDestinationIdentity.self, forKey: .midiDestination)
        let savedURL = try c.decodeIfPresent(String.self, forKey: .mirrorURL)
        mirrorURL = (savedURL == nil || savedURL == Self.legacyMirrorURL) ? d.mirrorURL : savedURL!
        mirrorTint = try c.decodeIfPresent(Bool.self, forKey: .mirrorTint) ?? d.mirrorTint
        mirrorWifiFallback = try c.decodeIfPresent(Bool.self, forKey: .mirrorWifiFallback) ?? d.mirrorWifiFallback
        stopwatch = try c.decodeIfPresent(StopwatchState.self, forKey: .stopwatch) ?? d.stopwatch
        midiLogEnabled = try c.decodeIfPresent(Bool.self, forKey: .midiLogEnabled) ?? d.midiLogEnabled
    }

    /// 配列の要素数を固定数に揃える（不足は既定値、超過は切り捨て）。
    private static func normalized<T>(_ loaded: [T]?, defaults: [T]) -> [T] {
        guard let loaded else { return defaults }
        return defaults.indices.map { $0 < loaded.count ? loaded[$0] : defaults[$0] }
    }
}
