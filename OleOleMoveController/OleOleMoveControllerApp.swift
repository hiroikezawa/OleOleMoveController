//
//  OleOleMoveControllerApp.swift
//  OleOleMoveController
//

import SwiftUI

@main
struct OleOleMoveControllerApp: App {
    @State private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(app: app)
                .preferredColorScheme(.dark)
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
                // 画面端のシステムジェスチャより先にパッド操作を優先させる（ライブ中の誤操作防止）
                .defersSystemGestures(on: .all)
                .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // ライブ中に自動スリープさせない
                UIApplication.shared.isIdleTimerDisabled = true
                app.midi.refreshDestinations()
                app.mirror.reconnectIfNeeded()
            case .inactive, .background:
                app.saveNow()
            @unknown default:
                break
            }
        }
    }
}
