//
//  XYPadView.swift
//  OleOleMoveController
//
//  参考：OleOleMIDICon/CV5_Sampler_3.swift の XYPadControlView。
//  参考実装は Controls ライブラリの XYPad を表示し、上に重ねた Color.clear の
//  DragGesture(minimumDistance: 0) でタッチ座標を 0.0〜1.0 に正規化していた。
//  ここでは外部ライブラリを使わず同じ見た目を Canvas で描き、同じジェスチャ方式で操作する。
//  各パッドは独立した DragGesture を持つので、2つのパッドを別の指で同時に操作できる。
//

import SwiftUI

/// パッド本体（参考アプリと同じ 180×180、角丸20、DARKBACKCOLOR）。
struct XYPadSurface: View {
    @Bindable var model: XYPadModel
    let size: CGFloat

    var body: some View {
        let dimension = CGSize(width: size, height: size)
        XYPadCanvas(x: model.x, y: model.y, isTouching: model.isTouching, isEnabled: model.isEnabled)
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { model.touch(at: $0.location, in: dimension) }
                    .onEnded { model.endTouch(at: $0.location, in: dimension) }
            )
            .accessibilityElement()
            .accessibilityLabel(model.name)
            .accessibilityValue("X \(model.xValue), Y \(model.yValue)")
    }
}

/// XYパッド2つで1セット。下にセット共通のMIDI設定の切り替え（◁ 名前 ▷）。
/// 参考アプリと同じく数値は出さない。MIDI設定の名前を長押しすると設定シートが開く。
struct XYPadSetControl: View {
    @Bindable var set: XYPadSetModel
    var padSize: CGFloat = 180
    var spacing: CGFloat = 30
    var faderWidth: CGFloat = 65
    var faderSpacing: CGFloat = 20
    @State private var showSettings = false

    var body: some View {
        HStack(alignment: .top, spacing: faderSpacing) {
            if set.hasFader {
                SetFaderControl(set: set, width: faderWidth, height: padSize)
            }
            padsAndPresetSwitcher
        }
    }

    private var padsAndPresetSwitcher: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: spacing) {
                ForEach(set.pads) { pad in
                    XYPadControl(model: pad, size: padSize)
                }
            }

            // セット共通のMIDI設定の切り替え（参考アプリの "Pst ◁ ▷" と同じ形）
            HStack(spacing: 0) {
                arrow("◁") { set.selectPreviousPreset() }
                Text(set.presetName)
                    .modifier(CustomTextColor())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .contentShape(Rectangle())
                    .onLongPressGesture(minimumDuration: 0.6) { showSettings = true }
                arrow("▷") { set.selectNextPreset() }
            }
            .frame(width: padSize * 2 + spacing)
            .sheet(isPresented: $showSettings) {
                XYPadSetSettingsView(set: set)
            }
        }
    }

    private func arrow(_ symbol: String, action: @escaping () -> Void) -> some View {
        let enabled = set.presetCount > 1
        return Text(symbol)
            .modifier(CustomTextColor())
            .opacity(enabled ? 1 : 0.2)
            .frame(width: 60, height: 40)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .allowsHitTesting(enabled)
    }
}

/// セット横のフェーダー。CH/CC と値は選択中のMIDI設定ごと（設定はMIDI設定名の長押しから）。
/// 上の 40pt はパッドの ON/OFF 行に合わせた見出し、トラックはパッド本体と同じ高さ。
struct SetFaderControl: View {
    @Bindable var set: XYPadSetModel
    var width: CGFloat
    var height: CGFloat

    var body: some View {
        VStack(spacing: 6) {
            Text("FADER")
                .modifier(CustomTextColor(size: 14))
                .opacity(0.6)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(width: width, height: 40)

            SliderTrack(value: set.faderNormalized, isActive: set.isFaderDragging)
                .frame(width: width, height: height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { g in
                            set.dragFader(delta: Double(-g.translation.height), fullRange: Double(height))
                        }
                        .onEnded { _ in set.endFaderDrag() }
                )
        }
    }
}

/// パッド1つ：ON/OFF（タップ）とパッド本体。
struct XYPadControl: View {
    @Bindable var model: XYPadModel
    var size: CGFloat = 180

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                // 参考アプリの XYPadControlView：文字だけのON/OFF、ONでNeon
                Text(model.isEnabled ? "ON" : "OFF")
                    .modifier(CustomTextColor())
                    .modifier(Neon(isNeoned: model.isEnabled))
                    .frame(width: 60, height: 40, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { model.isEnabled.toggle() }
                Spacer()
                Text(model.name)
                    .modifier(CustomTextColor(size: 14))
                    .opacity(0.6)
            }
            .frame(width: size)

            XYPadSurface(model: model, size: size)
        }
    }
}

/// グリッド・十字ガイド・マーカーの描画。
struct XYPadCanvas: View {
    let x: Double
    let y: Double
    let isTouching: Bool
    let isEnabled: Bool

    var body: some View {
        Canvas { ctx, size in
            let shape = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 20, style: .continuous)
            ctx.fill(shape, with: .color(Theme.darkBack))
            // 参考アプリ（Controls XYPad, indicatorSize 15×15）と同じ、面と点だけ
            let p = CGPoint(x: CGFloat(x) * (size.width - 15) + 7.5,
                            y: (1 - CGFloat(y)) * (size.height - 15) + 7.5)
            let alpha: Double = isEnabled ? 1 : 0.35
            ctx.drawLayer { layer in
                if isTouching && isEnabled { layer.addFilter(.shadow(color: .blue, radius: 10)) }
                layer.fill(Path(ellipseIn: CGRect(x: p.x - 7.5, y: p.y - 7.5, width: 15, height: 15)),
                           with: .color(Theme.indicator.opacity(alpha)))
            }
        }
    }
}
