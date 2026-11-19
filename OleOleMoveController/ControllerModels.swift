//
//  ControllerModels.swift
//  OleOleMoveController
//
//  ノブ・XYパッドの ViewModel と、アプリ全体をまとめる AppModel。
//  @Observable によりプロパティ単位で監視されるので、ノブ1つを回しても他のコントロールは再描画されない。
//

import SwiftUI
import Observation

// MARK: - Knob

@Observable
@MainActor
final class KnobModel: Identifiable {
    let index: Int
    nonisolated var id: Int { index }

    var name: String { didSet { onChange?() } }
    var assignment: CCAssignment { didSet { onChange?() } }
    /// 送信値 0...127
    private(set) var value: Int { didSet { onChange?() } }
    /// ドラッグ中の連続値（小数部を保持して細かい調整を可能にする）
    @ObservationIgnored private var continuousValue: Double
    @ObservationIgnored private var dragStartValue: Double = 0
    private(set) var isDragging = false
    private(set) var isTesting = false

    @ObservationIgnored weak var midi: MIDIManager?
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var testTask: Task<Void, Never>?

    /// ドラッグ量(pt) → 値。約300ptで全域(0→127)。
    nonisolated static let pointsForFullRange: Double = 300

    init(index: Int, configuration: KnobConfiguration) {
        self.index = index
        name = configuration.name
        assignment = configuration.assignment
        value = MIDIRange.clamp7bit(configuration.value)
        continuousValue = Double(MIDIRange.clamp7bit(configuration.value))
    }

    var configuration: KnobConfiguration {
        KnobConfiguration(name: name, assignment: assignment, value: value)
    }

    var normalized: Double { Double(value) / 127 }

    private var message: ControlChange { assignment.message(value: value) }

    // MARK: Drag (相対方式)

    /// 相対ドラッグ。delta: ドラッグ開始点からの移動量(pt、上方向が正)。
    /// fullRange: 0→127 に相当する移動量(pt)。スライダーの高さを渡すと見た目どおりに動く。
    func drag(delta: Double, fullRange: Double = KnobModel.pointsForFullRange) {
        if !isDragging {
            isDragging = true
            dragStartValue = continuousValue
        }
        let d = delta * 127.0 / max(fullRange, 1)
        continuousValue = min(max(dragStartValue + d, 0), 127)
        let newValue = Int(continuousValue.rounded())
        if newValue != value {
            value = newValue
            midi?.send(message, for: .knob(index), mode: .continuous)
        }
    }

    func endDrag() {
        isDragging = false
        midi?.send(message, for: .knob(index), mode: .final)
    }

    // MARK: Explicit send

    func sendCurrent() {
        midi?.send(message, for: .knob(index), mode: .force)
    }

    /// 値を設定して送信（0 / 64 / 127 送信ボタン）。
    func setAndSend(_ v: Int) {
        value = MIDIRange.clamp7bit(v)
        continuousValue = Double(value)
        sendCurrent()
    }

    /// TEST送信：0→127→現在値 のスイープ（約1秒）。CCを学習させる際の動作確認用。
    func runTest() {
        testTask?.cancel()
        isTesting = true
        let assignment = self.assignment
        let index = self.index
        testTask = Task { @MainActor [weak self] in
            let steps = 30
            var sequence: [Int] = (0...steps).map { $0 * 127 / steps }
            let current = self?.value ?? 0
            sequence += (0...steps).map { 127 - (127 - current) * $0 / steps }
            for v in sequence {
                if Task.isCancelled { break }
                self?.midi?.send(assignment.message(value: v), for: .knob(index), mode: .continuous)
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            if let self {
                self.midi?.send(self.message, for: .knob(index), mode: .final)
                self.isTesting = false
            }
        }
    }

    func apply(_ configuration: KnobConfiguration) {
        name = configuration.name
        assignment = configuration.assignment
        value = MIDIRange.clamp7bit(configuration.value)
        continuousValue = Double(value)
    }
}

// MARK: - XY Pad

@Observable
@MainActor
final class XYPadModel: Identifiable {
    let index: Int
    nonisolated var id: Int { index }

    var name: String { didSet { onChange?() } }
    var isEnabled: Bool { didSet { onChange?() } }
    /// 名前付きMIDI設定の一覧。選択中のものでCCを送る。
    private(set) var presets: [XYPadPreset] { didSet { onChange?() } }
    private(set) var selectedPreset: Int { didSet { onChange?() } }
    private(set) var isTouching = false

    @ObservationIgnored weak var midi: MIDIManager?
    @ObservationIgnored var onChange: (() -> Void)?

