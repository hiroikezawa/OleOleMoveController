//
//  ConfigurationStore.swift
//  OleOleMoveController
//
//  AppConfiguration を JSON にして UserDefaults に保存する。
//  ドラッグ中は値が毎フレーム変わるので、保存はデバウンスしてメインスレッドの負荷を避ける。
//

import Foundation

final class ConfigurationStore {
    static let storageKey = "OleOleMoveController.configuration.v1"

    private let defaults: UserDefaults
    private let key: String
    private var pendingSave: DispatchWorkItem?
    private let debounce: TimeInterval

    init(defaults: UserDefaults = .standard,
         key: String = ConfigurationStore.storageKey,
         debounce: TimeInterval = 0.6) {
        self.defaults = defaults
        self.key = key
        self.debounce = debounce
    }

    func load() -> AppConfiguration {
        guard let data = defaults.data(forKey: key) else { return .default }
        do {
            return try JSONDecoder().decode(AppConfiguration.self, from: data)
        } catch {
            NSLog("[Config] decode failed, using defaults: \(error)")
            return .default
        }
    }

    /// 少し待ってから保存。連続呼び出しは最後の1回にまとめる。
    func scheduleSave(_ provider: @escaping () -> AppConfiguration) {
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.saveNow(provider())
        }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    /// バックグラウンド移行時など、即時保存。
    func saveNow(_ configuration: AppConfiguration) {
        pendingSave?.cancel()
        pendingSave = nil
        do {
            let data = try JSONEncoder().encode(configuration)
            defaults.set(data, forKey: key)
        } catch {
            NSLog("[Config] encode failed: \(error)")
        }
    }

    func reset() {
        pendingSave?.cancel()
        defaults.removeObject(forKey: key)
    }
}
