//
//  SettingsView.swift
//  OleOleMoveController
//
//  ノブ/XYパッドの設定（ポップオーバー）と、全体設定（シート）。
//

import SwiftUI

// MARK: - Reusable editors

/// 大きめの −/+ ボタンと直接入力欄を持つ数値エディタ。
struct NumberEditor: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(Theme.futura(14, weight: .bold))
                .foregroundStyle(Theme.label)
            Spacer(minLength: 8)
            Button { set(value - 1) } label: { Image(systemName: "minus") }
                .buttonStyle(.neon(size: 16, minHeight: 40))
                .frame(width: 48)
                .disabled(value <= range.lowerBound)
            TextField("", text: $text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(Theme.futura(20, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Theme.label)
                .frame(width: 64, height: 40)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.5)))
                .focused($focused)
                .onSubmit { commit() }
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            Button { set(value + 1) } label: { Image(systemName: "plus") }
                .buttonStyle(.neon(size: 16, minHeight: 40))
                .frame(width: 48)
                .disabled(value >= range.upperBound)
        }
        .onAppear { text = "\(value)" }
        .onChange(of: value) { _, v in if !focused { text = "\(v)" } }
    }

    private func set(_ v: Int) {
        value = min(max(v, range.lowerBound), range.upperBound)
        text = "\(value)"
    }

    private func commit() {
        if let v = Int(text.trimmingCharacters(in: .whitespaces)) { set(v) } else { text = "\(value)" }
    }
}

struct SettingsSectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(Theme.futura(12, weight: .bold))
            .foregroundStyle(Theme.neonBright)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
    }
}

/// 設定シート共通の見た目。背景を全面に敷き、キーボード表示時もスクロールで全項目に届くようにする。
private struct SettingsChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.panel.ignoresSafeArea())
            .environment(\.colorScheme, .dark)
            .tint(Theme.neonBright)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
    }
}

extension View {
    fileprivate func settingsChrome() -> some View { modifier(SettingsChrome()) }
}

/// シート上部の見出しと閉じるボタン。
private struct SheetHeader: View {
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack {
            PanelTitle(text: title, size: 20)
            Spacer()
            Button("DONE") { dismiss() }
                .buttonStyle(.neon(size: 15))
                .frame(width: 100)
        }
        .padding(.bottom, 8)
    }
}

private struct NameField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .font(Theme.futura(18))
            .autocorrectionDisabled()
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.5)))
    }
}

// MARK: - Slider settings

struct KnobSettingsView: View {
    @Bindable var model: KnobModel

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "\(model.name) SETUP")
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsSectionHeader(title: "NAME")
                    NameField(placeholder: "Name", text: $model.name)

                    SettingsSectionHeader(title: "MIDI")
                    NumberEditor(title: "MIDI CH", value: $model.assignment.channel, range: MIDIRange.channels)
                    NumberEditor(title: "CC", value: $model.assignment.controller, range: MIDIRange.sevenBit)

                    SettingsSectionHeader(title: "SEND (CC LEARN)  ·  VALUE \(model.value)")
                    HStack(spacing: 8) {
                        Button("SEND") { model.sendCurrent() }.buttonStyle(.neon)
                        Button("TEST") { model.runTest() }.buttonStyle(.neon(active: model.isTesting))
                    }
                    HStack(spacing: 8) {
                        Button("0") { model.setAndSend(0) }.buttonStyle(.neon)
                        Button("64") { model.setAndSend(64) }.buttonStyle(.neon)
                        Button("127") { model.setAndSend(127) }.buttonStyle(.neon)
                    }
                    Text("TEST: 0→127→現在値 をスイープ送信します。0/64/127 は値を設定して送信します。")
                        .font(.caption)
                        .foregroundStyle(Theme.label.opacity(0.7))
                }
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .settingsChrome()
    }
}

// MARK: - XY pad set settings

