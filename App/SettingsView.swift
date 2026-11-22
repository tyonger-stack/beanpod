import SwiftUI

/// 设置窗口的五个页签共用一套窗口尺寸，超出一屏的内容在页签内滚动。
struct SettingsView: View {
    enum Pane: String { case general, dictation, models, vocabulary, connect }

    @Environment(BeanStore.self) private var store
    @AppStorage("settingsPane") private var pane = Pane.general
    @State private var paneHeight = SettingsWindowPosition.paneHeight(
        on: SettingsWindowPosition.pointerScreen ?? NSScreen.main
    )

    var body: some View {
        TabView(selection: $pane) {
            Tab("通用", systemImage: "gearshape", value: Pane.general) { GeneralPane() }
            Tab("语音输入", systemImage: "mic", value: Pane.dictation) { DictationPane() }
            Tab("模型", systemImage: "cpu", value: Pane.models) { ModelsPane() }
            Tab("词库", systemImage: "character.book.closed", value: Pane.vocabulary) { VocabularyPane() }
            Tab("连接", systemImage: "link", value: Pane.connect) { ConnectPane() }
        }
        .frame(width: 640, height: paneHeight)
        .background {
            SettingsWindowPosition { screen in paneHeight = SettingsWindowPosition.paneHeight(on: screen) }
        }
        .preferredColorScheme(store.settings.appearance.scheme)
        .onAppear { store.refreshASRAvailability() }
    }
}

private struct SettingsWindowPosition: NSViewRepresentable {
    var screenSelected: (NSScreen) -> Void

    static var pointerScreen: NSScreen? {
        NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
    }

    static func paneHeight(on screen: NSScreen?) -> CGFloat {
        max(360, min((screen?.visibleFrame.height ?? 900) - 150, 860))
    }

    func makeNSView(context: Context) -> PositionView {
        let view = PositionView()
        view.screenSelected = screenSelected
        return view
    }

    func updateNSView(_ nsView: PositionView, context: Context) {
        nsView.screenSelected = screenSelected
    }

    final class PositionView: NSView {
        private enum Placement {
            case awaitingOpen
            case centered(NSScreen)
            case userPositioned
        }

        private var placement = Placement.awaitingOpen
        private var positioning = false
        private var updateScheduled = false
        var screenSelected: ((NSScreen) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let notifications = NotificationCenter.default
            notifications.removeObserver(self)
            placement = .awaitingOpen
            guard let window else { return }
            notifications.addObserver(self, selector: #selector(opened), name: NSWindow.didBecomeKeyNotification, object: window)
            notifications.addObserver(self, selector: #selector(closed), name: NSWindow.willCloseNotification, object: window)
            notifications.addObserver(self, selector: #selector(resized), name: NSWindow.didResizeNotification, object: window)
            notifications.addObserver(self, selector: #selector(userMoved), name: NSWindow.willMoveNotification, object: window)
            notifications.addObserver(self, selector: #selector(userMoved), name: NSWindow.willStartLiveResizeNotification, object: window)
            if window.isVisible { opened() }
        }

        @objc private func opened() {
            guard case .awaitingOpen = placement else { return }
            guard let screen = SettingsWindowPosition.pointerScreen ?? window?.screen ?? NSScreen.main else { return }
            placement = .centered(screen)
            centerWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self, case let .centered(chosenScreen) = self.placement else { return }
                self.screenSelected?(chosenScreen)
            }
            resized()
        }

        @objc private func closed() {
            placement = .awaitingOpen
        }

        @objc private func userMoved() {
            guard !positioning else { return }
            placement = .userPositioned
        }

        @objc private func resized() {
            guard case .centered = placement, !updateScheduled else { return }
            updateScheduled = true
            // The shared viewport may change on opening the window on a different display.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.updateScheduled = false
                self.centerWindow()
            }
        }

        private func centerWindow() {
            guard let window, case let .centered(screen) = placement else { return }
            let visibleFrame = screen.visibleFrame
            let origin = NSPoint(x: visibleFrame.midX - window.frame.width / 2,
                                 y: visibleFrame.midY - window.frame.height / 2)
            guard window.frame.origin != origin else { return }
            positioning = true
            window.setFrameOrigin(origin)
            positioning = false
        }
    }
}

/// 「去设置」按钮：直接打开设置里的模型页。全应用里叫用户去设置的地方，缺的都是模型。
struct ModelSettingsLink: View {
    @Environment(\.openSettings) private var openSettings
    var title = String(localized: "去设置")

    var body: some View {
        Button(title) { SettingsView.open(.models, with: openSettings) }
    }
}

extension SettingsView {
    static func open(_ pane: Pane, with openSettings: OpenSettingsAction) {
        UserDefaults.standard.set(pane.rawValue, forKey: "settingsPane")
        openSettings()
    }
}

// MARK: 搭页面用的零件

private struct PaneFrame<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 22) { content }
                .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 26)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Backdrop())
    }
}

/// 一组设置：小标题、一张卡片、卡片下面的说明。卡片里每一行之间自动加分隔线。
struct SettingsGroup<Content: View, Accessory: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if title != nil || Accessory.self != EmptyView.self {
                HStack(spacing: 8) {
                    if let title { Text(title).font(.headline) }
                    Spacer(minLength: 0)
                    accessory
                }
                .padding(.horizontal, 4)
            }
            VStack(spacing: 0) {
                Group(subviews: content) { subviews in
                    ForEach(subviews) { sub in
                        sub.padding(.horizontal, 16).padding(.vertical, 11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if sub.id != subviews.last?.id { Divider().padding(.leading, 16) }
                    }
                }
            }
            .panel(radius: Theme.Radius.panel)
            if let footer {
                Text(footer).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            }
        }
    }
}

extension SettingsGroup where Accessory == EmptyView {
    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, footer: footer, accessory: { EmptyView() }, content: content)
    }
}

/// 一行设置：左边可选的小图标、标题和一行说明，右边是控件。
struct SettingRow<Trailing: View>: View {
    var icon: String?
    var title: String
    var detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let icon {
                Image(systemName: icon).font(.system(size: 17, weight: .regular)).foregroundStyle(.secondary)
                    .frame(width: 26)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}

/// 「已就绪」「还差一步」这种状态小牌子。
private struct StatusPill: View {
    var ok: Bool
    var text: String

