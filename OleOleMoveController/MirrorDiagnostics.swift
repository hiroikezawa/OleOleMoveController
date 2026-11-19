//
//  MirrorDiagnostics.swift
//  OleOleMoveController
//
//  Mirror Display への到達経路を検証する。
//  USB-C で MIDI が通っていても、HTTP が届くネットワーク経路があるとは限らない。
//  そこで「有線（USB Ethernet）」「Wi-Fi」それぞれに経路を限定して TCP 接続 + HTTP GET を試し、
//  どの経路で配信ページに届くかを判定する。
//

import Foundation
import Network
import Observation

struct ProbeResult: Equatable {
    enum Outcome: Equatable {
        case ok(remote: String, milliseconds: Int)
        case httpError(String)
        case failed(String)
        case noInterface
    }
    let route: Route
    let outcome: Outcome

    enum Route: String, CaseIterable {
        case wired = "USB / WIRED"
        case wifi = "WI-FI"
        case any = "ANY ROUTE"

        var interfaceType: NWInterface.InterfaceType? {
            switch self {
            case .wired: return .wiredEthernet
            case .wifi: return .wifi
            case .any: return nil
            }
        }
    }

    var isOK: Bool { if case .ok = outcome { return true } else { return false } }

    var remoteIP: String? {
        if case .ok(let remote, _) = outcome { return remote }
        return nil
    }

    var summary: String {
        switch outcome {
        case .ok(let remote, let ms): return "OK  \(remote)  \(ms) ms"
        case .httpError(let m): return "Reached, but \(m)"
        case .failed(let m): return m
        case .noInterface: return "No interface"
        }
    }
}

@Observable
@MainActor
final class MirrorDiagnostics {
    struct InterfaceInfo: Identifiable, Equatable {
        let name: String
        let type: String
        var id: String { name }
    }

    private(set) var interfaces: [InterfaceInfo] = []
    private(set) var hasWired = false
    private(set) var hasWiFi = false
    private(set) var results: [ProbeResult] = []
    private(set) var isChecking = false
    private(set) var checkedURL: String?

    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let list = path.availableInterfaces.map { iface -> InterfaceInfo in
                InterfaceInfo(name: iface.name, type: Self.typeName(iface.type))
            }
            let wired = path.availableInterfaces.contains { $0.type == .wiredEthernet }
            let wifi = path.availableInterfaces.contains { $0.type == .wifi }
            DispatchQueue.main.async {
                self?.interfaces = list
                self?.hasWired = wired
                self?.hasWiFi = wifi
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.oleole.move.pathmonitor"))
    }

    deinit { monitor.cancel() }

    nonisolated private static func typeName(_ t: NWInterface.InterfaceType) -> String {
        switch t {
        case .wifi: return "Wi-Fi"
        case .wiredEthernet: return "Wired (USB Ethernet)"
        case .cellular: return "Cellular"
        case .loopback: return "Loopback"
        case .other: return "Other"
        @unknown default: return "Unknown"
        }
    }

    /// 推奨経路の説明。
    var recommendation: String? {
        guard !results.isEmpty else { return nil }
        if results.first(where: { $0.route == .wired })?.isOK == true {
            return "USB-C（有線）経由で Mirror に到達できます。"
        }
        if results.first(where: { $0.route == .wifi })?.isOK == true {
            return "USB経由のネットワークはありません。Wi-Fi 経由で表示します。"
        }
        if results.first(where: { $0.route == .any })?.isOK == true {
            return "到達可能です（経路は自動選択）。"
        }
        return "到達できません。MoveとiPadを同じWi-Fiに接続し、Move側で Mirror Display を ON にしてください。move.local が解決できない場合は IP アドレスを指定してください。"
    }

    /// 解決されたIP（move.local → 192.168.x.x 等）。URLをIP指定に切り替える際に使う。
    var resolvedIP: String? { results.lazy.compactMap(\.remoteIP).first }