/// XYパッドセット（2パッド）のMIDI設定。左に設定の一覧、右に選択中の設定の2パッド分の内容。
struct XYPadSetSettingsView: View {
    @Bindable var set: XYPadSetModel
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "XY \(set.name) SETUP")
            ScrollView {
                // シート幅（iPad の formSheet）に収まるよう、一覧の下に2パッド分を並べる
                VStack(alignment: .leading, spacing: 16) {
                    presetList
                    VStack(alignment: .leading, spacing: 12) {
                        SettingsSectionHeader(title: "MIDI SETTING NAME")
                        NameField(placeholder: "Name", text: $set.presetName)
                        if set.hasFader { faderEditor }
                        HStack(alignment: .top, spacing: 20) {
                            ForEach(set.pads) { pad in
                                PadAxisEditor(model: pad)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .settingsChrome()
        .confirmationDialog("「\(set.presetName)」を削除しますか？", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("DELETE", role: .destructive) { set.deletePreset(at: set.selectedPreset) }
        }
    }

    /// MIDI設定の一覧。タップで選択（メイン画面の ◁ ▷ と同じ）。
    private var presetList: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(title: "MIDI SETTINGS (\(set.presetCount)/\(XYPadConfiguration.maxPresets))")
            ForEach(Array(set.presetNames.enumerated()), id: \.offset) { i, name in
                Button { set.selectPreset(i) } label: {
                    HStack {
                        Image(systemName: i == set.selectedPreset ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(Theme.neonBright)
                        Text(name).font(Theme.futura(15, weight: .bold)).foregroundStyle(Theme.label)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill(i == set.selectedPreset ? Theme.darkBack : Color.black.opacity(0.3)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 8) {
                Button("ADD") { set.addPreset() }
                    .buttonStyle(.neon(size: 13))
                    .disabled(set.presetCount >= XYPadConfiguration.maxPresets)
                Button("DELETE") { confirmDelete = true }
                    .buttonStyle(.neon(size: 13))
                    .disabled(set.presetCount <= 1)
            }
            HStack(spacing: 8) {
                Button { set.movePreset(from: set.selectedPreset, by: -1) } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(.neon(size: 13))
                    .disabled(set.selectedPreset == 0)
                Button { set.movePreset(from: set.selectedPreset, by: 1) } label: { Image(systemName: "arrow.down") }
                    .buttonStyle(.neon(size: 13))
                    .disabled(set.selectedPreset == set.presetCount - 1)
            }
            Text(set.hasFader ? "ADD は選択中の設定を複製して追加します（XYの各CCは+2、FADERのCCは+1）。"
                              : "ADD は選択中の設定を複製して追加します（各CCは+2）。")
                .font(.caption2).foregroundStyle(Theme.label.opacity(0.6))
        }
    }

    /// パッド左のフェーダーの、選択中のMIDI設定の CH/CC。
    private var faderEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeader(title: "FADER  ·  VALUE \(set.faderValue)")
            NumberEditor(title: "CH", value: $set.faderAssignment.channel, range: MIDIRange.channels)
            NumberEditor(title: "CC", value: $set.faderAssignment.controller, range: MIDIRange.sevenBit)
            Button("SEND FADER") { set.sendFader() }.buttonStyle(.neon(size: 13))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.25)))
    }
}

/// パッド1つ分の、選択中のMIDI設定の編集。
private struct PadAxisEditor: View {
    @Bindable var model: XYPadModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                PanelTitle(text: model.name, size: 16)
                Spacer()
                Toggle("ON", isOn: $model.isEnabled)
                    .font(Theme.futura(13, weight: .bold)).foregroundStyle(Theme.label)
                    .fixedSize()
            }
            SettingsSectionHeader(title: "X  ·  VALUE \(model.xValue)")
            NumberEditor(title: "CH", value: $model.xAssignment.channel, range: MIDIRange.channels)
            NumberEditor(title: "CC", value: $model.xAssignment.controller, range: MIDIRange.sevenBit)
            Toggle("Reverse X", isOn: $model.reverseX)
                .font(Theme.futura(13)).foregroundStyle(Theme.label)

            SettingsSectionHeader(title: "Y  ·  VALUE \(model.yValue)")
            NumberEditor(title: "CH", value: $model.yAssignment.channel, range: MIDIRange.channels)
            NumberEditor(title: "CC", value: $model.yAssignment.controller, range: MIDIRange.sevenBit)
            Toggle("Reverse Y", isOn: $model.reverseY)
                .font(Theme.futura(13)).foregroundStyle(Theme.label)

            SettingsSectionHeader(title: "SEND (CC LEARN)")
            HStack(spacing: 6) {
                Button("SEND X") { model.sendX() }.buttonStyle(.neon(size: 13))
                Button("SEND Y") { model.sendY() }.buttonStyle(.neon(size: 13))
            }
            HStack(spacing: 6) {
                Button("BOTH") { model.sendBoth() }.buttonStyle(.neon(size: 13))
                Button("CENTER") { model.center() }.buttonStyle(.neon(size: 13))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.25)))
    }
}

