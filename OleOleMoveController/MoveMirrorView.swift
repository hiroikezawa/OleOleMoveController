//
//  MoveMirrorView.swift
//  OleOleMoveController
//
//  Move Everything の Display Mirror (display_server.c) を WKWebView で表示する。
//
//  調査結果（move-anything src/host/display_server.c）:
//    - ポート 7681 の HTTP サーバーが HTML ページ（<canvas width=128 height=64>）を返す
//    - ページ内JSが EventSource('/stream') で Server-Sent Events を受信
//    - 各イベントは 1024 byte（SSD1306 形式 8ページ×128列、1bit）を base64 化したもの、約30Hz・変化時のみ
//  → 既存の配信ページをそのまま使い、CSSだけ注入して黒背景・全面表示にする。独自ストリーミングは実装しない。
//

import SwiftUI
import WebKit
import Observation

// MARK: - Controller

@Observable
@MainActor
final class MirrorController: NSObject {
    enum Status: Equatable {
        case idle
        case loading
        case connected(String)   // ページ内 #status の文字列（"connected - 30 fps" 等）
        case failed(String)

        var isFailure: Bool { if case .failed = self { return true } else { return false } }
    }

    /// Move の USB-C ネットワーク上のアドレス（Ableton 公式ヘルプ記載の固定アドレス）
    static let usbURL = "http://172.16.254.1:7681"
    static let usbHost = "172.16.254.1"
    /// Wi-Fi 経由（mDNS）
    static let wifiURL = "http://move.local:7681"

    /// 設定されたURL（通常は USB）
    private(set) var urlString: String { didSet { onChange?() } }
    /// いま実際に表示しているURL（USBに届かずWi-Fiへ退避中なら wifiURL）
    private(set) var activeURLString: String
    var tint: Bool {
        didSet { applyTint(); onChange?() }
    }
    /// USB に届かないとき Wi-Fi(move.local) へ自動で切り替える
    var wifiFallback: Bool {
        didSet { onChange?() }
    }
    private(set) var status: Status = .idle
    private(set) var lastAttempt: Date?

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private(set) lazy var webView: WKWebView = makeWebView()
    @ObservationIgnored private var retryWork: DispatchWorkItem?
    @ObservationIgnored private var retryCount = 0
    @ObservationIgnored private var primaryWatch: Timer?
    @ObservationIgnored private var disconnectWatch: DispatchWorkItem?

    static let messageHandlerName = "oleoleMirror"

    init(urlString: String, tint: Bool, wifiFallback: Bool = true) {
        self.urlString = urlString
        self.activeURLString = urlString
        self.tint = tint
        self.wifiFallback = wifiFallback
        super.init()
    }

    var url: URL? { Self.validatedURL(activeURLString) }

    var isUsingFallback: Bool { activeURLString != urlString }

    /// 表示中の経路
    var routeLabel: String {
        guard let host = Self.validatedURL(activeURLString)?.host else { return "" }
        if host == Self.usbHost { return "USB" }
        if host.hasSuffix(".local") { return "Wi-Fi" }
        return "LAN"
    }

    /// USB アドレスが設定されていて、Wi-Fi への退避が許可されているか
    private var canFallback: Bool {
        wifiFallback && Self.validatedURL(urlString)?.host == Self.usbHost
    }

    /// http/https かつホストを持つURLのみ受け付ける。スキーム省略時は http:// を補う。
    nonisolated static func validatedURL(_ string: String) -> URL? {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "http://" + s }
        guard let url = URL(string: s),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    @discardableResult
    func setURL(_ string: String) -> Bool {
        guard let url = Self.validatedURL(string) else { return false }
        urlString = url.absoluteString
        activeURLString = urlString
        reconnect()
        return true
    }

    /// 手動の再接続は常に設定URL（USB）から試す。
    func reconnect() {
        retryWork?.cancel()
        retryCount = 0
        activeURLString = urlString
        stopPrimaryWatch()
        load()
    }

    /// アプリ復帰時など。失敗中ならすぐ再試行する。
    func reconnectIfNeeded() {
        if status.isFailure || status == .idle { reconnect() }
    }

