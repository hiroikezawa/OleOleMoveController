//
//  MIDIManager.swift
//  OleOleMoveController
//
//  Core MIDI によるCC送信。
//  - MIDIManager  : MainActor。接続先の列挙・選択・状態をUIへ公開する
//  - MIDISendEngine: 専用のシリアルキューで間引きと送信を行う（UI更新から分離）
//

import Foundation
import CoreMIDI
import Observation

// MARK: - Destination info

enum MIDITransport: String {
    case usb = "USB"
    case network = "NETWORK"
    case bluetooth = "BLE"
    case virtual = "VIRTUAL"
    case other = "MIDI"
}

struct MIDIDestinationInfo: Identifiable, Equatable {
    let endpoint: MIDIEndpointRef
    let uniqueID: Int32
    let name: String
    let manufacturer: String
    let model: String
    let driverOwner: String
    let transport: MIDITransport
    let isOffline: Bool

    var id: Int32 { uniqueID }
    var identity: MIDIDestinationIdentity { MIDIDestinationIdentity(uniqueID: uniqueID, name: name) }

    /// ポート名を固定せず、列挙された属性からMoveらしさを判定する。
    var looksLikeMove: Bool {
        let haystack = "\(name) \(manufacturer) \(model)".lowercased()
        return haystack.contains("move") || manufacturer.lowercased().contains("ableton")
    }

    /// Move の USB-C には複数のMIDIポート（Live / User / External / Standalone）が出るが、
    /// Schwung (旧 Move Everything) が外部MIDI（cable 2）として受け取るのは
    /// "Standalone" ポートだけ（schwung docs/SYSEX.md の実測）。
    var isStandalonePort: Bool { name.lowercased().contains("standalone") }

    /// 自動選択の優先度。Move の Standalone ポート > Move の他ポート > その他USB。
    var autoScore: Int {
        guard !isOffline else { return -1 }
        var score = 0
        if looksLikeMove { score += 10 }
        if looksLikeMove && isStandalonePort { score += 20 }
        if transport == .usb { score += 5 }
        return score
    }
}

/// 自動選択ロジック（テスト可能な純粋関数）。
enum MIDIDestinationResolver {
    /// - preferred が指定されていればそれだけを探す（uniqueID → 名前の順）。見つからなければ nil（勝手に別機器へ送らない）。
    /// - preferred が nil（AUTO）ならMoveらしきポート、無ければUSBポートを選ぶ。どちらも無ければ nil。
    static func resolve(preferred: MIDIDestinationIdentity?,
                        candidates: [MIDIDestinationInfo]) -> MIDIDestinationInfo? {
        if let preferred {
            return candidates.first { $0.uniqueID == preferred.uniqueID && !$0.isOffline }
                ?? candidates.first { $0.name == preferred.name && !$0.isOffline }
        }
        let best = candidates.filter { $0.autoScore >= 5 }.max { $0.autoScore < $1.autoScore }
        return best
    }
}

enum MIDIConnectionState: Equatable {
    case unavailable(String)          // Core MIDI 初期化失敗
    case searching                    // AUTOで候補なし
    case waiting(String)              // 手動選択した機器が見つからない
    case connected(MIDIDestinationInfo)

    var isConnected: Bool { if case .connected = self { return true } else { return false } }
}

/// どのコントロールの送信か（間引き状態をコントロールごとに分けるためのキー）。
enum ControlID: Hashable {
    case knob(Int)
    case padX(Int)
    case padY(Int)
    /// XYパッドセット横のフェーダー（セット番号）
    case fader(Int)
    case test
}

enum SendMode {
    case continuous  // ドラッグ中（重複抑制＋60Hz間引き）
    case final       // タッチ終了（即時・重複のみ抑制）
    case force       // SEND等（必ず送る）
}

// MARK: - Log

