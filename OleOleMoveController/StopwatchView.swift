//
//  StopwatchView.swift
//  OleOleMoveController
//
//  経過時間は「開始時刻」と「積算時間」から計算する。
//  画面更新回数には依存しないので、バックグラウンド復帰後や再起動後も正しい。
//

import SwiftUI
import Observation

// MARK: - Pure logic

extension StopwatchState {
    var isRunning: Bool { runningSince != nil }

    func elapsed(at now: Date) -> TimeInterval {
        guard let since = runningSince else { return accumulated }
        return accumulated + max(0, now.timeIntervalSince(since))
    }

    mutating func start(at now: Date) {
        guard runningSince == nil else { return }
        runningSince = now
    }

    mutating func stop(at now: Date) {
        guard runningSince != nil else { return }
        accumulated = elapsed(at: now)
        runningSince = nil
    }

    mutating func reset(at now: Date) {
        accumulated = 0
        // 動作中にRESETした場合は0から計測を続ける
        if runningSince != nil { runningSince = now }
    }
}

enum StopwatchFormatter {
    /// HH:MM:SS、ミリ秒表示時は HH:MM:SS.mmm
    static func string(_ t: TimeInterval, milliseconds: Bool) -> String {
        let clamped = max(0, t)
        let totalMs = Int((clamped * 1000).rounded(.down))
        let h = totalMs / 3_600_000
        let m = (totalMs / 60_000) % 60
        let s = (totalMs / 1000) % 60
        if milliseconds {
            return String(format: "%02d:%02d:%02d.%03d", h, m, s, totalMs % 1000)
        }
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}

// MARK: - Model

@Observable
@MainActor
final class StopwatchModel {
    var state: StopwatchState {
        didSet { onChange?() }
    }
    @ObservationIgnored var onChange: (() -> Void)?

    init(state: StopwatchState) { self.state = state }

    var isRunning: Bool { state.isRunning }

    func toggle(now: Date = Date()) {
        if state.isRunning { state.stop(at: now) } else { state.start(at: now) }
    }

    func reset(now: Date = Date()) { state.reset(at: now) }
}

// MARK: - View

/// 参考アプリと同じ操作：時間表示をタップで START/STOP、長押しで RESET。動作中は Neon。
struct StopwatchView: View {
    @Bindable var model: StopwatchModel
    var fontSize: CGFloat = 30

    var body: some View {
        // 表示は TimelineView で更新するが、値は常に時刻から計算する。
        TimelineView(.periodic(from: .now, by: model.state.showsMilliseconds ? 1.0 / 30.0 : 0.25)) { context in
            Text(StopwatchFormatter.string(model.state.elapsed(at: context.date),
                                           milliseconds: model.state.showsMilliseconds))
                .font(.custom("Futura", size: fontSize))
                .monospacedDigit()
                .foregroundStyle(Theme.neon)
                .neon(model.isRunning)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .onTapGesture { model.toggle() }
        .onLongPressGesture(minimumDuration: 0.8) { model.reset() }
        .accessibilityLabel("Stopwatch")
        .accessibilityHint("Tap to start or stop, long press to reset")
    }
}
