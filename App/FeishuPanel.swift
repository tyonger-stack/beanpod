import SwiftUI

/// 设备页里的「飞书妙记」卡片（设计稿 design/ui/ui_feishu.png）。逻辑在 FeishuSync.swift。
struct FeishuPanel: View {
    @Environment(BeanStore.self) private var store
    @Environment(Navigator.self) private var nav
    private var sync: FeishuSync { FeishuSync.shared }
    @State private var showAll = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                header
                switch sync.link {
                case .noTool:
                    hint(String(localized: "这台 Mac 没装飞书命令行工具 lark-cli。在终端里运行 npm install -g @larksuite/cli，再运行 lark-cli config init 和 lark-cli auth login --domain minutes 授权后回来点「现在检查」。"))
                case .notLoggedIn:
                    hint(String(localized: "还没授权密盒助手读取你的飞书妙记。在终端里运行 lark-cli auth login --domain minutes，在浏览器里确认后回来点「现在检查」。"))
                case .failed(let why):
                    hint(String(localized: "没连上飞书：\(why)"))
                default:
                    list
                }
                actions
                if sync.audioDenied {
                    Text("飞书没给音频：你的飞书应用还没开通「导出妙记音视频」权限，先拉回的是飞书的文字稿。开通后再拉，就能拿到音频、由密盒助手自己转写。")
                        .font(.caption).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
                }
                Divider().overlay(Theme.warm200.opacity(0.6))
                Text("拉回来的录音来源标成「飞书」。有音频的由密盒助手自己转写整理；拿不到音频时先用飞书的文字稿。")
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { if sync.link == .unknown { await sync.check() } }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("飞").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.warm700)
                .frame(width: 40, height: 40).background(Theme.warm100, in: .rect(cornerRadius: Theme.Radius.card))
            VStack(alignment: .leading, spacing: 4) {
                Text("飞书妙记").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.warm900)
                Text("手机上的设备配套 App 把录音同步到飞书后，密盒上就没有了。密盒助手从飞书把它们拉回来。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 8) {
                Text(stateText).font(.caption).foregroundStyle(.secondary)
                Toggle("自动同步", isOn: Bindable(sync).auto)
                    .toggleStyle(.switch).controlSize(.small).tint(Theme.accent)
                    .help("开着时每 30 分钟查一次，新上传的妙记自动拉回来")
                    .disabled(sync.link != .ready)
            }
            .fixedSize()
        }
    }

    private var stateText: String {
        switch sync.link {
        case .ready: String(localized: "已连接 · 你的飞书账号")
        case .checking: String(localized: "正在查…")
        case .noTool, .notLoggedIn: String(localized: "还没连上")
        case .failed: String(localized: "出了点问题")
        case .unknown: ""
        }
    }

    private var shown: [FeishuSync.Minute] {
        // 默认只看新的和最近的；已经在豆仓、不要了的折起来
        if showAll { return sync.minutes }
        let fresh = sync.minutes.filter { m in
            let st = sync.status(of: m)
            if case .inLibrary = st { return false }
            if st == .removed { return false }
            return st != .skipped
        }
        return Array((fresh.isEmpty ? sync.minutes : fresh).prefix(8))
    }

    @ViewBuilder private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(listTitle).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                if sync.minutes.count > shown.count || showAll {
                    Button(showAll ? "只看新的" : "全部 \(sync.minutes.count) 条") { showAll.toggle() }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(Theme.accent)
                }
            }
            .padding(.bottom, 6)
            if sync.minutes.isEmpty, sync.link == .ready {
                Text("最近 30 天的飞书妙记里没有录音。").font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
            }
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, m in
                if i > 0 { Divider().overlay(Theme.warm200.opacity(0.6)) }
                row(m)
            }
        }
    }

    private var listTitle: String {
        guard let t = sync.lastChecked else { return String(localized: "最近的妙记") }
        let ago = Int(Date.now.timeIntervalSince(t) / 60)
        return ago < 1 ? String(localized: "最近的妙记 · 上次检查刚刚") : String(localized: "最近的妙记 · 上次检查 \(ago) 分钟前")
    }

    private func row(_ m: FeishuSync.Minute) -> some View {
        let st = sync.status(of: m)
        let pickable = st == .new || st == .skipped || { if case .failed = st { return true }; return false }()
        return HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { pickable && sync.picked.contains(m.id) },
                                     set: { on in if on { sync.picked.insert(m.id) } else { sync.picked.remove(m.id) } }))
                .toggleStyle(.checkbox).labelsHidden().disabled(!pickable)
                .accessibilityLabel("拉回「\(m.title)」")
            VStack(alignment: .leading, spacing: 2) {
                Text(m.title).font(.body.weight(.medium)).foregroundStyle(Theme.warm900).lineLimit(1)
                Text(meta(m)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            switch st {
            case .new:
                Text("新的").font(.caption.weight(.medium)).foregroundStyle(Theme.accent)
                    .padding(.horizontal, 8).padding(.vertical, 3).background(Theme.accent.opacity(0.12), in: .capsule)
            case .inLibrary(let id):
                Button { nav.route = .all; nav.selection = id } label: { Label("已在密盒助手", systemImage: "checkmark") }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary).help("打开这条录音")
            case .removed:
                Text("拉回后删掉了").font(.caption).foregroundStyle(.tertiary).help("在密盒助手里删掉过，不会再自动拉回")
            case .skipped:
                Text("没要").font(.caption).foregroundStyle(.tertiary)
            case .pulling:
                ProgressView().controlSize(.small)
            case .failed(let why):
                Text("没拉成").font(.caption).foregroundStyle(Theme.amber).help(why)
            }
            if let url = URL(string: m.url) {
                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.plain).foregroundStyle(Theme.warm400).help("在飞书里打开").accessibilityLabel("在飞书里打开")
            }
        }
        .padding(.vertical, 9)
    }

    /// 录音豆 App 的默认标题里有录音时间，用它；否则写上传时间
    private func meta(_ m: FeishuSync.Minute) -> String {
        let f = Date.FormatStyle.dateTime.month().day().hour().minute()
        let when = m.recorded.map { $0.formatted(f) } ?? m.uploaded.map { String(localized: "\($0.formatted(f)) 上传") } ?? ""
        let d = Int(m.duration.rounded())
        let len = d >= 3600 ? String(localized: "\(d / 3600) 小时 \(d % 3600 / 60) 分钟") : d >= 60 ? String(localized: "\(d / 60) 分钟") : String(localized: "\(d) 秒")
        return [when, len].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var toPull: [String] {
        sync.minutes.filter { m in
            guard sync.picked.contains(m.id) else { return false }
            let st = sync.status(of: m)
            if case .inLibrary = st { return false }
            if st == .removed { return false }
            return st != .pulling
        }.map(\.id)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button(toPull.isEmpty ? "没有要拉回的" : "拉回 \(toPull.count) 条") {
                let ids = toPull
                Task { await sync.pull(ids, skipRest: true) }
            }
            .buttonStyle(.glassProminent).tint(Theme.accent)
            .disabled(toPull.isEmpty || !sync.pulling.isEmpty || sync.link != .ready)
            if !sync.textOnlyImports.isEmpty {
                Button("补上音频（\(sync.textOnlyImports.count) 条）") { Task { await sync.fillAudio() } }
                    .buttonStyle(.glass)
                    .help("之前没有音频权限、只拉回了文字稿的，现在把音频下下来重新转写")
                    .disabled(!sync.pulling.isEmpty || sync.link != .ready)
            }
            Button("现在检查") { Task { await sync.check() } }
                .buttonStyle(.glass)
                .disabled(sync.link == .checking || !sync.pulling.isEmpty)
            if sync.link == .ready, !sync.newOnes.isEmpty {
                Text("不想要的取消勾选，之后不会再问。").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
}