/// 低コストなリングバッファログ。送信スレッドから追記、UIは定期的に読み出すだけ。
/// SwiftUIの監視対象にしないので、送信のたびに画面が再描画されることはない。
final class MIDILog: @unchecked Sendable {
    struct Entry: Identifiable {
        let id: UInt64
        let time: Date
        let text: String
        let isError: Bool
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var nextID: UInt64 = 0
    private let capacity: Int
    private var _enabled = true
    private(set) var sentCount: UInt64 = 0
    private(set) var droppedCount: UInt64 = 0

    init(capacity: Int = 300) { self.capacity = capacity }

    var isEnabled: Bool {
        get { lock.withLock { _enabled } }
        set { lock.withLock { _enabled = newValue } }
    }

    func recordSent(_ text: @autoclosure () -> String) {
        lock.lock(); defer { lock.unlock() }
        sentCount &+= 1
        guard _enabled else { return }
        appendLocked(text(), isError: false)
    }

    func recordDropped(_ text: @autoclosure () -> String) {
        lock.lock(); defer { lock.unlock() }
        droppedCount &+= 1
        guard _enabled else { return }
        appendLocked(text(), isError: true)
    }

    func note(_ text: String, isError: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        appendLocked(text, isError: isError)
    }

    func snapshot(last n: Int = .max) -> [Entry] {
        lock.withLock { Array(entries.suffix(n)) }
    }

    var counters: (sent: UInt64, dropped: UInt64) { lock.withLock { (sentCount, droppedCount) } }

    func clear() {
        lock.withLock { entries.removeAll(); sentCount = 0; droppedCount = 0 }
    }

    private func appendLocked(_ text: String, isError: Bool) {
        nextID &+= 1
        entries.append(Entry(id: nextID, time: Date(), text: text, isError: isError))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }
}

// MARK: - Send engine

/// 実際の送信関数。テストでは差し替える。戻り値は OSStatus (noErr=0 で成功)。
typealias MIDIOutputFunction = (_ message: ControlChange, _ endpoint: MIDIEndpointRef) -> OSStatus

/// 送信キュー上でのみ状態を触るエンジン。
final class MIDISendEngine: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.oleole.move.midi-send", qos: .userInteractive)
    let log: MIDILog
    private let output: MIDIOutputFunction
    private let minInterval: TimeInterval

    // ↓ すべて queue 上でのみアクセス
    private var endpoint: MIDIEndpointRef = 0
    private var endpointName = ""
    private var throttles: [ControlID: CCThrottle] = [:]

    init(log: MIDILog, minInterval: TimeInterval = 1.0 / 60.0, output: @escaping MIDIOutputFunction) {
        self.log = log
        self.minInterval = minInterval
        self.output = output
    }

    /// 接続先を変更（0 = 送信停止）。間引き状態をリセットし、再接続後は必ず再送されるようにする。
    func setEndpoint(_ endpoint: MIDIEndpointRef, name: String) {
        queue.async {
            self.endpoint = endpoint
            self.endpointName = name
            for key in self.throttles.keys { self.throttles[key]?.reset() }
        }
    }

    func submit(_ message: ControlChange, for id: ControlID, mode: SendMode) {
        queue.async { self.handle(message, id: id, mode: mode) }
    }

    /// テスト用：キューに積まれた処理の完了を待つ。
    func waitUntilIdle() { queue.sync {} }

    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func handle(_ message: ControlChange, id: ControlID, mode: SendMode) {
        var t = throttles[id] ?? CCThrottle(minInterval: minInterval)
        let now = Self.now()
        switch mode {
        case .continuous:
            switch t.submit(message, now: now) {
            case .send(let m):
                throttles[id] = t
                transmit(m, id: id)
            case .schedule(let at):
                throttles[id] = t
                let delay = max(0, at - now)
                queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.flush(id: id) }
            case .none:
                throttles[id] = t
            }
        case .final:
            let m = t.final(message, now: now)
            throttles[id] = t
            if let m { transmit(m, id: id) }
        case .force:
            let m = t.force(message, now: now)
            throttles[id] = t
            transmit(m, id: id)
        }
    }

    private func flush(id: ControlID) {
        guard var t = throttles[id] else { return }
        let m = t.flushPending(now: Self.now())
        throttles[id] = t
        if let m { transmit(m, id: id) }
    }

    private func transmit(_ m: ControlChange, id: ControlID) {
        guard endpoint != 0 else {
            // 接続断：安全に送信停止。再接続後に送れるよう「送信済み」記憶を消す。
            throttles[id]?.reset()
            log.recordDropped("DROP  \(m.debugDescription)  (no destination)")
            return
        }
        let status = output(m, endpoint)
        if status == noErr {
            log.recordSent("TX    \(m.debugDescription)")
        } else {
            throttles[id]?.reset()
            log.recordDropped("ERR   \(m.debugDescription)  OSStatus \(status)")
        }
    }
}

