//
//  SliderView.swift
//  OleOleMoveController
//
//  参考アプリの ModWheel スライダーと同じ見た目：濃紺（DARKBACKCOLOR）の角丸に、
//  値の位置を示す青い横バー。下に名前だけ。数値やボタンは出さない。
//  操作は相対ドラッグ（タッチ位置で値が飛ばない）。設定は名前の長押しで開く。
//

import SwiftUI

struct SliderControl: View {
    @Bindable var model: KnobModel
    var width: CGFloat
    var height: CGFloat
    /// 名前の表示幅。隣との間隔の範囲ではみ出してよいが、レイアウト上の幅はスライダー幅のまま
    var labelWidth: CGFloat?
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 8) {
            SliderTrack(value: model.normalized, isActive: model.isDragging || model.isTesting)
                .frame(width: width, height: height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { g in
                            // 上方向が増加。スライダーの高さ＝全域なので、指の移動量どおりにバーが動く
                            model.drag(delta: Double(-g.translation.height), fullRange: Double(height))
                        }
                        .onEnded { _ in model.endDrag() }
                )

            Text(model.name)
                .modifier(CustomTextColor())
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(width: labelWidth ?? width, height: 30)
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.6) { showSettings = true }
                .sheet(isPresented: $showSettings) {
                    KnobSettingsView(model: model)
                }
        }
        .frame(width: width)
    }
}

struct SliderTrack: View {
    let value: Double   // 0...1
    var isActive: Bool

    var body: some View {
        Canvas { ctx, size in
            let shape = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 10, style: .continuous)
            ctx.fill(shape, with: .color(Theme.darkBack))

            let barH: CGFloat = 10
            let inset: CGFloat = 6
            let v = CGFloat(min(max(value, 0), 1))
            let y = inset + (1 - v) * (size.height - inset * 2 - barH)
            let bar = Path(roundedRect: CGRect(x: inset, y: y, width: size.width - inset * 2, height: barH),
                           cornerRadius: 4)
            ctx.drawLayer { layer in
                if isActive { layer.addFilter(.shadow(color: .blue, radius: 10)) }
                layer.fill(bar, with: .color(Theme.neon))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Slider")
        .accessibilityValue("\(Int((value * 127).rounded()))")
    }
}
