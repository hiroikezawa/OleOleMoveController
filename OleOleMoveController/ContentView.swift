//
//  ContentView.swift
//  OleOleMoveController
//
//  参考アプリ（OleOleMIDICon）のデザインに合わせた1画面構成。
//  画面上にはライブ中に触るものだけを置く（枠付きボタン・パネル・ログは置かない）。
//
//    最上段      アプリ名 / MIDI接続（M）/ バッテリー残量 / ストップウォッチ（タップでSTART/STOP、長押しでRESET）
//    左上        Move Mirror Display（残りの面積で最大の 2:1）
//    右上        スライダー KICK / HAT / S1〜S4
//    左下 / 右下 XYパッド 2つで1セット（参考アプリと同じ 180×180）。MIDI設定はセット単位で ◁ ▷ 切り替え
//                右下のセットのみパッドの左にフェーダー（CH/CC はMIDI設定ごと）
//
//  ストップウォッチが止まっている間にスライダー・パッド・フェーダーを触ると、
//  画面中央に大きく「時計が止まっている」警告を出す（タッチは遮らない）。
//
//  設定は長押しで開く（シートで表示するので画面外に見切れない）：
//    アプリ名 / M 長押し → 全体設定（MIDI接続先・Mirror URL・ログ等）
//    スライダー名 長押し → そのスライダーの設定
//    XYセット下のMIDI設定名 長押し → そのセットのMIDI設定（複数・名前付き）
//

import SwiftUI
import UIKit

/// 画面サイズから各エリアの寸法を決める（純粋関数・テスト可能）。
struct ControllerLayout: Equatable {
    static let padSize: CGFloat = 180          // 参考アプリの XYPad と同じ
    static let padSpacing: CGFloat = 30
    /// 参考アプリの ModWheel と同じ（SLIDER_WIDTH / 16 * 1.3 × SLIDER_HEIGHT * 1.4）
    static let sliderWidth: CGFloat = 65
    static let sliderHeight: CGFloat = 210
    /// KICK / HAT / S1〜S4 の間隔の最小値（実際は右列の幅いっぱいに均等に広げる）
    static let minSliderSpacing: CGFloat = 12
    /// 右下のセット横のフェーダーとパッドの間隔
    static let faderSpacing: CGFloat = 20
    static let sliderCount: CGFloat = CGFloat(AppConfiguration.knobCount + AppConfiguration.defaultDrumFaders.count)

    let margin: CGFloat = 16
    let spacing: CGFloat = 16
    let columnGap: CGFloat = 40
    let topBarHeight: CGFloat = 44
    /// ON/OFF(40) + パッド + MIDI設定の切り替え(40) + 間隔
    let padBlockHeight: CGFloat = 40 + 6 + ControllerLayout.padSize + 6 + 40
    /// XYパッド2つ分の幅
    let padSetWidth: CGFloat = ControllerLayout.padSize * 2 + ControllerLayout.padSpacing
    /// 右下のセットはパッドの左にフェーダー（スライダーと同じ幅）を持つ
    let rightPadSetWidth: CGFloat = ControllerLayout.padSize * 2 + ControllerLayout.padSpacing
        + ControllerLayout.sliderWidth + ControllerLayout.faderSpacing
    let rightColumnWidth: CGFloat
    /// スライダー同士の間隔。Move画面を小さくしない範囲（右下のセットの幅）で最大にする
    let sliderSpacing: CGFloat
    let topAreaHeight: CGFloat
    let mirrorHeight: CGFloat

    init(size: CGSize) {
        let count = ControllerLayout.sliderCount
        let minSlidersWidth = ControllerLayout.sliderWidth * count + ControllerLayout.minSliderSpacing * (count - 1)
        rightColumnWidth = max(rightPadSetWidth, minSlidersWidth)
        sliderSpacing = (rightColumnWidth - ControllerLayout.sliderWidth * count) / (count - 1)
        topAreaHeight = max(160, size.height - margin * 2 - topBarHeight - spacing * 2 - padBlockHeight)
        let leftWidth = size.width - margin * 2 - rightColumnWidth - columnGap
        // 128×64 のドットが均一に見えるよう 32pt 刻みにスナップ
        let snapped = (min(topAreaHeight, leftWidth / 2) / 32).rounded(.down) * 32
        mirrorHeight = max(96, snapped)
    }