// MARK: - MIDIManager

@Observable
@MainActor
final class MIDIManager {
    private(set) var destinations: [MIDIDestinationInfo] = []
    private(set) var state: MIDIConnectionState = .searching
    /// nil = AUTO（Moveらしきポート優先）
    private(set) var preferred: MIDIDestinationIdentity?
    private(set) var loopbackEnabled = false

    @ObservationIgnored let log = MIDILog()
    @ObservationIgnored private(set) var engine: MIDISendEngine!
    @ObservationIgnored var onPreferenceChanged: (() -> Void)?
    /// 診断ファイルに追記する他機能の状態（Mirror 等）
    @ObservationIgnored var diagnosticsExtra: (() -> String)?

    @ObservationIgnored private var client: MIDIClientRef = 0
    @ObservationIgnored private var outPort: MIDIPortRef = 0
    @ObservationIgnored private var loopbackEndpoint: MIDIEndpointRef = 0

    static let loopbackName = "OleOle Loopback (Test)"

    init(preferred: MIDIDestinationIdentity?) {
        self.preferred = preferred
        setUpClient()
        // 出力ポートは生成後不変なので値でキャプチャし、送信キューからMainActorに触れない。
        let port = outPort
        engine = MIDISendEngine(log: log) { message, endpoint in
            guard port != 0 else { return OSStatus(kMIDIInvalidPort) }
            return MIDIManager.send(message, port: port, to: endpoint)
        }
        refreshDestinations()
    }

    // MARK: Public API

    func send(_ message: ControlChange, for id: ControlID, mode: SendMode) {
        engine.submit(message, for: id, mode: mode)
    }

    func select(_ identity: MIDIDestinationIdentity?) {
        preferred = identity
        resolveActive()
        onPreferenceChanged?()
    }

    func rescan() {
        log.note("— rescan —")
        refreshDestinations()
    }

    func setLogEnabled(_ enabled: Bool) { log.isEnabled = enabled }

    /// 自分自身への仮想Destination。ハードウェア無しで送信バイト列を確認する診断用。
    func setLoopback(_ enabled: Bool) {
        guard enabled != loopbackEnabled, client != 0 else { return }
        if enabled {
            var ep: MIDIEndpointRef = 0
            let log = self.log
            let status = MIDIDestinationCreateWithProtocol(client, Self.loopbackName as CFString,
                                                           ._1_0, &ep) { eventList, _ in
                Self.decodeReceived(eventList, into: log)
            }
            if status == noErr {
                loopbackEndpoint = ep
                loopbackEnabled = true
            } else {
                log.note("Loopback create failed: \(status)", isError: true)
            }
        } else {
            if loopbackEndpoint != 0 { MIDIEndpointDispose(loopbackEndpoint) }
            loopbackEndpoint = 0
            loopbackEnabled = false
        }
        refreshDestinations()
    }

    // MARK: Core MIDI setup

