import AVFoundation
import CoreBluetooth
import CoreGraphics
import SwiftUI
import UserNotifications

/// 上手引导（设计稿 design/ui/ui_onboarding.png）：第一次打开时出现，左边步骤栏、右边一步一页。
/// 欢迎 → 连接录音豆 → 转写模型 → 整理纪要的模型 → 权限 → 更多功能。每一步都能跳过，
/// 以后在菜单栏「帮助」→「上手引导」里还能再打开。
struct WelcomeView: View {
    @Environment(BeanStore.self) private var store
    @Environment(Navigator.self) private var nav
    @Environment(Dictation.self) private var dictation
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(Connector.self) private var connector

    enum Step: Int, CaseIterable, Identifiable {
        case welcome, device, asr, analysis, permissions, more
        var id: Int { rawValue }
        var name: String {
            switch self {
            case .welcome: String(localized: "欢迎")
            case .device: String(localized: "连接密盒")
            case .asr: String(localized: "转写模型")
            case .analysis: String(localized: "整理纪要的模型")
            case .permissions: String(localized: "权限")
            case .more: String(localized: "更多功能")
            }
        }
    }

    @State private var step: Step = .welcome
    /// 走过的步骤（用来在步骤栏里标「跳过了」）
    @State private var seen: Set<Step> = [.welcome]
    @State private var perms = Permissions()