    init(index: Int, configuration: XYPadConfiguration) {
        self.index = index
        name = configuration.name
        isEnabled = configuration.isEnabled
        presets = configuration.presets
        selectedPreset = configuration.selectedPreset
    }

    var configuration: XYPadConfiguration {
        XYPadConfiguration(name: name, isEnabled: isEnabled, presets: presets, selectedPreset: selectedPreset)
    }

    // MARK: Current preset（設定画面のバインディング用に get/set を提供）

    var current: XYPadPreset {
        get { presets[selectedPreset] }
        set { presets[selectedPreset] = newValue }
    }

    var presetName: String {
        get { current.name }
        set { current.name = newValue }
    }
    var xAssignment: CCAssignment {
        get { current.xAssignment }
        set { current.xAssignment = newValue }
    }
    var yAssignment: CCAssignment {
        get { current.yAssignment }
        set { current.yAssignment = newValue }
    }
    var reverseX: Bool {
        get { current.reverseX }
        set { current.reverseX = newValue }
    }
    var reverseY: Bool {
        get { current.reverseY }
        set { current.reverseY = newValue }
    }
    /// マーカー位置（正規化、Yは下端0）。指を離しても保持。MIDI設定ごとに記憶。
    var x: Double { current.x }
    var y: Double { current.y }

    /// 送信されるCC値（反転設定を反映）
    var xValue: Int { CCValueMapper.midiValue(fromNormalized: x, reversed: reverseX) }
    var yValue: Int { CCValueMapper.midiValue(fromNormalized: y, reversed: reverseY) }

    var xMessage: ControlChange { xAssignment.message(value: xValue) }
    var yMessage: ControlChange { yAssignment.message(value: yValue) }

    // MARK: Preset switching / management

    /// MIDI設定を切り替える。切り替えただけでは送信しない（受信側のパラメーターが急に飛ばないように）。
    func selectPreset(_ i: Int) {
        guard presets.indices.contains(i), i != selectedPreset else { return }
        selectedPreset = i
    }

    func selectNextPreset() { selectPreset((selectedPreset + 1) % presets.count) }
    func selectPreviousPreset() { selectPreset((selectedPreset - 1 + presets.count) % presets.count) }

    /// 現在のMIDI設定を複製して追加（CC番号は+2して重複しにくくする）。
    func addPreset() {
        guard presets.count < XYPadConfiguration.maxPresets else { return }
        var p = current
        p.id = UUID()
        p.name = "MIDI \(presets.count + 1)"
        p.xAssignment.controller = min(127, p.xAssignment.controller + 2)
        p.yAssignment.controller = min(127, p.yAssignment.controller + 2)
        p.faderAssignment.controller = min(127, p.faderAssignment.controller + 1)
        presets.append(p)
        selectedPreset = presets.count - 1
    }

    /// セットの整合用：現在の最後の設定を複製して末尾に足す（選択は変えない）。
    func appendPresetCopy() {
        guard var p = presets.last else { return }
        p.id = UUID()
        presets.append(p)
    }

    /// セットの整合用：先頭パッドと同じ名前にそろえる。
    func renamePresets(_ names: [String]) {
        for i in presets.indices where i < names.count && presets[i].name != names[i] {
            presets[i].name = names[i]
        }
    }

    func deletePreset(at i: Int) {
        guard presets.count > 1, presets.indices.contains(i) else { return }
        presets.remove(at: i)
        selectedPreset = min(selectedPreset, presets.count - 1)
    }

    func movePreset(from i: Int, by offset: Int) {
        let j = i + offset
        guard presets.indices.contains(i), presets.indices.contains(j) else { return }
        presets.swapAt(i, j)
        if selectedPreset == i { selectedPreset = j } else if selectedPreset == j { selectedPreset = i }
    }

    // MARK: Touch

    /// タッチ開始・ドラッグ中。開始位置で即座に値を更新して送信する。
    func touch(at location: CGPoint, in size: CGSize) {
        isTouching = true
        move(to: CCValueMapper.normalizedPoint(location: location, in: size), mode: .continuous)
    }

    /// タッチ終了。最終値を必ず送信する。
    func endTouch(at location: CGPoint, in size: CGSize) {
        move(to: CCValueMapper.normalizedPoint(location: location, in: size), mode: .final)
        isTouching = false
    }

    private func move(to p: (x: Double, y: Double), mode: SendMode) {
        if p.x != current.x || p.y != current.y {
            presets[selectedPreset].x = p.x
            presets[selectedPreset].y = p.y
        }
        guard isEnabled else { return }  // OFF のときは送信しない
        midi?.send(xMessage, for: .padX(index), mode: mode)
        midi?.send(yMessage, for: .padY(index), mode: mode)
    }