    private func load() {
        guard let url else {
            status = .failed("Invalid URL: \(activeURLString)")
            return
        }
        status = .loading
        lastAttempt = Date()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        webView.stopLoading()
        webView.load(request)
    }

    /// 接続失敗時はライブ中に手を煩わせないよう自動で再試行（2s→4s→…最大10s）。
    private func scheduleRetry() {
        retryWork?.cancel()
        retryCount += 1
        let delay = min(10.0, 2.0 * Double(retryCount))
        let work = DispatchWorkItem { [weak self] in self?.load() }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func fail(_ message: String) {
        disconnectWatch?.cancel()
        status = .failed(message)
        if canFallback && !isUsingFallback {
            // USB に届かない → すぐ Wi-Fi で試す
            activeURLString = Self.wifiURL
            retryWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.load() }
            retryWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            return
        }
        if canFallback && isUsingFallback {
            // Wi-Fi もだめ → 次は USB から試し直す
            activeURLString = urlString
        }
        scheduleRetry()
    }

    /// Wi-Fi へ退避中は、USB が復帰したかを定期的に確認して戻す。
    private func startPrimaryWatch() {
        guard primaryWatch == nil, let primary = Self.validatedURL(urlString), let host = primary.host else { return }
        let port = primary.port ?? 80
        primaryWatch = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isUsingFallback else { return }
                let result = await HTTPProbe.run(host: host, port: port, route: .any, timeout: 2)
                if result.isOK && self.isUsingFallback { self.reconnect() }
            }
        }
    }

    private func stopPrimaryWatch() {
        primaryWatch?.invalidate()
        primaryWatch = nil
    }

    private func applyTint() {
        let js = "document.documentElement.classList.toggle('oleole-tint', \(tint ? "true" : "false"));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: WebView setup

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.suppressesIncrementalRendering = false
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: Self.injectedScript(tint: tint),
                                              injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true))
        controller.add(WeakScriptHandler(self), name: Self.messageHandlerName)
        config.userContentController = controller

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        wv.isOpaque = false
        wv.backgroundColor = .black
        wv.scrollView.backgroundColor = .black
        // 表示専用：スクロール・ズーム・タッチをすべて無効化し、誤操作とジェスチャ競合を防ぐ
        wv.scrollView.isScrollEnabled = false
        wv.scrollView.bounces = false
        wv.scrollView.pinchGestureRecognizer?.isEnabled = false
        wv.scrollView.minimumZoomScale = 1
        wv.scrollView.maximumZoomScale = 1
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.isUserInteractionEnabled = false
        wv.allowsLinkPreview = false
        return wv
    }

    /// 配信ページに注入するスクリプト。canvas をビューいっぱいに拡大し、余白・枠・ステータス表示を消す。
    /// ページの #status 文字列はネイティブ側に転送して接続状態として表示する。
    static func injectedScript(tint: Bool) -> String {
        let css = """
        html,body{margin:0!important;padding:0!important;background:#000!important;width:100%!important;height:100%!important;overflow:hidden!important;}
        body{display:block!important;height:100vh!important;-webkit-user-select:none;-webkit-touch-callout:none;}
        canvas{display:block!important;width:100vw!important;height:100vh!important;border:0!important;image-rendering:pixelated;image-rendering:crisp-edges;}
        #status{display:none!important;}
        html.oleole-tint body::after{content:'';position:fixed;left:0;top:0;right:0;bottom:0;background:#3a8dff;mix-blend-mode:multiply;pointer-events:none;}
        """
        return """
        (function(){
          var m=document.querySelector('meta[name=viewport]');
          if(!m){m=document.createElement('meta');m.name='viewport';document.head.appendChild(m);}
          m.content='width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no';
          var s=document.createElement('style');s.textContent=\(jsString(css));document.head.appendChild(s);
          document.documentElement.classList.toggle('oleole-tint',\(tint ? "true" : "false"));
          function post(t){try{window.webkit.messageHandlers.\(messageHandlerName).postMessage(t);}catch(e){}}
          var st=document.getElementById('status');
          if(st){
            new MutationObserver(function(){post(st.textContent||'');}).observe(st,{childList:true,characterData:true,subtree:true});
            post(st.textContent||'');
          } else {
            post(document.querySelector('canvas') ? 'connected' : 'no-canvas');
          }
        })();
        """
    }

    private static func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        let arr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
    }

    fileprivate func receivedStatus(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t == "no-canvas" {
            fail("Page has no display canvas (not a Move Everything mirror?)")
        } else if t.hasPrefix("connected") {
            retryCount = 0
            disconnectWatch?.cancel()
            status = .connected(t)
            if isUsingFallback { startPrimaryWatch() } else { stopPrimaryWatch() }
        } else if t.contains("disconnected") {
            // ページ側の EventSource が自動再接続する。ページ自体は生きているので再読込はしない。
            status = .failed("Stream disconnected — reconnecting…")
            // ケーブルを抜いた等でストリームが戻らなければ、経路を切り替えて読み直す
            if disconnectWatch == nil || disconnectWatch?.isCancelled == true {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.status.isFailure else { return }
                    self.fail("Stream lost")
                }
                disconnectWatch = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
            }
        } else if !t.isEmpty {
            status = .loading
        }
    }
}