    var body: some View {
        HStack(spacing: 0) {
            rail
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    page.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 8)
                }
                .scrollBounceBehavior(.basedOnSize)
                footer
            }
            .padding(32)
        }
        .frame(width: 860, height: 600)
        .onAppear { store.restorePausedDownloads(); store.refreshASRAvailability(); perms.refresh() }
        .task {
            await connector.refresh()
            // 在系统设置里开好权限回来，这里自己变成「已开」
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                perms.refresh()
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 1), value: step)
    }

    // MARK: 步骤栏

    private var rail: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                DevicePhotoView().frame(width: 56, height: 56).accessibilityHidden(true)
                Text("密盒助手").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(Theme.warm900)
            }
            .padding(.bottom, 18)
            ForEach(Step.allCases) { s in
                Button { go(s) } label: { railRow(s) }.buttonStyle(.plain)
            }
            Spacer()
            Button("跳过引导") { finish() }.buttonStyle(.plain).foregroundStyle(.secondary).font(.callout)
        }
        .padding(20)
        .frame(width: 236, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(Theme.warm100)
    }

    private func railRow(_ s: Step) -> some View {
        let isDone = done(s), current = s == step
        return HStack(spacing: 12) {
            ZStack {
                Circle().fill(isDone || current ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.clear)).frame(width: 26, height: 26)
                Circle().strokeBorder(isDone || current ? .clear : Theme.warm400, lineWidth: 1.5).frame(width: 26, height: 26)
                if isDone && !current {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(s.rawValue + 1)").font(.system(size: 13, weight: .semibold)).foregroundStyle(current ? .white : Theme.warm500)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(s.name).font(.system(size: 14, weight: current ? .semibold : .regular)).foregroundStyle(Theme.warm900)
                if !isDone, !current, seen.contains(s) {
                    Text("跳过了").font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(current ? Theme.accent.opacity(0.12) : .clear, in: .rect(cornerRadius: Theme.Radius.card))
        .contentShape(.rect)
        .accessibilityLabel(isDone ? String(localized: "第 \(s.rawValue + 1) 步：\(s.name)，已完成") : String(localized: "第 \(s.rawValue + 1) 步：\(s.name)"))
    }

    private func done(_ s: Step) -> Bool {
        switch s {
        case .welcome: seen.count > 1
        case .device: store.link == .ready || store.card.link == .ready
        case .asr: store.asrAvailable
        case .analysis: store.analysisAvailable
        case .permissions: perms.missing.isEmpty || (seen.contains(.more) && perms.essentialOK)
        case .more: false
        }
    }

    private func go(_ s: Step) { step = s; seen.insert(s) }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "welcomed")
        dismiss()
    }

    // MARK: 底部按钮

    private var footer: some View {
        HStack {
            Spacer()
            if step != .welcome {
                Button("上一步") { go(Step(rawValue: step.rawValue - 1)!) }
                    .buttonStyle(.glass).controlSize(.large)
            }
            if let next = Step(rawValue: step.rawValue + 1) {
                Button(step == .welcome ? "开始准备" : "下一步") { go(next) }
                    .buttonStyle(.glassProminent).tint(Theme.accent).controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("开始使用") { finish() }
                    .buttonStyle(.glassProminent).tint(Theme.accent).controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.top, 16)
    }

    // MARK: 每一页

    @ViewBuilder private var page: some View {
        switch step {
        case .welcome: welcome
        case .device: device
        case .asr: asr
        case .analysis: analysis
        case .permissions: permissions
        case .more: more
        }
    }

    private func heading(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 30, weight: .bold)).foregroundStyle(Theme.warm900)
            Text(detail).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 20)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading(String(localized: "欢迎来到密盒助手"), String(localized: "密盒负责听，密盒助手负责把它变成文字和纪要。接下来几步把要准备的东西过一遍，几分钟就好；每一步都能先跳过。"))
            VStack(spacing: 0) {
                feature("waveform", String(localized: "录完自动变成纪要"), String(localized: "连上密盒自动下载，在这台 Mac 上转成文字，整理出摘要、决定和待办。"))
                Divider().padding(.leading, 62)
                feature("lock", String(localized: "录音不出这台 Mac"), String(localized: "转写用本机模型；整理纪要可以用本机模型，也可以填你自己的云端模型。"))
                Divider().padding(.leading, 62)
                feature("square.stack.3d.up", String(localized: "一个地方管所有声音"), String(localized: "密盒、录音卡、Mac 自己录、导入的音频、视频链接、飞书妙记，都在这里，标着来源。"))
                Divider().padding(.leading, 62)
                feature("sparkles", String(localized: "AI 助手直接查"), String(localized: "Claude、Codex 这些助手连上后，可以直接问密盒助手里的录音、纪要和待办。"))
            }
            .padding(.vertical, 4)
            .panel(radius: Theme.Radius.panel)
        }
    }

    private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(Theme.warm600)
                .frame(width: 34, height: 34).background(Theme.warm100, in: .rect(cornerRadius: Theme.Radius.card))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).foregroundStyle(Theme.warm900)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private var device: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading(String(localized: "连接密盒"), String(localized: "把密盒放在 Mac 旁边，并确认已开机。密盒同一时间只能连一台设备：手机上的设备配套 App 连着的话，先关掉手机蓝牙。"))
            row(icon: "headphones", title: store.link == .ready ? String(localized: "\(store.displayDeviceName) 已连接") : String(localized: "密盒还没连上"),
                detail: store.link == .ready ? String(localized: "以后连上密盒，在外面录的都会自动同步过来。") : String(localized: "点「去连接」到设备页，找到它点一下就行。"),
                ok: store.link == .ready) {
                Button("去连接") { nav.route = .device; finish() }.buttonStyle(.glass)
            }
            .panel(radius: Theme.Radius.panel)
            Text("也支持得到 AI 录音卡（按公开协议实现，还没在实机上测过）。手机 App 已经把录音同步进飞书妙记的，可以在最后一步打开「飞书妙记同步」拉回来。")
                .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
        }
    }

    private var asr: some View {
        @Bindable var settings = store.settings
        return VStack(alignment: .leading, spacing: 0) {
            heading(String(localized: "下载转写模型"), String(localized: "本机转写在这台 Mac 上完成，录音不会上传。选择 Paraformer 或 Fun-ASR-Nano 会自动下载缺少的模型文件。"))
            Picker("本机转写模型", selection: $settings.localASRModel) {
                ForEach(AppSettings.LocalASRModel.allCases) { model in
                    Text(model.pickerTitle).tag(model)
                }
            }
            .pickerStyle(.segmented).labelsHidden().padding(.bottom, 12)
            .onChange(of: settings.localASRModel) { _, _ in store.localASRSelectionChanged() }
            row(icon: "text.bubble", title: store.asrAvailable ? String(localized: "转写模型已就绪") : settings.localASRModel.asrName,
                detail: store.localASRReadinessHint ?? String(localized: "新录音下载后会自动转成文字。"),
                ok: store.asrAvailable) {
                if let job = store.asrJob {
                    VStack(alignment: .trailing, spacing: 6) {
                        ProgressView(value: job.fraction).frame(width: 110)
                        Text("\(Int(job.fraction * 100))%").font(.callout).monospacedDigit().foregroundStyle(.secondary)
                        HStack {
                            switch job.state {
                            case .running: Button("暂停") { job.pause() }
                            case .paused: Button("继续") { job.start() }
                            case .failed: Button("重试") { job.start() }
                            case .verifying: ProgressView().controlSize(.small)
                            }
                            Button("取消") { job.cancel() }.disabled(job.state == .verifying)
                        }
                    }
                } else if !QwenASR.modelInstalled(selection: settings.localASRModel) {
                    Button("下载（\(settings.localASRModel.asrSize)）") { store.downloadASRModel() }.buttonStyle(.glass)
                } else if !store.asrAvailable {
                    ModelSettingsLink(title: String(localized: "检查运行程序"))
                }
            }
            .panel(radius: Theme.Radius.panel)
            Text("不想下载也可以：在 设置 → 模型 里填一个云端转写服务（比如小米 MiMo），用你自己的密钥。")
                .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
        }
    }

    private var analysis: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading(String(localized: "选一个整理纪要的模型"), String(localized: "把文字稿整理成摘要、决定、待办和重点。可以用本机模型（不联网），也可以填你自己的云端模型。这一步可以以后再做：没选的时候录音照样转成文字。"))
            row(icon: "doc.text.magnifyingglass", title: store.analysisAvailable ? String(localized: "已就绪") : String(localized: "还没选"),
                detail: store.analysisAvailable ? String(localized: "整理好的录音会出现在总览的「接下来要做的」里。") : String(localized: "在设置的「模型」里选择本机、密盒或云端服务。"),
                ok: store.analysisAvailable) {
                if let progress = store.llmDownload {
                    ProgressView(value: progress).frame(width: 110)
                    Text("\(Int(progress * 100))%").font(.callout).monospacedDigit().foregroundStyle(.secondary)
                } else {
                    Button("打开设置") { SettingsView.open(.models, with: openSettings) }.buttonStyle(.glass)
                }
            }
            .panel(radius: Theme.Radius.panel)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading(String(localized: "密盒助手需要的权限"), String(localized: "每一项都写了用来做什么。没开的点「去打开」，会直接跳到系统设置里对应的地方；开好回来这里会自动变成已开。"))
            VStack(spacing: 0) {
                ForEach(Array(Permissions.Kind.allCases.enumerated()), id: \.element) { i, k in
                    if i > 0 { Divider().padding(.leading, 62) }
                    row(icon: k.icon, title: k.name, detail: k.use, ok: perms.granted(k)) {
                        Button("去打开") { perms.request(k, dictation: dictation) }.buttonStyle(.glass)
                    }
                }
            }
            .panel(radius: Theme.Radius.panel)
            Text("不开也能用：没开的那项功能用不了，其它照常。")
                .font(.caption).foregroundStyle(.tertiary).padding(.top, 12)
        }
    }

    private var more: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading(String(localized: "更多功能（都是可选的）"), String(localized: "用得上再开。都可以以后在设置或设备页里打开。"))
            VStack(spacing: 0) {
                row(icon: "keyboard", title: String(localized: "语音输入"),
                    detail: store.settings.dictationEnabled ? String(localized: "已打开：按住\(Dictation.name(of: store.settings.dictationKey).components(separatedBy: " ").prefix(2).joined(separator: " "))说话，松开文字打进当前的软件。说过的话记在侧栏「语音输入」。")
                        : String(localized: "按住一个键对着密盒或麦克风说话，松开后文字直接打进当前的软件，像输入法一样。要「辅助功能」权限。"),
                    ok: store.settings.dictationEnabled) {
                    Button("去设置") { SettingsView.open(.dictation, with: openSettings) }.buttonStyle(.glass)
                }
                Divider().padding(.leading, 62)
                row(icon: "cloud", title: String(localized: "飞书妙记同步"),
                    detail: FeishuSync.shared.link == .ready ? String(localized: "已连上你的飞书。手机 App 同步走的录音会在设备页列出来，可以拉回密盒助手。")
                        : String(localized: "手机上的设备配套 App 先连上密盒的话，录音会被同步进飞书、密盒上就没有了。装好飞书命令行工具并授权后，密盒助手能把它们拉回来。"),
                    ok: FeishuSync.shared.link == .ready) {
                    Button("看步骤") { nav.route = .device; finish() }.buttonStyle(.glass)
                }
                if FeishuSync.shared.link != .ready {
                    VStack(alignment: .leading, spacing: 6) {
                        command("npm install -g @larksuite/cli")
                        command("lark-cli config init --new")
                        command("lark-cli auth login --domain minutes")
                    }
                    .padding(.leading, 62).padding(.trailing, 14).padding(.bottom, 12)
                }
                Divider().padding(.leading, 62)
                row(icon: "sparkles", title: String(localized: "连上 AI 助手"),
                    detail: connector.connectedCount > 0 ? String(localized: "已经连上 \(connector.connectedCount) 个。在它们那边就能直接问密盒助手里的内容。")
                        : String(localized: "Claude、Codex、OpenClaw、Grok Bot 都可以。连上后在它们那边就能直接问密盒助手里的录音和待办。"),
                    ok: connector.connectedCount > 0) {
                    Button("去连接") { openWindow(id: "connect") }.buttonStyle(.glass)
                }
            }
            .panel(radius: Theme.Radius.panel)
        }
        .task { if FeishuSync.shared.link == .unknown { await FeishuSync.shared.check() } }
    }

    /// 终端命令：等宽字、能选中、一键拷贝
    private func command(_ text: String) -> some View {
        HStack(spacing: 8) {
            Text(text).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.warm700).textSelection(.enabled)
            Spacer(minLength: 4)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                store.toast("doc.on.doc", String(localized: "已拷贝，粘到终端里运行"))
            } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.plain).foregroundStyle(Theme.warm500).help("拷贝").accessibilityLabel("拷贝命令")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.warm100, in: .rect(cornerRadius: Theme.Radius.card))
    }

    /// 一行：图标、名字、说明，右边是「已开/已就绪」或者一个按钮
    private func row<Trailing: View>(icon: String, title: String, detail: String, ok: Bool,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 17)).foregroundStyle(Theme.warm600)
                .frame(width: 36, height: 36).background(Theme.warm100, in: .rect(cornerRadius: Theme.Radius.card))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).foregroundStyle(Theme.warm900)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            if ok {
                HStack(spacing: 6) {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text("已开").font(.callout).foregroundStyle(Theme.warm700)
                }
                .fixedSize()
                .accessibilityLabel("已开")
            } else {
                HStack(spacing: 8) { trailing() }.fixedSize()
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }
}