    var body: some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .font(.callout.weight(.medium))
            .foregroundStyle(ok ? Theme.ok : Theme.amber)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background((ok ? Theme.ok : Theme.amber).opacity(0.14), in: .capsule)
    }
}

// MARK: 通用

private struct GeneralPane: View {
    @Environment(BeanStore.self) private var store

    var body: some View {
        @Bindable var settings = store.settings
        PaneFrame {
            SettingsGroup(String(localized: "外观")) {
                HStack(spacing: 12) {
                    ForEach(AppSettings.Appearance.allCases) { mode in
                        AppearanceTile(mode: mode, selected: settings.appearance == mode) { settings.appearance = mode }
                    }
                }
                .padding(.vertical, 5)
            }

            LanguageSetting()

            SettingsGroup(String(localized: "我是做什么的"), footer: String(localized: "职业决定整理纪要时更看重什么。场景（会议、访谈、销售……）是每条录音自动判断的，判断错了可以在录音页面改。")) {
                SettingRow(icon: "person.crop.circle", title: String(localized: "我的职业"), detail: settings.profession.focus) {
                    Picker("我的职业", selection: $settings.profession) {
                        ForEach(Profession.allCases) { Text($0.name).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }

            SettingsGroup(String(localized: "视频素材")) {
                VideoKeepSettings().padding(.vertical, 6)
            }

            SettingsGroup(String(localized: "录音的时候和录完之后")) {
                SettingRow(icon: "captions.bubble", title: String(localized: "边录边出字"), detail: String(localized: "录音时在舞台上实时显示文字。")) {
                    Toggle("边录边出字", isOn: $settings.liveTranscribe).labelsHidden().toggleStyle(.switch)
                }
                SettingRow(icon: "doc.on.clipboard", title: String(localized: "识别剪贴板里的视频链接"), detail: String(localized: "复制了抖音、B 站、YouTube 这些链接，切回密盒助手时提示一键导入。只看链接，不存剪贴板内容。")) {
                    Toggle("识别剪贴板里的视频链接", isOn: $settings.watchClipboard).labelsHidden().toggleStyle(.switch)
                }
                SettingRow(icon: "questionmark.bubble", title: String(localized: "录完先问一句留不留"), detail: String(localized: "录完弹一张小卡片，不要的话当场删掉，哪里都不留。十秒不理它就默认留着。")) {
                    Toggle("录完先问一句留不留", isOn: $settings.askKeep).labelsHidden().toggleStyle(.switch)
                }
                SettingRow(icon: "arrow.down.circle", title: String(localized: "自动从密盒下载"), detail: String(localized: "录完一条、或者重新连上密盒时，把还没下载的拉到这台 Mac 上。")) {
                    Toggle("自动从密盒下载", isOn: $settings.autoDownload).labelsHidden().toggleStyle(.switch)
                }
                SettingRow(icon: "wand.and.sparkles", title: String(localized: "自动转写并整理"), detail: String(localized: "下载后直接出文字稿、纪要和待办。")) {
                    Toggle("自动转写并整理", isOn: $settings.autoProcess).labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }
}

/// 外观的一个选项：一张小窗口缩略图加名字，选中的有琥珀色描边。
private struct AppearanceTile: View {
    var mode: AppSettings.Appearance
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                preview
                    .frame(height: 74)
                    .clipShape(.rect(cornerRadius: Theme.Radius.card))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
                HStack(spacing: 5) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
                    Text(mode.name).fontWeight(selected ? .semibold : .regular)
                }
                .font(.callout)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(.background.opacity(selected ? 0.9 : 0.4), in: .rect(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.separator), lineWidth: selected ? 2 : 0.5))
            .contentShape(.rect(cornerRadius: Theme.Radius.card))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var preview: some View {
        switch mode {
        case .light: MiniWindow(dark: false)
        case .dark: MiniWindow(dark: true)
        case .system:
            // 左半浅、右半深：跟着系统走
            ZStack {
                MiniWindow(dark: false)
                MiniWindow(dark: true).mask(alignment: .trailing) {
                    GeometryReader { geo in Rectangle().frame(width: geo.size.width / 2).frame(maxWidth: .infinity, alignment: .trailing) }
                }
            }
        }
    }
}

/// 豆仓窗口的缩略图：左边侧栏、红色录音键、右边几条内容。
private struct MiniWindow: View {
    var dark: Bool

    var body: some View {
        let ink = dark ? Color.white : Color.black
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(Theme.rec).frame(width: 30, height: 7)
                ForEach(0..<3, id: \.self) { _ in Capsule().fill(ink.opacity(0.22)).frame(width: 24, height: 4) }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxHeight: .infinity)
            .background(ink.opacity(0.06))
            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(ink.opacity(0.75)).frame(width: 52, height: 6)
                RoundedRectangle(cornerRadius: 4).fill(ink.opacity(0.1)).frame(height: 16)
                RoundedRectangle(cornerRadius: 4).fill(Theme.accent.opacity(0.55)).frame(width: 60, height: 16)
                Spacer(minLength: 0)
            }
            .padding(9)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(dark ? Theme.graphite : Theme.paper)
    }
}

// MARK: 语音输入

private struct DictationPane: View {
    @Environment(BeanStore.self) private var store
    @Environment(Dictation.self) private var dictation
    @State private var trusted = AXIsProcessTrusted()

    var body: some View {
        @Bindable var settings = store.settings
        let on = settings.dictationEnabled
        PaneFrame {
            SettingsGroup(footer: String(localized: "在任何 App 里按住你选的那个键，录下所选来源的声音，松开后文字出现在光标处。使用这台 Mac 的声音来源，无需连接密盒。")) {
                SettingRow(icon: "mic.fill", title: String(localized: "按住按键录音，松开输入文字"), detail: on ? String(localized: "已打开。按住「\(Dictation.name(of: settings.dictationKey))」试试。") : String(localized: "关着的时候，密盒助手不会监听任何按键。")) {
                    Toggle("语音输入", isOn: Binding(get: { settings.dictationEnabled }, set: {
                        settings.dictationEnabled = $0
                        dictation.refresh()
                        if $0, !AXIsProcessTrusted() { dictation.requestAccessibility() }
                    }))
                    .labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsGroup(String(localized: "声音来源"), footer: String(localized: "默认优先使用已连接的密盒。断开时使用所选的 Mac 音源。也可以在侧栏手动切换。")) {
                SettingRow(icon: store.sourceIcon, title: store.sourceName, detail: String(localized: "与侧栏的录音来源共用同一选择。")) {
                    EmptyView()
                }
            }

            SettingsGroup(String(localized: "怎么用")) {
                SettingRow(icon: "keyboard", title: String(localized: "按住这个键"), detail: dictation.recordingKey ? String(localized: "现在按下你想用的那个键…") : nil) {
                    Picker("按住这个键", selection: $settings.dictationKey) {
                        ForEach(Dictation.keys, id: \.code) { Text($0.name).tag($0.code) }
                        if !Dictation.keys.contains(where: { $0.code == settings.dictationKey }) {
                            Text(Dictation.name(of: settings.dictationKey)).tag(settings.dictationKey)
                        }
                    }
                    .labelsHidden().fixedSize()
                    Button(dictation.recordingKey ? "取消" : "换一个键…") {
                        dictation.recordingKey.toggle()
                        dictation.refresh()
                    }
                    .help("点一下，然后按下你想用的修饰键")
                }
                SettingRow(icon: "text.badge.checkmark", title: String(localized: "把口语理顺再输入"), detail: String(localized: "去掉嗯啊和重复，句子更通顺。要多等几秒。")) {
                    Toggle("把口语理顺再输入", isOn: $settings.dictationPolish).labelsHidden().toggleStyle(.switch)
                }
                SettingRow(icon: "keyboard", title: String(localized: "记下说过的话"), detail: String(localized: "打字的同时，把这句话记进侧栏的「语音输入」（声音 + 文字），能回听、拷贝、搜索。不进录音列表，也不做 AI 整理。")) {
                    Toggle("记下说过的话", isOn: $settings.dictationSave).labelsHidden().toggleStyle(.switch)
                }
                SettingRow(icon: "waveform.badge.minus", title: String(localized: "原声保留"), detail: String(localized: "到期只删声音，文字一直留着。")) {
                    Picker("原声保留", selection: $settings.dictationAudioDays) {
                        Text("7 天").tag(7); Text("30 天").tag(30); Text("90 天").tag(90); Text("一直留着").tag(0)
                    }
                    .labelsHidden().fixedSize()
                }
                .disabled(!settings.dictationSave)
                SettingRow(icon: "books.vertical", title: String(localized: "知识库里也搜"), detail: String(localized: "问知识库、AI 助手查询时，把语音输入说过的话也算进去。默认不算，免得零碎的话干扰回答。")) {
                    Toggle("知识库里也搜", isOn: $settings.dictationInKnowledge).labelsHidden().toggleStyle(.switch)
                }
                .disabled(!settings.dictationSave)
                SettingRow(icon: "play.circle", title: String(localized: "先试一次"), detail: String(localized: "按当前声音来源录 5 秒，只显示识别结果，不会打进别的 App。选麦克风时说句话，选电脑里的声音时播放一段人声。")) {
                    Button("试一次") { dictation.tryOnce() }
                }
            }
            .disabled(!on)
            .opacity(on ? 1 : 0.5)

            SettingsGroup(String(localized: "权限"), footer: String(localized: "密盒助手要靠「辅助功能」权限来听到这个按键、把文字打进其他 App。没有权限时，文字只会放进剪贴板。")) {
                SettingRow(icon: "hand.raised", title: String(localized: "辅助功能")) {
                    if trusted {
                        StatusPill(ok: true, text: String(localized: "已允许"))
                    } else {
                        StatusPill(ok: false, text: String(localized: "未允许"))
                        Button("去授权") { dictation.requestAccessibility() }
                        Button("重新检查", action: refreshAccessibility)
                    }
                }
            }
        }
        .onAppear { refreshAccessibility() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshAccessibility()
        }
    }

    private func refreshAccessibility() {
        let current = AXIsProcessTrusted()
        if trusted != current { trusted = current }
        dictation.refresh()
    }
}

// MARK: 模型

/// 模型页的一张大卡片：卡片里面顶上是图标、标题和状态牌子。
private struct ModelCard<Content: View>: View {
    var icon: String
    var title: String
    var ok: Bool
    var status: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 20)).foregroundStyle(.secondary).frame(width: 26).accessibilityHidden(true)
                Text(title).font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                StatusPill(ok: ok, text: status)
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(radius: Theme.Radius.panel)
    }
}

private struct ModelsPane: View {
    @Environment(BeanStore.self) private var store
    @State private var advanced = false
    @State private var cloudSheet = false
    @State private var asrSheet = false
    @State private var miBoxSheet: MiBoxServiceSheet.Service?
    @State private var testNote: String?
    @State private var testing = false