extension MirrorController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !Self.isBenign(error) else { return }
        fail(Self.describe(error))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !Self.isBenign(error) else { return }
        fail(Self.describe(error))
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if let http = navigationResponse.response as? HTTPURLResponse, http.statusCode != 200 {
            fail("HTTP \(http.statusCode)")
            return .cancel
        }
        return .allow
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        fail("Web content process terminated")
    }

    /// stopLoading() による取消や、HTTPエラーでのポリシー中断は二重の失敗として扱わない。
    private static func isBenign(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return true }
        if ns.domain == WKError.errorDomain && ns.code == 102 { return true } // frame load interrupted by policy change
        return false
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                return "Host not found (try the IP address instead of move.local)"
            case NSURLErrorTimedOut: return "Timed out"
            case NSURLErrorCannotConnectToHost: return "Connection refused (Mirror server not running?)"
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                return "No network path to Move"
            case NSURLErrorCancelled: return "Cancelled"
            default: break
            }
        }
        return ns.localizedDescription
    }
}

/// WKUserContentController は handler を強参照するので、循環参照を避けるための弱参照ラッパー。
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: MirrorController?
    init(_ target: MirrorController) { self.target = target }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let text = message.body as? String else { return }
        MainActor.assumeIsolated { target?.receivedStatus(text) }
    }
}

// MARK: - SwiftUI wrapper

struct MirrorWebView: UIViewRepresentable {
    let controller: MirrorController

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        container.clipsToBounds = true
        let wv = controller.webView
        wv.translatesAutoresizingMaskIntoConstraints = true
        wv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        wv.frame = container.bounds
        container.addSubview(wv)
        if controller.status == .idle { controller.reconnect() }
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// 128×64 のMove画面（2:1）と、接続状態・再接続ボタン。
struct MoveMirrorView: View {
    let controller: MirrorController

    var body: some View {
        ZStack {
            Color.black
            MirrorWebView(controller: controller)
                .opacity(isShowingContent ? 1 : 0.25)

            if !isShowingContent {
                VStack(spacing: 6) {
                    Text(statusTitle)
                        .font(Theme.futura(20))
                        .foregroundStyle(Theme.neon)
                    Text(statusDetail)
                        .font(Theme.futura(13))
                        .foregroundStyle(Theme.neon.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.7)
                }
                .padding(8)
            }
        }
        .aspectRatio(2, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        // 表示専用。未接続のときだけタップで再接続できる（接続中のタップは何もしない）
        .contentShape(Rectangle())
        .onTapGesture { if !isShowingContent { controller.reconnect() } }
    }

    private var isShowingContent: Bool {
        if case .connected = controller.status { return true }
        return false
    }

    private var statusTitle: String {
        switch controller.status {
        case .idle: return "MIRROR IDLE"
        case .loading: return "CONNECTING…"
        case .connected: return "MIRROR"
        case .failed: return "MIRROR OFFLINE"
        }
    }

    private var statusDetail: String {
        switch controller.status {
        case .failed(let m): return "\(m)\n\(controller.activeURLString)\nTAP TO RECONNECT"
        default: return controller.activeURLString
        }
    }
}
