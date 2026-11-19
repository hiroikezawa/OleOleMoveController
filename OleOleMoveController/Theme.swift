//
//  Theme.swift
//  OleOleMoveController
//
//  参考アプリ (OleOleMIDICon) の ViewCommon.swift / ContentView.swift の配色・Neon・BlueShadow を踏襲。
//

import SwiftUI

enum Theme {
    /// 参考アプリの TEXTCOLOR (Color.blue)
    static let neon = Color.blue
    /// コントロールの発光色（少し明るいネオンブルー）
    static let neonBright = Color(red: 0.25, green: 0.55, blue: 1.0)
    /// 数値やラベル用の明るいブルー
    static let label = Color(red: 0.55, green: 0.80, blue: 1.0)
    /// XYパッドのインジケーター等（参考アプリのスクリーンショットの明るい青い点）
    static let indicator = Color(red: 0.1, green: 0.55, blue: 1.0)
    /// 参考アプリの DARKBACKCOLOR
    static let darkBack = Color(red: 0, green: 0, blue: 0.3)
    /// 操作パネル（暗い青）
    static let panel = Color(red: 0.0, green: 0.02, blue: 0.16)
    static let panelStroke = Color.blue.opacity(0.35)
    /// 消灯状態の文字（参考アプリの DARKTEXTCOLORHALF 相当）
    static let dim = Color(red: 0.12, green: 0.18, blue: 0.40)
    static let danger = Color(red: 1.0, green: 0.30, blue: 0.40)
    static let ok = Color(red: 0.30, green: 0.95, blue: 0.75)

    static let cornerRadius: CGFloat = 16

    /// 参考アプリの背景：黒 → 暗い紫。ストップウォッチ動作中は暗い青。
    static func background(running: Bool) -> LinearGradient {
        let end = running ? Color(red: 0.0, green: 0.0, blue: 0.5) : Color(red: 0.3, green: 0.0, blue: 0.5)
        return LinearGradient(colors: [.black, end], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func futura(_ size: CGFloat, weight: FuturaWeight = .medium) -> Font {
        .custom(weight.rawValue, size: size)
    }

    enum FuturaWeight: String {
        case medium = "Futura-Medium"
        case bold = "Futura-Bold"
        case condensed = "Futura-CondensedExtraBold"
    }
}

// MARK: - Modifiers (参考アプリ由来)

struct BlueShadow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .shadow(color: Color.blue, radius: 20, x: 0, y: 0)
            .shadow(color: Color.blue, radius: 20, x: 0, y: 0)
            .shadow(color: Color.blue.opacity(0.8), radius: 3, x: 0, y: 0)
    }
}

struct Neon: ViewModifier {
    var isNeoned: Bool

    func body(content: Content) -> some View {
        content
            .shadow(color: Color.blue, radius: isNeoned ? 20 : 0)
            .shadow(color: Color.blue, radius: isNeoned ? 20 : 0)
            .shadow(color: Color.blue.opacity(0.8), radius: isNeoned ? 3 : 0)
    }
}

struct NeonWeak: ViewModifier {
    var isNeoned: Bool
    func body(content: Content) -> some View {
        content.shadow(color: Color.blue, radius: isNeoned ? 12 : 0)
    }
}

/// 参考アプリの CustomTextColor：Futura 20、TEXTCOLOR(Color.blue)
struct CustomTextColor: ViewModifier {
    var size: CGFloat = 20
    func body(content: Content) -> some View {
        content
            .foregroundColor(Theme.neon)
            .font(.custom("Futura", size: size))
    }
}

/// 角丸の暗い青パネル。
struct PanelBackground: ViewModifier {
    var highlighted = false
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(Theme.panel.opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(highlighted ? Theme.neonBright : Theme.panelStroke,
                                  lineWidth: highlighted ? 1.5 : 1)
            )
    }
}

extension View {
    func panel(highlighted: Bool = false) -> some View { modifier(PanelBackground(highlighted: highlighted)) }
    func neon(_ on: Bool = true) -> some View { modifier(Neon(isNeoned: on)) }
    func neonWeak(_ on: Bool = true) -> some View { modifier(NeonWeak(isNeoned: on)) }
}

// MARK: - Buttons

/// ライブ用の大きめボタン。最小44pt。押下中は発光する。
struct NeonButtonStyle: ButtonStyle {
    var isActive = false
    var fontSize: CGFloat = 16
    var minHeight: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        let lit = isActive || configuration.isPressed
        configuration.label
            .font(Theme.futura(fontSize, weight: .bold))
            .foregroundStyle(lit ? Color.white : Theme.label)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 10)
            .frame(minHeight: minHeight)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(lit ? Theme.neon.opacity(0.85) : Theme.darkBack.opacity(0.8))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.neonBright.opacity(lit ? 1 : 0.5), lineWidth: 1)
            )
            .neonWeak(lit)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == NeonButtonStyle {
    static var neon: NeonButtonStyle { NeonButtonStyle() }
    static func neon(active: Bool = false, size: CGFloat = 16, minHeight: CGFloat = 44) -> NeonButtonStyle {
        NeonButtonStyle(isActive: active, fontSize: size, minHeight: minHeight)
    }
}

/// パネル見出し。
struct PanelTitle: View {
    let text: String
    var size: CGFloat = 15
    var body: some View {
        Text(text.uppercased())
            .font(Theme.futura(size, weight: .bold))
            .foregroundStyle(Theme.neonBright)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .neonWeak()
    }
}