// MARK: - Global settings

struct GlobalSettingsView: View {
    @Bindable var app: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var urlDraft = ""
    @State private var urlError: String?
    @State private var confirmReset = false

    private var midi: MIDIManager { app.midi }
    private var mirror: MirrorController { app.mirror }
    private var diagnostics: MirrorDiagnostics { app.diagnostics }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                PanelTitle(text: "SETTINGS", size: 22)
                Spacer()
                Button("DONE") { dismiss() }
                    .buttonStyle(.neon(size: 15))
                    .frame(width: 100)
            }
            .padding(.bottom, 10)

            ScrollView {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        midiSection
                        logSection
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 10) {
                        mirrorSection
                        otherSection
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .settingsChrome()
        .onAppear { urlDraft = mirror.urlString }
        .confirmationDialog("ノブとXYパッドのCH/CC・名前・値を初期値に戻しますか？", isPresented: $confirmReset,
                            titleVisibility: .visible) {
            Button("RESET", role: .destructive) { app.resetControlsToDefaults() }
        }
    }

    // MARK: MIDI

    private var midiSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(title: "MIDI OUTPUT")
            MIDIStatusLine(state: midi.state)

            destinationRow(title: "AUTO", subtitle: "Moveらしきポート → USBポートの順に自動選択",
                           selected: midi.preferred == nil, active: false) {
                midi.select(nil)
            }
            if midi.destinations.isEmpty {
                Text("MIDI出力先がありません。USB-CケーブルでMoveを接続してください。")
                    .font(.caption).foregroundStyle(Theme.label.opacity(0.7))
            }
            ForEach(midi.destinations) { d in
                let isActive: Bool = {
                    if case .connected(let info) = midi.state { return info.uniqueID == d.uniqueID }
                    return false
                }()
                destinationRow(title: d.name,
                               subtitle: [d.transport.rawValue, d.manufacturer, d.model, d.isOffline ? "OFFLINE" : ""]
                                   .filter { !$0.isEmpty }.joined(separator: " · "),
                               selected: midi.preferred?.uniqueID == d.uniqueID,
                               active: isActive) {
                    midi.select(d.identity)
                }
            }
            if let p = midi.preferred, !midi.destinations.contains(where: { $0.uniqueID == p.uniqueID || $0.name == p.name }) {
                destinationRow(title: p.name, subtitle: "保存済み・未接続（接続されると自動で再開）",
                               selected: true, active: false) {}
            }
            HStack(spacing: 8) {
                Button("RESCAN") { midi.rescan() }.buttonStyle(.neon(size: 14))
                Button("SEND ALL") { app.sendAll() }.buttonStyle(.neon(size: 14))
            }
            Toggle(isOn: Binding(get: { midi.loopbackEnabled }, set: { midi.setLoopback($0) })) {
                VStack(alignment: .leading) {
                    Text("Loopback test port").font(Theme.futura(14)).foregroundStyle(Theme.label)
                    Text("仮想MIDIポートを作成。選択すると送信バイト列をRXとしてログに表示（ハードウェア無しの検証用）")
                        .font(.caption2).foregroundStyle(Theme.label.opacity(0.6))
                }
            }
        }
    }

    private func destinationRow(title: String, subtitle: String, selected: Bool, active: Bool,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(Theme.neonBright)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.futura(15, weight: .bold)).foregroundStyle(Theme.label)
                    Text(subtitle).font(.caption2).foregroundStyle(Theme.label.opacity(0.6)).lineLimit(2)
                }
                Spacer()
                if active {
                    Text("ACTIVE").font(Theme.futura(11, weight: .bold)).foregroundStyle(Theme.ok)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Theme.darkBack : Color.black.opacity(0.3)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Log

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(title: "MIDI DEBUG LOG")
            Toggle(isOn: $app.midiLogEnabled) {
                Text("ログ記録（OFFでも送信数はカウント）").font(Theme.futura(14)).foregroundStyle(Theme.label)
            }
            MIDILogList(log: midi.log, lines: 60, fontSize: 11)
                .frame(height: 220)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.5)))
            Button("CLEAR LOG") { midi.log.clear() }.buttonStyle(.neon(size: 14))
        }
    }

    // MARK: Mirror

    private var mirrorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(title: "MOVE MIRROR DISPLAY")
            Text("Move Everything: Shift+Vol+Step2 → Display → Mirror Display ON")
                .font(.caption).foregroundStyle(Theme.label.opacity(0.7))
            HStack(spacing: 8) {
                TextField(MirrorController.usbURL, text: $urlDraft)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(Theme.futura(15))
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.5)))
                    .onSubmit(applyURL)
                Button("APPLY", action: applyURL).buttonStyle(.neon(size: 14)).frame(width: 90)
            }
            if let urlError {
                Text(urlError).font(.caption).foregroundStyle(Theme.danger)
            }
            HStack(spacing: 8) {
                Button("USB 172.16.254.1") {
                    urlDraft = MirrorController.usbURL
                    applyURL()
                }
                .buttonStyle(.neon(size: 13))
                Button("Wi-Fi move.local") {
                    urlDraft = MirrorController.wifiURL
                    applyURL()
                }
                .buttonStyle(.neon(size: 13))
                Button("RECONNECT") { mirror.reconnect() }.buttonStyle(.neon(size: 13))
            }
            Text("表示中: \(mirror.routeLabel)  \(mirror.activeURLString)")
                .font(.caption).foregroundStyle(Theme.label.opacity(0.8))
            Toggle(isOn: Binding(get: { mirror.wifiFallback }, set: { mirror.wifiFallback = $0 })) {
                VStack(alignment: .leading) {
                    Text("USBに届かないときWi-Fiで表示").font(Theme.futura(14)).foregroundStyle(Theme.label)
                    Text("USBアドレス設定時のみ。USBが復帰すると自動で戻ります（15秒ごとに確認）")
                        .font(.caption2).foregroundStyle(Theme.label.opacity(0.6))
                }
            }
            Toggle(isOn: Binding(get: { mirror.tint }, set: { mirror.tint = $0 })) {
                Text("ネオンブルーで表示（OFFで白黒）").font(Theme.futura(14)).foregroundStyle(Theme.label)
            }

            SettingsSectionHeader(title: "NETWORK PATH CHECK")
            Text("USB-C でMIDIが通ってもHTTPが届くとは限りません。有線(USB Ethernet)とWi-Fiそれぞれの経路で配信ページに到達できるか検証します。")
                .font(.caption).foregroundStyle(Theme.label.opacity(0.7))
            HStack {
                Text("Interfaces: " + (diagnostics.interfaces.isEmpty ? "none"
                                       : diagnostics.interfaces.map { "\($0.name) (\($0.type))" }.joined(separator: ", ")))
                    .font(.caption2).foregroundStyle(Theme.label.opacity(0.8))
            }
            Button(diagnostics.isChecking ? "CHECKING…" : "CHECK CONNECTION") {
                Task { await diagnostics.check(urlString: mirror.urlString) }
            }
            .buttonStyle(.neon(active: diagnostics.isChecking, size: 14))
            .disabled(diagnostics.isChecking)

            ForEach(diagnostics.results, id: \.route) { r in
                HStack {
                    Circle().fill(r.isOK ? Theme.ok : Theme.danger.opacity(0.8)).frame(width: 10, height: 10)
                    Text(r.route.rawValue).font(Theme.futura(12, weight: .bold)).foregroundStyle(Theme.label)
                        .frame(width: 100, alignment: .leading)
                    Text(r.summary).font(.caption).foregroundStyle(Theme.label.opacity(0.85)).lineLimit(2)
                }
            }
            if let rec = diagnostics.recommendation {
                Text(rec).font(.caption).foregroundStyle(Theme.label)
            }
            if let ip = diagnostics.resolvedIP, !ip.contains(":"),
               let current = MirrorController.validatedURL(mirror.urlString), current.host != ip {
                Button("USE IP \(ip)") {
                    var comps = URLComponents(url: current, resolvingAgainstBaseURL: false)
                    comps?.host = ip
                    if let s = comps?.url?.absoluteString {
                        urlDraft = s
                        applyURL()
                    }
                }
                .buttonStyle(.neon(size: 13))
            }
        }
    }

    private func applyURL() {
        if mirror.setURL(urlDraft) {
            urlError = nil
            urlDraft = mirror.urlString
        } else {
            urlError = "URLが不正です（例: http://192.168.1.100:7681）"
        }
    }

    // MARK: Other

    private var otherSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(title: "STOPWATCH")
            Toggle(isOn: Binding(get: { app.stopwatch.state.showsMilliseconds },
                                 set: { app.stopwatch.state.showsMilliseconds = $0 })) {
                Text("ミリ秒表示").font(Theme.futura(14)).foregroundStyle(Theme.label)
            }
            SettingsSectionHeader(title: "CONTROLS")
            Button("RESET CH/CC TO DEFAULTS") { confirmReset = true }.buttonStyle(.neon(size: 13))
            Text("初期値: S1-S4 = CH1 CC20-23 / XY1 = CC24,25 / XY2 = CC26,27 / XY3 = CC28,29 / XY4 = CC30,31 / KICK = CC103 / HAT = CC104 / FADER = CC102")
                .font(.caption2).foregroundStyle(Theme.label.opacity(0.6))
        }
    }
}