    // MARK: Explicit send（CCラーニング用：パッドON/OFFに関係なく送る）

    func sendX() { midi?.send(xMessage, for: .padX(index), mode: .force) }
    func sendY() { midi?.send(yMessage, for: .padY(index), mode: .force) }
    func sendBoth() { sendX(); sendY() }

    /// X=64, Y=64 に移動。有効時のみ送信。
    func center() {
        let c = 64.0 / 127.0
        presets[selectedPreset].x = c
        presets[selectedPreset].y = c
        if isEnabled { sendBoth() }
    }

    func apply(_ c: XYPadConfiguration) {
        name = c.name
        isEnabled = c.isEnabled
        presets = c.presets
        selectedPreset = c.selectedPreset
    }
}

// MARK: - XY Pad Set

/// XYパッド2つで1セット。MIDI設定（名前付き）はセット単位で切り替える。
/// 1つのMIDI設定 = 2パッド分（各パッドの X/Y の CH・CC・反転・位置）。
/// 保存形式はパッドごとのまま（各パッドの presets の i 番目同士が1つのMIDI設定）で、
/// このモデルが2つのパッドの設定数・選択・名前を常に揃える。
@Observable
@MainActor
final class XYPadSetModel: Identifiable {
    let index: Int
    nonisolated var id: Int { index }
    let pads: [XYPadModel]
    /// パッドの左にフェーダーを持つか（右下のセットのみ）。
    let hasFader: Bool
    private(set) var isFaderDragging = false
    @ObservationIgnored private var faderDragStart: Double = 0

    init(index: Int, pads: [XYPadModel], hasFader: Bool = false) {
        self.index = index
        self.pads = pads
        self.hasFader = hasFader
        normalize()
    }

    var name: String { "SET \(index + 1)" }
    private var lead: XYPadModel { pads[0] }

    var presetCount: Int { lead.presets.count }
    var selectedPreset: Int { lead.selectedPreset }
    var presetNames: [String] { lead.presets.map(\.name) }

    var presetName: String {
        get { lead.presetName }
        set { pads.forEach { $0.presetName = newValue } }
    }

    func selectPreset(_ i: Int) { pads.forEach { $0.selectPreset(i) } }
    func selectNextPreset() { selectPreset((selectedPreset + 1) % presetCount) }
    func selectPreviousPreset() { selectPreset((selectedPreset - 1 + presetCount) % presetCount) }

    func addPreset() {
        guard presetCount < XYPadConfiguration.maxPresets else { return }
        pads.forEach { $0.addPreset() }
        normalize()
    }

    func deletePreset(at i: Int) {
        guard presetCount > 1 else { return }
        pads.forEach { $0.deletePreset(at: i) }
    }

    func movePreset(from i: Int, by offset: Int) {
        pads.forEach { $0.movePreset(from: i, by: offset) }
    }

    // MARK: Fader（MIDI設定ごとの CH/CC・値。保存先は先頭パッドの presets）

    var faderAssignment: CCAssignment {
        get { lead.current.faderAssignment }
        set { lead.current.faderAssignment = newValue }
    }
    var faderValue: Int { lead.current.faderValue }
    var faderNormalized: Double { Double(faderValue) / 127 }
    private var faderMessage: ControlChange { faderAssignment.message(value: faderValue) }

    /// 相対ドラッグ（スライダー S1〜S4 と同じ方式）。delta: 開始点からの移動量(pt、上方向が正)。
    func dragFader(delta: Double, fullRange: Double) {
        if !isFaderDragging {
            isFaderDragging = true
            faderDragStart = Double(faderValue)
        }
        let v = min(max(faderDragStart + delta * 127.0 / max(fullRange, 1), 0), 127)
        let newValue = Int(v.rounded())
        if newValue != faderValue {
            lead.current.faderValue = newValue
            lead.midi?.send(faderMessage, for: .fader(index), mode: .continuous)
        }
    }

    func endFaderDrag() {
        isFaderDragging = false
        lead.midi?.send(faderMessage, for: .fader(index), mode: .final)
    }

    func sendFader() {
        lead.midi?.send(faderMessage, for: .fader(index), mode: .force)
    }

