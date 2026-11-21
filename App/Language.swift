import Foundation

/// 界面语言（设置 → 通用 → 语言）。界面文字都在 App/Localizable.xcstrings 里：中文是开发语言（也是默认），
/// 英文是翻译；以后加别的语言，只要在那个文件里补一列翻译、在这里加一项。
/// 切换写进这个 App 自己的 AppleLanguages，重新打开豆仓后生效。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, zhHans = "zh-Hans", en

    var id: String { rawValue }

    /// 选项上显示的名字：每种语言用它自己的写法，不跟着界面语言翻译
    var name: String {
        switch self {
        case .system: String(localized: "跟随系统")
        case .zhHans: "简体中文"
        case .en: "English"
        }
    }

    static var current: AppLanguage {
        guard let list = UserDefaults.standard.array(forKey: "AppleLanguages") as? [String],
              UserDefaults.standard.object(forKey: "beanpodLanguage") != nil,
              let first = list.first else { return .system }
        return first.hasPrefix("en") ? .en : first.hasPrefix("zh") ? .zhHans : .system
    }

    /// 写进这个 App 的语言偏好。「跟随系统」就把它删掉，交还给系统设置。
    func apply() {
        let d = UserDefaults.standard
        switch self {
        case .system:
            d.removeObject(forKey: "AppleLanguages")
            d.removeObject(forKey: "AppleLocale")
            d.removeObject(forKey: "beanpodLanguage")
        case .zhHans, .en:
            d.set([rawValue], forKey: "AppleLanguages")
            // 日期、星期的写法跟着地区设置走：只换语言的话，中文系统上英文界面里还会出现「11月14日 周六」。
            // 这里把这个 App 的地区语言一起换掉，国家/地区保持系统原来的
            let region = Locale.current.region?.identifier ?? (self == .en ? "US" : "CN")
            d.set(self == .en ? "en_\(region)" : "zh_Hans_\(region)", forKey: "AppleLocale")
            d.set(rawValue, forKey: "beanpodLanguage")
        }
    }

    /// 现在界面实际用的是不是英文（给模型提示词选语言等用）
    static var isEnglishUI: Bool {
        (Bundle.main.preferredLocalizations.first ?? "zh-Hans").hasPrefix("en")
    }
}

import AppKit
import SwiftUI

/// 设置 → 通用里的「语言」：跟随系统 / 简体中文 / English。改了以后提示重新打开豆仓。
struct LanguageSetting: View {
    @State private var choice = AppLanguage.current
    @State private var changed = false

    var body: some View {
        SettingsGroup(String(localized: "语言 · Language"),
                      footer: String(localized: "界面文字跟着这里变。")) {
            SettingRow(icon: "globe", title: String(localized: "界面语言"),
                       detail: changed ? String(localized: "重新打开密盒助手后生效。") : String(localized: "默认跟随系统；系统不是中文时显示英文。")) {
                HStack(spacing: 8) {
                    Picker("界面语言", selection: $choice) {
                        ForEach(AppLanguage.allCases) { Text($0.name).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    if changed {
                        Button("重新打开") { Self.relaunch() }
                    }
                }
            }
            NotesLanguageSetting()
        }
        .onChange(of: choice) { _, new in new.apply(); changed = true }
    }

    /// 退出后用 open 再打开自己
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"\(path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }
}

/// 设置 → 通用 → 语言里的「纪要语言」：跟随界面 / 简体中文 / English（写进 UserDefaults "notesLanguage"，Shared/Analyzer.swift 的 NotesLanguage 读它）
struct NotesLanguageSetting: View {
    @AppStorage("notesLanguage") private var value = "auto"

    var body: some View {
        SettingRow(icon: "text.bubble", title: String(localized: "纪要语言"),
                   detail: String(localized: "模型写纪要、标题、待办用的语言。之后整理的录音生效；已经整理过的可以「重新整理」。")) {
            Picker("纪要语言", selection: $value) {
                Text("跟随界面").tag("auto")
                Text(verbatim: "简体中文").tag("zh-Hans")
                Text(verbatim: "English").tag("en")
            }
            .labelsHidden().fixedSize()
        }
    }
}