/// 引导里的权限一览：每项现在开没开、怎么去开。
@MainActor @Observable
final class Permissions {
    enum Kind: CaseIterable {
        case bluetooth, microphone, screen, accessibility, notifications
        var name: String {
            switch self {
            case .bluetooth: String(localized: "蓝牙")
            case .microphone: String(localized: "麦克风")
            case .screen: String(localized: "屏幕与系统录音")
            case .accessibility: String(localized: "辅助功能")
            case .notifications: String(localized: "通知")
            }
        }
        var use: String {
            switch self {
            case .bluetooth: String(localized: "连接密盒和录音卡")
            case .microphone: String(localized: "用 Mac 自己录音")
            case .screen: String(localized: "录会议软件、视频里的电脑声音")
            case .accessibility: String(localized: "语音输入时把文字打进别的软件")
            case .notifications: String(localized: "录音整理好了、密盒连上了告诉你")
            }
        }
        var icon: String {
            switch self {
            case .bluetooth: "dot.radiowaves.left.and.right"
            case .microphone: "mic"
            case .screen: "display"
            case .accessibility: "accessibility"
            case .notifications: "bell"
            }
        }
        /// 系统设置里对应的那一页
        var settingsURL: URL? {
            let anchor: String
            switch self {
            case .bluetooth: anchor = "Privacy_Bluetooth"
            case .microphone: anchor = "Privacy_Microphone"
            case .screen: anchor = "Privacy_ScreenCapture"
            case .accessibility: anchor = "Privacy_Accessibility"
            case .notifications: return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
            }
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
        }
    }