// MARK: - Shared small views

struct MIDIStatusLine: View {
    let state: MIDIConnectionState

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
                .shadow(color: color, radius: state.isConnected ? 6 : 0)
            Text(text)
                .font(Theme.futura(14, weight: .bold))
                .foregroundStyle(Theme.label)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    private var color: Color {
        switch state {
        case .connected: return Theme.ok
        case .searching, .waiting: return Color.orange
        case .unavailable: return Theme.danger
        }
    }

    private var text: String {
        switch state {
        case .connected(let d): return "\(d.transport.rawValue) MIDI · \(d.name)"
        case .searching: return "MIDI · NO DEVICE"
        case .waiting(let name): return "MIDI · WAITING \(name)"
        case .unavailable(let m): return "MIDI ERROR · \(m)"
        }
    }
}

/// ログの表示。TimelineView で一定間隔に読み出すだけなので、送信頻度に関係なく描画負荷は一定。
struct MIDILogList: View {
    let log: MIDILog
    var lines: Int = 6
    var fontSize: CGFloat = 10

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            let entries = log.snapshot(last: lines)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(entries.reversed()) { e in
                        Text(e.text)
                            .font(.system(size: fontSize, design: .monospaced))
                            .foregroundStyle(e.isError ? Theme.danger : Theme.label.opacity(0.85))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            .scrollDisabled(lines <= 8)
        }
    }
}