    var mirrorWidth: CGFloat { mirrorHeight * 2 }
}

struct ContentView: View {
    @Bindable var app: AppModel
    @State private var showSettings = false
    /// ストップウォッチ停止中に操作したときの警告
    @State private var showClockWarning = false
    @State private var hideWarningTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            let layout = ControllerLayout(size: geo.size)
            ZStack {
                Theme.background(running: app.stopwatch.isRunning)
                    .ignoresSafeArea()

                VStack(alignment: .leading, spacing: layout.spacing) {
                    TopBar(app: app, showSettings: $showSettings)
                        .frame(height: layout.topBarHeight)

                    HStack(alignment: .top, spacing: layout.columnGap) {
                        // 左列：Move画面 / XYパッド 1・2
                        VStack(alignment: .leading, spacing: layout.spacing) {
                            MoveMirrorView(controller: app.mirror)
                                .frame(width: layout.mirrorWidth, height: layout.mirrorHeight)
                                .overlay(alignment: .bottomLeading) { routeBadge }
                                .frame(maxWidth: .infinity, maxHeight: layout.topAreaHeight, alignment: .topLeading)
                            XYPadSetControl(set: app.padSets[0], padSize: ControllerLayout.padSize,
                                            spacing: ControllerLayout.padSpacing)
                                .simultaneousGesture(interactionWatcher)
                        }

                        // 右列：スライダー / XYパッド 3・4
                        VStack(alignment: .trailing, spacing: layout.spacing) {
                            HStack(alignment: .top, spacing: layout.sliderSpacing) {
                                ForEach(app.drumFaders + app.knobs) { knob in
                                    SliderControl(model: knob, width: ControllerLayout.sliderWidth,
                                                  height: ControllerLayout.sliderHeight,
                                                  labelWidth: ControllerLayout.sliderWidth + layout.sliderSpacing)
                                }
                            }
                            .frame(width: layout.rightColumnWidth, height: layout.topAreaHeight, alignment: .topTrailing)
                            .simultaneousGesture(interactionWatcher)
                            XYPadSetControl(set: app.padSets[1], padSize: ControllerLayout.padSize,
                                            spacing: ControllerLayout.padSpacing,
                                            faderWidth: ControllerLayout.sliderWidth,
                                            faderSpacing: ControllerLayout.faderSpacing)
                                .simultaneousGesture(interactionWatcher)
                        }
                        .frame(width: layout.rightColumnWidth)
                    }
                }
                .padding(layout.margin)

                if showClockWarning {
                    ClockStoppedWarning()
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: showClockWarning)
        }
        .ignoresSafeArea()
        .onChange(of: app.stopwatch.isRunning) { _, running in
            if running { hideClockWarning() }
        }
        .sheet(isPresented: $showSettings) {
            GlobalSettingsView(app: app)
        }
    }

    /// 操作エリアへのタッチを、子のジェスチャー（スライダー・パッド）を妨げずに検知する。
    private var interactionWatcher: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !app.stopwatch.isRunning else { return }
                hideWarningTask?.cancel()
                showClockWarning = true
            }
            .onEnded { _ in
                guard showClockWarning else { return }
                // 指を離してから少しの間は表示を残す
                hideWarningTask?.cancel()
                hideWarningTask = Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    guard !Task.isCancelled else { return }
                    showClockWarning = false
                }
            }
    }

    private func hideClockWarning() {
        hideWarningTask?.cancel()
        showClockWarning = false
    }

    /// Move画面の表示経路（USB / Wi-Fi）。画面の邪魔にならないよう左下に小さく。
    private var routeBadge: some View {
        Text(app.mirror.routeLabel)
            .modifier(CustomTextColor(size: 11))
            .opacity(0.6)
            .padding(6)
            .allowsHitTesting(false)
    }
}