    private func setUpClient() {
        var c: MIDIClientRef = 0
        let status = MIDIClientCreateWithBlock("OleOleMoveController" as CFString, &c) { [weak self] notification in
            let messageID = notification.pointee.messageID
            // 抜き差し・構成変更で再列挙する
            switch messageID {
            case .msgSetupChanged, .msgObjectAdded, .msgObjectRemoved, .msgPropertyChanged:
                DispatchQueue.main.async { self?.refreshDestinations() }
            default:
                break
            }
        }
        guard status == noErr else {
            state = .unavailable("MIDIClientCreate failed (\(status))")
            log.note("MIDIClientCreate failed: \(status)", isError: true)
            return
        }
        client = c

        var p: MIDIPortRef = 0
        let portStatus = MIDIOutputPortCreate(client, "OleOle Out" as CFString, &p)
        guard portStatus == noErr else {
            state = .unavailable("MIDIOutputPortCreate failed (\(portStatus))")
            log.note("MIDIOutputPortCreate failed: \(portStatus)", isError: true)
            return
        }
        outPort = p
    }

    func refreshDestinations() {
        let count = MIDIGetNumberOfDestinations()
        var list: [MIDIDestinationInfo] = []
        for i in 0..<count {
            let ep = MIDIGetDestination(i)
            guard ep != 0 else { continue }
            list.append(Self.describe(ep))
        }
        if list != destinations { destinations = list }
        resolveActive()
        writeDiagnostics()
    }

    // MARK: Diagnostics

    /// Documents/midi-diagnostics.txt に、iPadから見えているMIDI機器と直近の送信ログを書き出す。
    /// 実機で「Moveが見えているか」「送信が成功しているか」を確認するため
    /// （Mac から `xcrun devicectl device copy from --domain-type appDataContainer` で取得できる）。
    func writeDiagnostics() {
        var lines: [String] = []
        lines.append("== OleOle Move Controller MIDI diagnostics \(Date()) ==")
        lines.append("state: \(state)")
        lines.append("preferred: \(preferred.map { "\($0.name) (\($0.uniqueID))" } ?? "AUTO")")
        lines.append("")
        lines.append("-- devices (MIDIGetNumberOfDevices = \(MIDIGetNumberOfDevices())) --")
        for i in 0..<MIDIGetNumberOfDevices() {
            let dev = MIDIGetDevice(i)
            let off = Self.intProperty(dev, kMIDIPropertyOffline)
            lines.append("device[\(i)] name='\(Self.stringProperty(dev, kMIDIPropertyName))' mfr='\(Self.stringProperty(dev, kMIDIPropertyManufacturer))' model='\(Self.stringProperty(dev, kMIDIPropertyModel))' driver='\(Self.stringProperty(dev, kMIDIPropertyDriverOwner))' offline=\(off)")
            for e in 0..<MIDIDeviceGetNumberOfEntities(dev) {
                let ent = MIDIDeviceGetEntity(dev, e)
                lines.append("  entity[\(e)] '\(Self.stringProperty(ent, kMIDIPropertyName))' sources=\(MIDIEntityGetNumberOfSources(ent)) destinations=\(MIDIEntityGetNumberOfDestinations(ent))")
            }
        }
        lines.append("")
        lines.append("-- destinations (\(destinations.count)) --")
        for d in destinations {
            lines.append("dest '\(d.name)' id=\(d.uniqueID) mfr='\(d.manufacturer)' model='\(d.model)' driver='\(d.driverOwner)' transport=\(d.transport.rawValue) offline=\(d.isOffline) move=\(d.looksLikeMove)")
        }
        if let extra = diagnosticsExtra?() {
            lines.append("")
            lines.append(extra)
        }
        lines.append("")
        let c = log.counters
        lines.append("-- log (sent \(c.sent), dropped \(c.dropped)) --")
        for e in log.snapshot(last: 120) {
            lines.append("\(e.time.formatted(date: .omitted, time: .standard))  \(e.text)")
        }
        let text = lines.joined(separator: "\n") + "\n"
        DispatchQueue.global(qos: .utility).async {
            guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            try? text.write(to: dir.appendingPathComponent("midi-diagnostics.txt"), atomically: true, encoding: .utf8)
        }
    }