    var body: some View {
        @Bindable var settings = store.settings
        let server = QwenASR.locateServer(custom: settings.llamaServerPath)
        let serverRequired = (settings.engine == .qwen && settings.localASRModel.funASR == nil)
            || settings.analysisMode == .local || settings.analysisMode == .auto
        let asrOK: Bool = switch settings.engine {
        case .qwen: store.asrAvailable
        case .apple: true
        case .cloud: settings.asrConfig != nil
        case .miBox: settings.miBoxASRConfig != nil
        }
        PaneFrame {
            // 设计稿 design/ui/ui_models2.png
            ModelCard(icon: "cpu", title: String(localized: "本机运行环境"), ok: server != nil || !serverRequired, status: server != nil ? String(localized: "已就绪") : serverRequired ? String(localized: "需要安装") : String(localized: "可选")) {
                line(String(localized: "推理程序 llama.cpp")) {
                    if let note = store.serverInstall {
                        ProgressView().controlSize(.small)
                        Text(note).foregroundStyle(.secondary)
                    } else if let server {
                        Text(server.path.hasPrefix("/Applications/") ? String(localized: "借用 \(server.pathComponents.dropFirst(2).first ?? String(localized: "其他 App"))") : String(localized: "已安装"))
                            .foregroundStyle(.secondary)
                        Button("重新检查") { store.refreshASRAvailability() }
                    } else {
                        Text("没找到").foregroundStyle(.secondary)
                        if BeanStore.brewPath != nil {
                            Button("安装") { store.installLlamaServer() }.buttonStyle(.glassProminent).tint(Theme.accent)
                        } else {
                            Link("怎么安装", destination: URL(string: "https://github.com/ggml-org/llama.cpp#quick-start")!)
                        }
                    }
                }
                Text(serverHint(server)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("高级", isExpanded: $advanced) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(server?.path ?? String(localized: "没找到")).font(.callout.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        TextField("自己指定 llama-server 的位置（可不填）", text: $settings.llamaServerPath).textFieldStyle(.roundedBorder)
                            .onSubmit { store.refreshASRAvailability() }
                    }
                    .padding(.top, 8)
                }
            }

            ModelCard(icon: "waveform", title: String(localized: "转写：把声音变成文字"), ok: asrOK, status: asrOK ? String(localized: "已就绪") : String(localized: "还差一步")) {
                line(String(localized: "引擎")) {
                    Picker("引擎", selection: $settings.engine) {
                        Text("本机").tag(AppSettings.Engine.qwen)
                        Text("系统识别").tag(AppSettings.Engine.apple)
                        Text("云端").tag(AppSettings.Engine.cloud)
                        Text("高阶网关/密盒").tag(AppSettings.Engine.miBox)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                switch settings.engine {
                case .qwen:
                    line(String(localized: "本机转写模型")) {
                        Picker("本机转写模型", selection: $settings.localASRModel) {
                            ForEach(AppSettings.LocalASRModel.allCases) { model in
                                Text(model.pickerTitle).tag(model)
                            }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        .onChange(of: settings.localASRModel) { _, _ in store.localASRSelectionChanged() }
                    }
                    line(String(localized: "模型文件")) {
                        downloadView(store.asrJob, ready: QwenASR.modelInstalled(selection: settings.localASRModel),
                                     readyText: String(localized: "\(settings.localASRModel.asrName) · 已下载"),
                                     size: settings.localASRModel.asrSize) { store.downloadASRModel() }
                    }
                    if settings.localASRModel.funASR != nil {
                        let hint = settings.localASRModel == .nano
                            ? String(localized: "使用本机 CPU 转写。录音不会上传。")
                            : String(localized: "在这台 Mac 上运行，录音不会上传。Paraformer 使用应用内的转写程序，不需要 llama-server。")
                        Text(store.localASRReadinessHint ?? hint)
                            .font(.callout).foregroundStyle(store.asrAvailable ? Color.secondary : Theme.amber)
                    } else {
                        Text(store.asrAvailable ? "在这台 Mac 上运行，录音不会上传。" : "还没准备好之前，暂时用系统语音识别顶上。")
                            .font(.callout).foregroundStyle(store.asrAvailable ? Color.secondary : Theme.amber)
                    }
                case .apple:
                    line(String(localized: "语言")) {
                        Picker("语言", selection: $settings.language) {
                            ForEach(Transcriber.languages, id: \.id) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    Text("用 macOS 自带的语音识别，在这台 Mac 上运行。").font(.callout).foregroundStyle(.secondary)
                case .cloud:
                    Text(settings.asrConfig == nil ? "还没设置云端转写服务，先点下面的「设置…」。" : "录音会发给你设置的云端服务转写。")
                        .font(.callout).foregroundStyle(settings.asrConfig == nil ? Theme.amber : Color.secondary)
                case .miBox:
                    line(String(localized: "密盒转写服务")) {
                        Text(settings.miBoxASRConfig == nil ? String(localized: "还没设置") : settings.miBoxASRModel)
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("设置…") { miBoxSheet = .asr }
                    }
                }
                if settings.engine != .miBox {
                    Divider()
                    line(settings.engine == .cloud ? String(localized: "云端转写服务") : String(localized: "云端重转")) {
                        Text(asrSummary).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button(settings.asrConfig == nil ? "设置…" : "更改…") { asrSheet = true }
                    }
                    if settings.engine != .cloud {
                        Text("本机转得不准的录音，可以在录音页的「⋯」菜单里按需交给云端再转一遍。").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }

            ModelCard(icon: "doc.text", title: String(localized: "整理：写纪要、回答提问"), ok: store.analysisAvailable, status: store.analysisAvailable ? String(localized: "已就绪") : String(localized: "还没选模型")) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("用哪边的模型", selection: $settings.analysisMode) {
                        Text("云端优先").tag(AppSettings.AnalysisMode.auto)
                        Text("只用云端").tag(AppSettings.AnalysisMode.cloud)
                        Text("只用本机").tag(AppSettings.AnalysisMode.local)
                        Text("高阶网关/密盒").tag(AppSettings.AnalysisMode.miBox)
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.large)
                    Text(modeHint(settings.analysisMode)).font(.callout).foregroundStyle(.secondary)
                }
                if settings.analysisMode == .miBox {
                    line(String(localized: "密盒整理服务")) {
                        Text(settings.miBoxLLMConfig == nil ? String(localized: "还没设置") : settings.miBoxLLMModel)
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("设置…") { miBoxSheet = .analysis }
                    }
                } else {
                    HStack(alignment: .top, spacing: 18) {
                        half(String(localized: "本机模型"), dim: settings.analysisMode == .cloud) {
                            Picker("本机整理模型", selection: $settings.localAnalysisModel) {
                                Text("Qwen3-4B").tag(AppSettings.LocalModel.qwen)
                                Text("Gemma 4 E2B").tag(AppSettings.LocalModel.gemma)
                            }
                            .pickerStyle(.segmented).labelsHidden()
                            .onChange(of: settings.localAnalysisModel) { _, _ in store.refreshASRAvailability() }
                            if let job = store.llmJob {
                                jobDetail(job, title: settings.localAnalysisModel.analysisName)
                            } else if LocalLLM.modelURL(selection: settings.localAnalysisModel) != nil {
                                Text(LocalLLM.modelLabel(selection: settings.localAnalysisModel)).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                                Button("打开模型文件夹", action: openFolder)
                            } else {
                                Text("\(settings.localAnalysisModel.analysisName) · 还没下载").font(.body.weight(.medium))
                                HStack {
                                    Button("下载（\(settings.localAnalysisModel.analysisSize)）") { store.downloadLocalLLM() }
                                    Button("打开模型文件夹", action: openFolder)
                                }
                            }
                        }
                        Divider()
                        half(String(localized: "云端服务"), dim: settings.analysisMode == .local) {
                            Text(cloudSummary).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                            HStack {
                                Button(settings.llmConfigured ? "更改…" : "设置…") { cloudSheet = true }
                                if settings.llmConfigured {
                                    Button("测试") { test() }.disabled(testing)
                                    if testing { ProgressView().controlSize(.small) }
                                }
                            }
                            if let testNote { Text(testNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Text("下载断了会从断点接着下；HuggingFace 太慢时自动换国内镜像，下完按 SHA‑256 校验。本机模型不联网；云端纪要质量更高，但文字稿会发给服务商，录音本身不会。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            ModelCard(icon: "character.bubble", title: String(localized: "翻译：把外语译成你要的语言"), ok: store.analysisAvailable, status: store.analysisAvailable ? String(localized: "用整理的模型") : String(localized: "还没选模型")) {
                line(String(localized: "译成")) {
                    Picker("译成", selection: $settings.translateTo) {
                        ForEach(translateLanguages, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                Divider()
                line(String(localized: "默认风格")) {
                    Picker("默认风格", selection: $settings.translateStyle) {
                        ForEach(TranslateStyle.allCases) { Text($0.name).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                Text(settings.translateStyle.hint).font(.callout).foregroundStyle(.secondary)
                if settings.translateStyle == .custom {
                    TextField("自定义提示词，比如：译成小红书风格，口语化，每段不超过三句", text: $settings.translatePrompt, axis: .vertical)
                        .lineLimit(2...5).textFieldStyle(.roundedBorder)
                }
                Divider()
                Toggle("外语素材整理完自动翻译", isOn: $settings.autoTranslate).toggleStyle(.switch)
                Text("用上面选定的整理模型逐句翻译。").font(.callout).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $cloudSheet) { CloudServiceSheet() }
        .sheet(isPresented: $asrSheet) { CloudASRSheet() }
        .sheet(item: $miBoxSheet) { MiBoxServiceSheet(service: $0) }
        .onAppear { store.restorePausedDownloads(); store.refreshASRAvailability() }
    }

    private func serverHint(_ server: URL?) -> String {
        if store.serverInstall != nil { return String(localized: "正在用 Homebrew 安装 llama.cpp，大约 1 分钟，装好会自动检测。") }
        if let server, server.path.hasPrefix("/Applications/") {
            return String(localized: "Qwen3-ASR、Gemma 4 E2B 和本机整理模型靠它运行；Paraformer 不需要它。现在借用的是别的 App 里带的那份，那个 App 删掉就用不了了；建议点「高级」看看位置，或者用 Homebrew 装一份（brew install llama.cpp）。")
        }
        if server != nil { return String(localized: "Qwen3-ASR、Gemma 4 E2B 和本机整理模型靠它运行；Paraformer 不需要它。") }
        return BeanStore.brewPath != nil
            ? String(localized: "Qwen3-ASR、Gemma 4 E2B 和本机整理模型靠它运行；Paraformer 不需要它。点「安装」会用 Homebrew 装，大约 1 分钟。")
            : String(localized: "Qwen3-ASR、Gemma 4 E2B 和本机整理模型靠它运行；Paraformer 不需要它。这台 Mac 上没有 Homebrew，先按链接里的说明装好 llama.cpp。")
    }

    /// 模型下载那一格：没下 → 下载按钮；下载中 → 进度、来源、速度、暂停/取消；下好了 → 一行字。
    @ViewBuilder
    private func downloadView(_ job: DownloadJob?, ready: Bool, readyText: String, size: String, start: @escaping () -> Void) -> some View {
        if let job {
            VStack(alignment: .trailing, spacing: 6) { jobDetail(job, title: nil) }.frame(width: 300)
        } else if ready {
            Text(readyText).foregroundStyle(.secondary)
        } else {
            Button("下载（\(size)）", action: start)
        }
    }

    @ViewBuilder
    private func jobDetail(_ job: DownloadJob, title: String?) -> some View {
        let gb = { (b: Int64) in String(format: "%.1f", Double(b) / 1_000_000_000) }
        let head: String = switch job.state {
        case .running: String(localized: "正在下载 \(Int(job.fraction * 100))%")
        case .paused: String(localized: "已暂停 \(Int(job.fraction * 100))%")
        case .verifying: String(localized: "正在校验…")
        case .failed: String(localized: "没下完")
        }
        Text([title, head].compactMap { $0 }.joined(separator: " · ")).font(.body.weight(.medium)).monospacedDigit()
        ProgressView(value: job.fraction).tint(Theme.accent)
        if case .failed(let why) = job.state {
            Text(why).font(.caption).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
        } else {
            Text("\(gb(job.received)) / \(gb(job.total)) GB · \(job.source.name)" + (job.state == .running && job.speed > 0 ? String(format: " · %.1f MB/s", job.speed / 1_000_000) : ""))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        HStack {
            switch job.state {
            case .running: Button("暂停") { job.pause() }
            case .paused, .failed: Button("继续") { job.start() }
            case .verifying: EmptyView()
            }
            Button("取消") { job.cancel() }.disabled(job.state == .verifying)
        }
        .controlSize(.small)
    }

    private func test() {
        guard let config = store.cloudConfig else { return }
        testing = true; testNote = nil
        Task {
            defer { testing = false }
            let result = await CloudServiceSheet.runTest(config, store: store)
            testNote = result.text
            if result.ok { store.upgradeRoughNotes() }
        }
    }

    private func line<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Text(title)
            Spacer(minLength: 12)
            trailing()
        }
    }

    private func half<Content: View>(_ title: String, dim: Bool, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(dim ? 0.45 : 1)
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: LocalLLM.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(LocalLLM.folder)
    }

    private func modeHint(_ mode: AppSettings.AnalysisMode) -> String {
        switch mode {
        case .auto: String(localized: "平时用云端，连不上的时候自动换成本机。")
        case .cloud: String(localized: "只用云端。连不上的时候不整理，等能连上再说。")
        case .local: String(localized: "只用本机。文字稿不会离开这台电脑。")
        case .miBox: String(localized: "使用密盒上配置的模型整理纪要、回答提问和翻译。")
        }
    }

    private var cloudSummary: String {
        let s = store.settings
        guard s.llmConfigured else { return String(localized: "还没设置") }
        let name = AppSettings.presets.first { $0.url == s.llmBaseURL }?.name ?? String(localized: "自定义服务")
        return "\(name) · \(s.llmModel)"
    }

    private var asrSummary: String {
        let s = store.settings
        guard let config = s.asrConfig else { return String(localized: "未设置") }
        let name = CloudASR.presets.first { $0.url == s.asrBaseURL }?.name ?? String(localized: "自定义服务")
        return "\(name) · \(config.model)"
    }
}

private struct MiBoxServiceSheet: View {
    enum Service: String, Identifiable {
        case asr, analysis
        var id: Self { self }

        var title: String {
            switch self {
            case .asr: String(localized: "密盒转写")
            case .analysis: String(localized: "密盒整理")
            }
        }
    }

    private enum TestState {
        case idle
        case testing(UUID)
        case result(ok: Bool, text: String)

        var isTesting: Bool {
            if case .testing = self { return true }
            return false
        }
    }

    let service: Service
    @Environment(BeanStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var testState = TestState.idle
    @State private var testTask: Task<Void, Never>?
    @State private var models: [String] = []
    @State private var modelTask: Task<Void, Never>?
    @State private var modelRequestID: UUID?
    @State private var modelListLoaded = false

    private var baseURL: Binding<String> {
        @Bindable var settings = store.settings
        return service == .asr ? $settings.miBoxASRBaseURL : $settings.miBoxLLMBaseURL
    }

    private var model: Binding<String> {
        @Bindable var settings = store.settings
        return service == .asr ? $settings.miBoxASRModel : $settings.miBoxLLMModel
    }

    private var key: Binding<String> {
        @Bindable var settings = store.settings
        return service == .asr ? $settings.miBoxASRKey : $settings.miBoxLLMKey
    }

    private var fields: [String] { [baseURL.wrappedValue, model.wrappedValue, key.wrappedValue] }
    private var modelSource: [String] { [baseURL.wrappedValue, key.wrappedValue] }

    private var configured: Bool {
        service == .asr ? store.settings.miBoxASRConfig != nil : store.settings.miBoxLLMConfig != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(service.title).font(.title2.bold())
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("接口地址")
                    TextField("接口地址", text: baseURL, prompt: Text("http://…/v1"))
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("模型")
                    HStack(spacing: 6) {
                        TextField("模型", text: model).textFieldStyle(.roundedBorder)
                        Menu {
                            ForEach(models, id: \.self) { name in
                                Button(name) { model.wrappedValue = name }
                            }
                            if models.isEmpty {
                                Text(modelListLoaded ? "这个服务没给列表，可以直接填写模型名。" : "先刷新列表，也可以直接填写模型名。")
                            }
                        } label: { Image(systemName: "chevron.down") }
                        .menuIndicator(.hidden).fixedSize()
                        if modelRequestID != nil { ProgressView().controlSize(.small) }
                        Button("刷新列表") { loadModels() }
                            .buttonStyle(.link).foregroundStyle(Theme.accent)
                            .disabled(AppSettings.miBoxEndpoint(baseURL.wrappedValue) == nil || modelRequestID != nil)
                    }
                }
                GridRow {
                    Text("密钥")
                    SecureField("密钥", text: key).textFieldStyle(.roundedBorder)
                }
            }
            .padding(14).panel(radius: Theme.Radius.card)
            HStack {
                if case .result(let ok, let text) = testState {
                    Text(text).font(.callout).foregroundStyle(ok ? Theme.ok : Theme.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if testState.isTesting { ProgressView().controlSize(.small) }
                Button("测试一下") { test() }.disabled(!configured || testState.isTesting)
                Button("完成") { dismiss() }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 560)
        .onChange(of: fields) { _, _ in resetTest() }
        .onChange(of: modelSource) { _, _ in resetModels() }
        .onDisappear { resetTest(); resetModels() }
    }

    private func resetModels() {
        modelTask?.cancel()
        modelTask = nil
        modelRequestID = nil
        models = []
        modelListLoaded = false
    }

    private func loadModels() {
        guard let endpoint = AppSettings.miBoxEndpoint(baseURL.wrappedValue) else { return }
        let requestKey = key.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = modelSource
        let requestID = UUID()
        modelRequestID = requestID
        modelTask = Task {
            let result = await Analyzer.listModels(baseURL: endpoint, key: requestKey)
            guard !Task.isCancelled, source == modelSource, modelRequestID == requestID else { return }
            models = result
            modelListLoaded = true
            modelRequestID = nil
            modelTask = nil
        }
    }

    private func resetTest() {
        testTask?.cancel()
        testTask = nil
        testState = .idle
    }

    private func test() {
        let settings = store.settings
        let asrConfig = settings.miBoxASRConfig
        let llmConfig = settings.miBoxLLMConfig
        guard service == .asr ? asrConfig != nil : llmConfig != nil else { return }
        let testedFields = fields
        let requestID = UUID()
        testState = .testing(requestID)
        testTask = Task {
            let result: (ok: Bool, text: String)
            switch service {
            case .asr:
                guard let asrConfig else { return }
                do {
                    try await CloudASR.test(asrConfig)
                    result = (true, String(localized: "测试通过，接口能用。"))
                } catch {
                    result = (false, error.localizedDescription)
                }
            case .analysis:
                guard let llmConfig else { return }
                result = await CloudServiceSheet.runTest(llmConfig, store: store)
            }
            guard !Task.isCancelled, testedFields == fields,
                  case .testing(let currentID) = testState, currentID == requestID else { return }
            testState = .result(ok: result.ok, text: result.text)
            testTask = nil
        }
    }
}

/// 云端整理服务（设计稿 design/ui/ui_cloud_providers.png）：选一家 → 地址自动填好 → 选模型、填密钥 → 测试。
private struct CloudServiceSheet: View {
    @Environment(BeanStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var models: [String] = []
    @State private var loadingModels = false
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?
    @State private var custom = false

    private var cloud: [AppSettings.Provider] { AppSettings.presets.filter { !$0.local } }
    private var local: [AppSettings.Provider] { AppSettings.presets.filter(\.local) }
    private var current: AppSettings.Provider? { AppSettings.presets.first { $0.url == store.settings.llmBaseURL } }

    var body: some View {
        @Bindable var settings = store.settings
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("云端服务").font(.title2.bold())
                Text("任何兼容 OpenAI 接口的服务都能用。密钥存在系统钥匙串里。").font(.callout).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                ForEach(cloud) { p in tile(p) }
            }
            HStack(spacing: 8) {
                ForEach(local) { p in chip(p.name, picked: settings.llmBaseURL == p.url) { pick(p) } }
                chip(String(localized: "自定义…"), picked: custom || (current == nil && !settings.llmBaseURL.isEmpty)) {
                    custom = true; settings.llmBaseURL = ""; settings.llmModel = ""; models = []; testResult = nil
                }
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("接口地址").gridColumnAlignment(.leading)
                    TextField("接口地址", text: $settings.llmBaseURL, prompt: Text("https://…/v1")).textFieldStyle(.roundedBorder)
                    Text(current != nil && !custom ? "已自动填好" : "").font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                }
                GridRow {
                    Text("模型")
                    HStack(spacing: 6) {
                        TextField("模型", text: $settings.llmModel, prompt: Text(models.isEmpty ? "填模型名，或点右边从列表里选" : "从右边的列表里选")).textFieldStyle(.roundedBorder)
                        Menu {
                            ForEach(models, id: \.self) { m in Button(m) { settings.llmModel = m } }
                            if models.isEmpty { Text(loadingModels ? "正在获取…" : "这个服务没给列表（可能要先填密钥）") }
                        } label: { Image(systemName: "chevron.down") }
                        .menuIndicator(.hidden).fixedSize().disabled(settings.llmBaseURL.isEmpty)
                    }
                    Button("刷新列表") { Task { await loadModels() } }.buttonStyle(.link).foregroundStyle(Theme.accent).disabled(settings.llmBaseURL.isEmpty)
                }
                if !settings.llmIsLocal {
                    GridRow {
                        Text("密钥")
                        SecureField("API Key", text: $settings.llmKey).textFieldStyle(.roundedBorder)
                        if let page = current?.keyPage, !page.isEmpty, let url = URL(string: page) {
                            Link("去获取密钥", destination: url).foregroundStyle(Theme.accent)
                        } else { Text("") }
                    }
                }
            }
            .padding(14).panel(radius: Theme.Radius.card)
            HStack(alignment: .center) {
                if let testResult {
                    Text(testResult.text).font(.callout).foregroundStyle(testResult.ok ? Theme.ok : Theme.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if testing { ProgressView().controlSize(.small) }
                Button("测试一下") { test() }.disabled(!settings.llmConfigured || testing)
                Button("完成") { dismiss() }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 620)
        .task(id: settings.llmBaseURL + settings.llmKey) {
            guard !settings.llmBaseURL.isEmpty else { return }
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            await loadModels()
        }
    }

    private func pick(_ p: AppSettings.Provider) {
        let s = store.settings
        custom = false
        guard s.llmBaseURL != p.url else { return }
        s.llmBaseURL = p.url
        s.llmModel = p.model
        models = []; testResult = nil
    }

    private func tile(_ p: AppSettings.Provider) -> some View {
        let picked = store.settings.llmBaseURL == p.url && !custom
        return Button { pick(p) } label: {
            VStack(spacing: 8) {
                Text(p.badge).font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 34, height: 34).background(Color.secondary.opacity(0.14), in: .circle)
                Text(p.name).font(.callout.weight(.medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(Color(nsColor: .controlBackgroundColor).opacity(picked ? 1 : 0.6), in: .rect(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(picked ? Theme.accent : Color.secondary.opacity(0.22), lineWidth: picked ? 2 : 0.5))
            .overlay(alignment: .topTrailing) {
                if picked { Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, Theme.accent).padding(5) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(picked ? String(localized: "\(p.name)，已选中") : p.name)
    }

    private func chip(_ title: String, picked: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.callout).padding(.horizontal, 14).padding(.vertical, 6)
                .overlay(Capsule().strokeBorder(picked ? Theme.accent : Color.secondary.opacity(0.3), lineWidth: picked ? 1.5 : 0.5))
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }

    private func loadModels() async {
        loadingModels = true
        models = await Analyzer.listModels(baseURL: store.settings.llmBaseURL, key: store.settings.llmKey)
        loadingModels = false
    }

    private func test() {
        guard let config = store.cloudConfig else { return }
        testing = true; testResult = nil
        Task {
            defer { testing = false }
            let result = await Self.runTest(config, store: store)
            testResult = result
            if result.ok { store.upgradeRoughNotes() }
        }
    }

    /// 拿一段销售通话试整理，看判对场景没有。模型页的「测试」也用它。
    static func runTest(_ config: LLMConfig, store: BeanStore) async -> (ok: Bool, text: String) {
        let t0 = Date()
        do {
            let a = try await Analyzer.analyze(
                transcript: "王总您好，我是小李。这套系统年费三万八，含五个席位。您说预算三万以内，我申请到这个月签可以三万二，再送两个月服务。除了您还要财务张姐确认对吧？我周四把合同发您邮箱，周五再给您打电话。",
                duration: 40, profession: store.settings.profession, fixedScene: nil, config: config)
            let secs = String(format: "%.1f", Date().timeIntervalSince(t0))
            return a.scene == .sales || a.scene == .call
                ? (ok: true, text: String(localized: "测试通过 · \(secs) 秒 · 把销售通话判成了「\(a.scene.name)」"))
                : (ok: false, text: String(localized: "能连上（\(secs) 秒），但把销售通话判成了「\(a.scene.name)」，这个模型可能偏弱。"))
        } catch {
            return (ok: false, text: error.localizedDescription)
        }
    }
}

/// 云端转写服务（Mac 上之前没有界面）：兼容 OpenAI「/audio/transcriptions」接口的服务。
private struct CloudASRSheet: View {
    @Environment(BeanStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var testing = false
    @State private var result: (ok: Bool, text: String)?

    var body: some View {
        @Bindable var settings = store.settings
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("云端转写").font(.title2.bold())
                Text("兼容 OpenAI「/audio/transcriptions」接口的服务都能用；小米 MiMo 走它自己的转写模型。用它转写时，录音会发给这家服务商。密钥存在系统钥匙串里。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                ForEach(CloudASR.presets, id: \.url) { p in
                    let picked = settings.asrBaseURL == p.url
                    Button {
                        settings.asrBaseURL = p.url; settings.asrModel = p.model; result = nil
                    } label: {
                        Text(p.name).font(.callout).padding(.horizontal, 14).padding(.vertical, 6)
                            .overlay(Capsule().strokeBorder(picked ? Theme.accent : Color.secondary.opacity(0.3), lineWidth: picked ? 1.5 : 0.5))
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("接口地址")
                    TextField("接口地址", text: $settings.asrBaseURL, prompt: Text("https://…/v1")).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("模型")
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("模型", text: $settings.asrModel, prompt: Text("比如 whisper-1")).textFieldStyle(.roundedBorder)
                        if CloudASR.isMiMo(settings.asrBaseURL), CloudASR.mimoModel(settings.asrModel) != settings.asrModel {
                            Text("「\(settings.asrModel)」是对话模型，不能转写。转写会用 \(CloudASR.mimoModel(settings.asrModel))。")
                                .font(.caption).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
                        }
                        if CloudASR.isSiliconFlowEnglishModel(baseURL: settings.asrBaseURL, model: settings.asrModel) {
                            Text("这个模型专用于英文。中文或粤语转写会使用同一服务的 XingChenASR-V3.2-Ultra。")
                                .font(.caption).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if CloudASR.isSiliconFlowEnglishModel(baseURL: settings.asrBaseURL, model: settings.asrModel) {
                    GridRow {
                        Text("语言")
                        Picker("语言", selection: $settings.language) {
                            ForEach(Transcriber.languages, id: \.id) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden()
                    }
                }
                GridRow {
                    Text("密钥")
                    SecureField("API Key", text: $settings.asrKey).textFieldStyle(.roundedBorder)
                }
            }
            .padding(14).panel(radius: Theme.Radius.card)
            HStack {
                if let result {
                    Text(result.text).font(.callout).foregroundStyle(result.ok ? Theme.ok : Theme.amber).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if testing { ProgressView().controlSize(.small) }
                Button("测试一下") { test() }.disabled(settings.asrConfig == nil || testing)
                Button("完成") { dismiss() }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 560)
        .onChange(of: store.settings.asrConfig) { result = nil }
    }

    private func test() {
        guard let config = store.settings.asrConfig else { return }
        testing = true; result = nil
        Task {
            defer { testing = false }
            do { try await CloudASR.test(config); result = (true, String(localized: "测试通过，接口能用。")) }
            catch { result = (false, error.localizedDescription) }
        }
    }
}

// MARK: 词库

private struct VocabularyPane: View {
    @Environment(BeanStore.self) private var store
    @State private var wrong = ""
    @State private var right = ""
    @FocusState private var focus: Field?
    private enum Field { case wrong, right }

    private var canAdd: Bool {
        !wrong.trimmingCharacters(in: .whitespaces).isEmpty && !right.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        let settings = store.settings
        PaneFrame {
            SettingsGroup(String(localized: "纠错词库"), footer: String(localized: "模型老是听错的人名、产品名、术语记在这里，以后转写出来会自动改成正确的写法。在文字稿里改一个词，也会记到这里。")) {
                HStack(spacing: 10) {
                    TextField("听成了", text: $wrong, prompt: Text("听成了，比如：豆苍")).textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .wrong).onSubmit { focus = .right }
                    Image(systemName: "arrow.right").font(.callout).foregroundStyle(.tertiary).accessibilityHidden(true)
                    TextField("应该是", text: $right, prompt: Text("应该是，比如：密盒助手")).textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .right).onSubmit(add)
                    Button("记住", action: add).disabled(!canAdd)
                }
                if settings.vocabulary.isEmpty {
                    Text("还没有记住任何词。").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(settings.vocabulary) { entry in
                                HStack(spacing: 10) {
                                    Text(entry.wrong).foregroundStyle(.secondary)
                                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
                                    Text(entry.right)
                                    Spacer()
                                    Button("删除「\(entry.wrong)」", systemImage: "minus.circle") { settings.vocabulary.removeAll { $0 == entry } }
                                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                                }
                                .padding(.vertical, 7)
                                if entry != settings.vocabulary.last { Divider() }
                            }
                        }
                    }
                    .frame(height: min(CGFloat(settings.vocabulary.count) * 36, 288))
                }
            }
        }
    }

    private func add() {
        guard canAdd else { return }
        let w = wrong.trimmingCharacters(in: .whitespaces), r = right.trimmingCharacters(in: .whitespaces)
        store.settings.vocabulary.removeAll { $0.wrong == w }
        store.settings.vocabulary.insert(.init(wrong: w, right: r), at: 0)
        wrong = ""; right = ""
        focus = .wrong
    }
}

// MARK: 连接

private struct ConnectPane: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(Connector.self) private var connector
    @State private var copied = false

    var body: some View {
        PaneFrame {
            SettingsGroup(String(localized: "AI 助手"), footer: String(localized: "连上之后，在它们那边就能直接查你的录音、纪要和待办，也能把文字和音频存进密盒助手。")) {
                SettingRow(icon: "link", title: String(localized: "Claude、Codex、OpenClaw、TeleAgent、Grok Bot"),
                           detail: connector.connectedCount > 0 ? String(localized: "已经连上 \(connector.connectedCount) 个。") : String(localized: "还没有连上任何一个。")) {
                    Button("打开连接页面…") { openWindow(id: "connect") }
                }
                SettingRow(icon: "film", title: String(localized: "Renoise（做视频）"), detail: String(localized: "把改写好的稿子做成口播视频要用它。安装和登录也在连接页面里。")) {
                    Button("去看看…") { openWindow(id: "connect") }
                }
            }

            LoginsGroup()

            SettingsGroup(String(localized: "给其他工具用"), footer: String(localized: "这个地址只在这台电脑上能访问，而且只有密盒助手开着的时候才通。")) {
                SettingRow(icon: "network", title: String(localized: "接入地址")) {
                    Text(BeanStore.mcpAddress).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    Button(copied ? "已拷贝" : "拷贝") {
                        copy(BeanStore.mcpAddress)
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                    }
                }
                SettingRow(icon: "terminal", title: String(localized: "命令行"), detail: String(localized: "在终端里也能查录音、存内容。")) {
                    Text("beanpod").font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .task { await connector.refresh() }
    }
}

/// 从链接导入时登录过的平台。登录状态只存在这台 Mac 上，这里可以一个个清掉。
private struct LoginsGroup: View {
    @Environment(BeanStore.self) private var store
    @State private var refresh = 0

    var body: some View {
        let list = store.loggedInPlatforms
        let _ = refresh
        SettingsGroup(String(localized: "从链接导入时登录过的平台"), footer: String(localized: "导入要登录才能看的内容时，密盒助手会弹出登录窗口让你自己登录。登录状态只存在这台 Mac 上。")) {
            if list.isEmpty {
                Text("还没有登录过任何平台。").foregroundStyle(.secondary)
            }
            ForEach(list, id: \.self) { platform in
                SettingRow(icon: "person.crop.circle.badge.checkmark", title: platform) {
                    Button("退出登录") { store.forgetLogin(platform); refresh += 1 }
                }
            }
        }
    }
}