    func check(urlString: String) async {
        guard let url = MirrorController.validatedURL(urlString), let host = url.host else {
            results = [ProbeResult(route: .any, outcome: .failed("Invalid URL"))]
            return
        }
        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        isChecking = true
        checkedURL = url.absoluteString
        results = []
        let wired = hasWired, wifi = hasWiFi

        async let w = wired ? HTTPProbe.run(host: host, port: port, route: .wired) : ProbeResult(route: .wired, outcome: .noInterface)
        async let f = wifi ? HTTPProbe.run(host: host, port: port, route: .wifi) : ProbeResult(route: .wifi, outcome: .noInterface)
        async let a = HTTPProbe.run(host: host, port: port, route: .any)
        results = await [w, f, a]
        isChecking = false
    }
}

/// Network.framework で直接 TCP 接続し、最小限の HTTP GET を送って配信ページかどうか確認する。
/// （NWConnection は経路のインターフェース種別を指定できる。URLSession では指定できない）
enum HTTPProbe {
    static func run(host: String, port: Int, route: ProbeResult.Route, timeout: TimeInterval = 3) async -> ProbeResult {
        await withCheckedContinuation { (cont: CheckedContinuation<ProbeResult, Never>) in
            let params = NWParameters.tcp
            if let type = route.interfaceType { params.requiredInterfaceType = type }
            params.prohibitedInterfaceTypes = [.cellular]
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
                cont.resume(returning: ProbeResult(route: route, outcome: .failed("Bad port")))
                return
            }
            let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
            let queue = DispatchQueue(label: "com.oleole.move.probe.\(route.rawValue)")
            let started = Date()
            let once = Once()

            func finish(_ outcome: ProbeResult.Outcome) {
                guard once.claim() else { return }
                conn.cancel()
                cont.resume(returning: ProbeResult(route: route, outcome: outcome))
            }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let remote = Self.remoteDescription(conn) ?? host
                    let req = "GET / HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\nUser-Agent: OleOleMoveController\r\n\r\n"
                    conn.send(content: req.data(using: .utf8), completion: .contentProcessed { error in
                        if let error { finish(.failed(error.localizedDescription)); return }
                    })
                    Self.receiveAll(conn, buffer: Data()) { data in
                        let text = String(decoding: data.prefix(8192), as: UTF8.self)
                        let ms = Int(Date().timeIntervalSince(started) * 1000)
                        let statusLine = text.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
                        if !statusLine.contains(" 200") {
                            finish(.httpError(statusLine.isEmpty ? "no HTTP response" : statusLine))
                        } else if text.contains("<canvas") || text.contains("EventSource") {
                            finish(.ok(remote: remote, milliseconds: ms))
                        } else {
                            finish(.httpError("HTTP 200 but not a Move display page"))
                        }
                    }
                case .waiting(let error):
                    finish(.failed(Self.describe(error)))
                case .failed(let error):
                    finish(.failed(Self.describe(error)))
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(.failed("Timed out")) }
        }
    }

    private static func receiveAll(_ conn: NWConnection, buffer: Data, completion: @escaping (Data) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, isComplete, error in
            var buf = buffer
            if let data { buf.append(data) }
            // ページは小さいので、ヘッダ+canvas部分が届けば十分
            if isComplete || error != nil || buf.count > 8192 {
                completion(buf)
            } else {
                receiveAll(conn, buffer: buf, completion: completion)
            }
        }
    }

    private static func remoteDescription(_ conn: NWConnection) -> String? {
        guard case .hostPort(let h, _)? = conn.currentPath?.remoteEndpoint else { return nil }
        switch h {
        case .ipv4(let a): return "\(a)"
        case .ipv6(let a): return "[\(a)]"
        case .name(let n, _): return n
        @unknown default: return nil
        }
    }

    private static func describe(_ error: NWError) -> String {
        switch error {
        case .dns: return "DNS failed (name not resolved)"
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return "Connection refused"
            case .ENETUNREACH, .EHOSTUNREACH: return "No route to host"
            case .ENETDOWN: return "Network down"
            default: return "\(code)"
            }
        default: return error.localizedDescription
        }
    }
}

/// 一度だけ true を返すスレッドセーフなフラグ。
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