    private func resolveActive() {
        guard client != 0, outPort != 0 else { return }
        let target = MIDIDestinationResolver.resolve(preferred: preferred, candidates: destinations)
        let newState: MIDIConnectionState
        if let target {
            newState = .connected(target)
        } else if let preferred {
            newState = .waiting(preferred.name)
        } else {
            newState = .searching
        }
        guard newState != state else { return }

        let previous = state
        state = newState
        switch newState {
        case .connected(let info):
            engine.setEndpoint(info.endpoint, name: info.name)
            log.note("CONNECTED  \(info.name) [\(info.transport.rawValue)]")
        default:
            engine.setEndpoint(0, name: "")
            if case .connected(let old) = previous {
                log.note("DISCONNECTED  \(old.name) — sending stopped", isError: true)
            }
        }
    }

    // MARK: Helpers

    nonisolated private static func send(_ message: ControlChange, port: MIDIPortRef,
                                         to endpoint: MIDIEndpointRef) -> OSStatus {
        var eventList = MIDIEventList()
        var word = message.umpWord()
        let packet = MIDIEventListInit(&eventList, ._1_0)
        _ = MIDIEventListAdd(&eventList, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &word)
        guard eventList.numPackets == 1 else { return OSStatus(kMIDIMessageSendErr) }
        return MIDISendEventList(port, endpoint, &eventList)
    }

    nonisolated private static func decodeReceived(_ list: UnsafePointer<MIDIEventList>, into log: MIDILog) {
        for packet in list.unsafeSequence() {
            let count = Int(packet.pointee.wordCount)
            withUnsafeBytes(of: packet.pointee.words) { raw in
                let words = raw.bindMemory(to: UInt32.self)
                for i in 0..<min(count, words.count) {
                    let word = words[i]
                    guard (word >> 28) & 0xF == 0x2 else { continue }
                    let status = UInt8((word >> 16) & 0xFF)
                    let d1 = UInt8((word >> 8) & 0xFF)
                    let d2 = UInt8(word & 0xFF)
                    log.note(String(format: "RX    loopback  [%02X %02X %02X]", status, d1, d2))
                }
            }
        }
    }

    nonisolated private static func stringProperty(_ obj: MIDIObjectRef, _ key: CFString) -> String {
        var cf: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(obj, key, &cf) == noErr, let s = cf?.takeRetainedValue() else { return "" }
        return s as String
    }

    nonisolated private static func intProperty(_ obj: MIDIObjectRef, _ key: CFString) -> Int32 {
        var v: Int32 = 0
        MIDIObjectGetIntegerProperty(obj, key, &v)
        return v
    }

    nonisolated private static func describe(_ ep: MIDIEndpointRef) -> MIDIDestinationInfo {
        let display = stringProperty(ep, kMIDIPropertyDisplayName)
        let name = display.isEmpty ? stringProperty(ep, kMIDIPropertyName) : display
        var manufacturer = stringProperty(ep, kMIDIPropertyManufacturer)
        var model = stringProperty(ep, kMIDIPropertyModel)
        var driver = ""
        var entity: MIDIEntityRef = 0
        var device: MIDIDeviceRef = 0
        let hasEntity = MIDIEndpointGetEntity(ep, &entity) == noErr && entity != 0
        if hasEntity, MIDIEntityGetDevice(entity, &device) == noErr, device != 0 {
            driver = stringProperty(device, kMIDIPropertyDriverOwner)
            if manufacturer.isEmpty { manufacturer = stringProperty(device, kMIDIPropertyManufacturer) }
            if model.isEmpty { model = stringProperty(device, kMIDIPropertyModel) }
        }
        let d = driver.lowercased()
        let transport: MIDITransport
        if !hasEntity { transport = .virtual }
        else if d.contains("usb") { transport = .usb }
        else if d.contains("rtp") || d.contains("network") { transport = .network }
        else if d.contains("bluetooth") || d.contains("ble") { transport = .bluetooth }
        else { transport = .other }

        return MIDIDestinationInfo(endpoint: ep,
                                   uniqueID: intProperty(ep, kMIDIPropertyUniqueID),
                                   name: name.isEmpty ? "Unnamed" : name,
                                   manufacturer: manufacturer,
                                   model: model,
                                   driverOwner: driver,
                                   transport: transport,
                                   isOffline: intProperty(ep, kMIDIPropertyOffline) != 0)
    }
}