    /// 2つのパッドのMIDI設定の数・名前・選択を揃える（旧データや手動編集で食い違っても破綻しない）。
    private func normalize() {
        let count = pads.map(\.presets.count).max() ?? 1
        for p in pads { while p.presets.count < count { p.appendPresetCopy() } }
        let names = lead.presets.map(\.name)
        for p in pads.dropFirst() { p.renamePresets(names) }
        let sel = lead.selectedPreset
        for p in pads.dropFirst() { p.selectPreset(sel) }
    }
}

// MARK: - App

@Observable
@MainActor
final class AppModel {
    let knobs: [KnobModel]
    /// KICK / HAT フェーダー。送信の間引きキーがスライダーと重ならないよう index は S1〜S4 の後に続ける
    let drumFaders: [KnobModel]
    let pads: [XYPadModel]
    /// XY 1・2 = SET 1（左下）、XY 3・4 = SET 2（右下）
    let padSets: [XYPadSetModel]
    let midi: MIDIManager
    let stopwatch: StopwatchModel
    let mirror: MirrorController
    let diagnostics = MirrorDiagnostics()

    var midiLogEnabled: Bool {
        didSet { midi.setLogEnabled(midiLogEnabled); scheduleSave() }
    }

    @ObservationIgnored private let store: ConfigurationStore

    init(store: ConfigurationStore = ConfigurationStore()) {
        self.store = store
        let config = store.load()
        midi = MIDIManager(preferred: config.midiDestination)
        knobs = config.knobs.enumerated().map { KnobModel(index: $0.offset, configuration: $0.element) }
        drumFaders = config.drumFaders.enumerated().map {
            KnobModel(index: AppConfiguration.knobCount + $0.offset, configuration: $0.element)
        }
        let padModels = config.pads.enumerated().map { XYPadModel(index: $0.offset, configuration: $0.element) }
        pads = padModels
        padSets = stride(from: 0, to: padModels.count - 1, by: 2).map {
            // 右下のセット（SET 2）だけパッドの左にフェーダーを置く
            XYPadSetModel(index: $0 / 2, pads: [padModels[$0], padModels[$0 + 1]], hasFader: $0 / 2 == 1)
        }
        stopwatch = StopwatchModel(state: config.stopwatch)
        mirror = MirrorController(urlString: config.mirrorURL, tint: config.mirrorTint,
                                  wifiFallback: config.mirrorWifiFallback)
        midiLogEnabled = config.midiLogEnabled
        midi.setLogEnabled(config.midiLogEnabled)

        let save: () -> Void = { [weak self] in self?.scheduleSave() }
        for k in knobs + drumFaders { k.midi = midi; k.onChange = save }
        for p in pads { p.midi = midi; p.onChange = save }
        stopwatch.onChange = { [weak self] in self?.saveNow() } // 開始/停止は即保存
        mirror.onChange = save
        midi.onPreferenceChanged = save

        midi.diagnosticsExtra = { [weak self] in
            guard let self else { return "" }
            let ifs = self.diagnostics.interfaces.map { "\($0.name)(\($0.type))" }.joined(separator: ", ")
            return """
            -- mirror --
            configured: \(self.mirror.urlString)  fallback: \(self.mirror.wifiFallback)
            active: \(self.mirror.activeURLString)  route: \(self.mirror.routeLabel)
            status: \(self.mirror.status)
            interfaces: \(ifs)
            """
        }

        // 診断ファイルを定期的に更新（送信処理とは独立、低頻度）
        diagnosticsTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.midi.writeDiagnostics() }
        }
    }

    @ObservationIgnored private var diagnosticsTimer: Timer?

    var configuration: AppConfiguration {
        AppConfiguration(knobs: knobs.map(\.configuration),
                         pads: pads.map(\.configuration),
                         drumFaders: drumFaders.map(\.configuration),
                         midiDestination: midi.preferred,
                         mirrorURL: mirror.urlString,
                         mirrorTint: mirror.tint,
                         mirrorWifiFallback: mirror.wifiFallback,
                         stopwatch: stopwatch.state,
                         midiLogEnabled: midiLogEnabled)
    }

    func scheduleSave() {
        store.scheduleSave { [weak self] in self?.configuration ?? .default }
    }

    func saveNow() { store.saveNow(configuration) }

    /// 全コントロールの現在値を送信（再接続後の同期・学習用）。
    func sendAll() {
        knobs.forEach { $0.sendCurrent() }
        drumFaders.forEach { $0.sendCurrent() }
        pads.forEach { $0.sendBoth() }
        padSets.filter(\.hasFader).forEach { $0.sendFader() }
    }

    /// CH/CC/名前/値を初期値に戻す（MIDI接続先・Mirror URLは保持）。
    func resetControlsToDefaults() {
        let d = AppConfiguration.default
        for (k, c) in zip(knobs, d.knobs) { k.apply(c) }
        for (k, c) in zip(drumFaders, d.drumFaders) { k.apply(c) }
        for (p, c) in zip(pads, d.pads) { p.apply(c) }
        saveNow()
    }
}