    private var state: [Kind: Bool] = [:]
    private var notificationsAsked = false

    func granted(_ k: Kind) -> Bool { state[k] ?? false }
    var missing: [Kind] { Kind.allCases.filter { !granted($0) } }
    /// 蓝牙是必须的，其它看用不用得上
    var essentialOK: Bool { granted(.bluetooth) }

    func refresh() {
        state[.bluetooth] = CBManager.authorization == .allowedAlways
        state[.microphone] = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        state[.screen] = CGPreflightScreenCaptureAccess()
        state[.accessibility] = AXIsProcessTrusted()
        Task {
            let s = await UNUserNotificationCenter.current().notificationSettings()
            state[.notifications] = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
            notificationsAsked = s.authorizationStatus != .notDetermined
        }
    }

    /// 还没问过的先弹系统的询问；问过、被拒了的，直接打开系统设置那一页。
    func request(_ k: Kind, dictation: Dictation) {
        switch k {
        case .microphone where AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in Task { @MainActor in self.refresh() } }
        case .screen:
            if !CGRequestScreenCaptureAccess(), let url = k.settingsURL { NSWorkspace.shared.open(url) }
        case .accessibility:
            dictation.requestAccessibility()
            if let url = k.settingsURL { NSWorkspace.shared.open(url) }
        case .notifications where !notificationsAsked:
            Task {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                refresh()
            }
        default:
            if let url = k.settingsURL { NSWorkspace.shared.open(url) }
        }
    }
}