// MARK: - Top bar

private struct TopBar: View {
    @Bindable var app: AppModel
    @Binding var showSettings: Bool

    var body: some View {
        HStack(spacing: 20) {
            // アプリ名：長押しで全体設定（ライブ中の誤タップで開かないよう長押しのみ）
            Text("OleOle Move")
                .font(.custom("Futura", size: 25))
                .foregroundColor(Theme.neon)
                .modifier(Neon(isNeoned: app.midi.state.isConnected))
                .frame(height: 44)
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.6) { showSettings = true }

            Spacer()

            // 参考アプリの "T P O" と同じ：文字が光れば接続中
            Text("M")
                .modifier(CustomTextColor())
                .modifier(NeonWeak(isNeoned: app.midi.state.isConnected))
                .opacity(app.midi.state.isConnected ? 1 : 0.4)
                .frame(width: 30, height: 44)
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.6) { showSettings = true }
                .accessibilityLabel(app.midi.state.isConnected ? "MIDI connected" : "MIDI not connected")

            BatteryIndicator()

            StopwatchView(model: app.stopwatch, fontSize: 30)
        }
    }
}

// MARK: - Battery

/// バッテリー残量。ステータスバーを隠しているので、ライブ中に残量を確認できるよう最上段に出す。
private struct BatteryIndicator: View {
    @State private var level: Float = -1
    @State private var batteryState: UIDevice.BatteryState = .unknown

    /// これ以下で充電していなければ警告色にする
    private static let lowThreshold: Float = 0.2

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbolName)
                .font(.system(size: 20))
            Text(levelText)
                .monospacedDigit()
        }
        .modifier(CustomTextColor(size: 18))
        .foregroundColor(isLow ? .red : Theme.neon)
        .frame(height: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery \(levelText)")
        .task {
            UIDevice.current.isBatteryMonitoringEnabled = true
            refresh()
            // 残量と充電状態の変化を受け取って更新する
            await withTaskGroup(of: Void.self) { group in
                for name in [UIDevice.batteryLevelDidChangeNotification,
                             UIDevice.batteryStateDidChangeNotification] {
                    group.addTask { @MainActor in
                        for await _ in NotificationCenter.default.notifications(named: name).map({ _ in () }) {
                            refresh()
                        }
                    }
                }
            }
        }
    }

    private func refresh() {
        level = UIDevice.current.batteryLevel
        batteryState = UIDevice.current.batteryState
    }

    private var isCharging: Bool { batteryState == .charging || batteryState == .full }
    private var isLow: Bool { level >= 0 && level <= Self.lowThreshold && !isCharging }

    /// 取得できない（シミュレータ等）ときは "--"
    private var levelText: String {
        level < 0 ? "--%" : "\(Int((level * 100).rounded()))%"
    }

    private var symbolName: String {
        if isCharging { return "battery.100percent.bolt" }
        switch level {
        case ..<0: return "battery.0percent"
        case ..<0.13: return "battery.0percent"
        case ..<0.38: return "battery.25percent"
        case ..<0.63: return "battery.50percent"
        case ..<0.88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

// MARK: - Clock warning

/// ストップウォッチ停止中に操作したときの大きな警告。タッチは下のコントロールへ通す。
private struct ClockStoppedWarning: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40, weight: .bold))
                .symbolEffect(.pulse, options: .repeating)
            Text("CLOCK STOPPED")
                .font(Theme.futura(36, weight: .bold))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text("時計が動いていません — 右上の時計をタップでスタート")
                .font(.system(size: 13, weight: .bold))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 30)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .fill(Theme.danger.opacity(0.88))
        )
        .shadow(color: Theme.danger, radius: 15)
        .padding(40)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Stopwatch is not running")
    }
}
