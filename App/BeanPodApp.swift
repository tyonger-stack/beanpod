import SwiftUI

@main
struct BeanPodApp: App {
    @State private var store = BeanStore()
    @State private var nav = Navigator()
    @State private var dictation = Dictation()
    @State private var connector = Connector()
    @State private var maker = VideoMaker()
    @State private var renoise = RenoiseSetup()
    @State private var clipboard = ClipboardWatch()
    @State private var notch = NotchPanel()
    @Environment(\.openWindow) private var openWindow

    var body: some SwiftUI.Scene {
        Window("密盒助手", id: "main") {
            RootView()
                .environment(store).environment(nav).environment(dictation).environment(connector).environment(maker).environment(renoise).environment(clipboard)
                .task { dictation.attach(store) }
                .task { await maker.watch(store) }   // 接着跟上次交给 Claude 还没做完的视频
                .task { notch.attach(store) }        // 刘海快捷面板
                .task { FeishuSync.shared.attach(store) }   // 手机同步进飞书妙记的录音，拉回来
                .frame(minWidth: 980, minHeight: 600)
                .containerBackground(.clear, for: .window)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .help) {
                Button("上手引导") { nav.welcomeOpen = true }
                Button("连接 AI 助手…") { openWindow(id: "connect") }
                Button("安装 Renoise（做视频）…") { openWindow(id: "connect") }
            }
            CommandMenu("录音") {
                // 好按的键只做能反悔的事：开始、暂停、继续。结束要按另一个键，免得手滑把录音断掉。
                Button(store.recState == .idle ? "开始录音" : store.recState == .paused ? "继续录音" : "暂停") {
                    switch store.recState {
                    case .idle: store.startRecording()
                    case .recording: store.pauseRecording()
                    case .paused: store.resumeRecording()
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                // 用这台 Mac 录：三种声音来源，点哪个就用哪个开始，并记住这次的选择
                Menu("用这台 Mac 录") {
                    ForEach(BeanStore.MacSource.allCases) { source in
                        Button(source.name + (store.macSource == source ? "　✓" : "")) { store.startMacRecording(source) }
                    }
                }
                .disabled(store.recState != .idle)
                Button("用这台 Mac 录（\(store.macSource.name)）") { store.startMacRecording() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(store.recState != .idle)
                Button("标重点") { store.markNow() }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(store.recState != .recording)
                Button("结束录音") { store.finishRecording() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(store.recState == .idle)
                Divider()
                Button(nav.stageOpen ? "收起录音舞台" : "打开录音舞台") { nav.stageOpen.toggle() }
                    .keyboardShortcut("l", modifiers: .command)
                    .disabled(store.recState == .idle)
                Button(notch.visible ? "隐藏刘海快捷面板" : "显示刘海快捷面板") { notch.setVisible(!notch.visible) }
                Divider()
                // 删除选中的那条录音。都会先问一句，不会直接删
                let chosen = store.recordings.first { $0.id == nav.selection }
                Button("从链接导入…") {
                    if !nav.route.isList { nav.route = .all }
                    nav.linkSheet = true
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                Divider()
                Button("重命名选中的录音…") {
                    if !nav.route.isList { nav.route = .all }
                    nav.renaming = chosen?.id
                }
                .disabled(chosen == nil)
                Button("让 AI 给选中的录音重新起标题") { if let id = chosen?.id { store.retitle(id) } }
                    .disabled(chosen?.transcript == nil || !store.analysisAvailable)
                Button("重新转写选中的录音") { if let id = chosen?.id { store.process(id, retranscribe: true) } }
                    .disabled(chosen?.downloaded != true || chosen?.textOnly == true || chosen.map { store.stages[$0.id] != nil } == true)
                // 视频素材的画面（VideoKeep.swift）
                if let c = chosen, c.isMaterial, store.videoRevision >= 0, store.hasVideo(c.id) {
                    Button("删掉选中素材的画面") { store.removeVideo(c.id) }
                } else {
                    Button("下载选中素材的画面（最高 720p）") { if let id = chosen?.id { store.fetchVideo(id) } }
                        .disabled(chosen?.isMaterial != true || chosen?.source == nil || chosen.map { store.videoWorking.contains($0.id) } == true)
                }
                Button("把选中的录音移到最近删除") { if let id = chosen?.id { store.trashWithUndo([id]) } }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(chosen?.downloaded != true || store.recState != .idle)
                Button("从密盒删除选中的录音…") { nav.confirmDeviceDelete = true }
                    .disabled(chosen?.onDevice != true || store.link != .ready || store.recState != .idle)
                Divider()
                Button("用 Wi‑Fi 快传还没下载的录音…") { nav.confirmWiFiSync = true }
                    .disabled(!store.canWiFiSync)
            }
            CommandMenu("回听") {
                let current = nav.selection ?? store.playingID
                Button("往回 15 秒") { if let current { store.skip(current, by: -15) } }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button("往后 15 秒") { if let current { store.skip(current, by: 15) } }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button("上一个重点标记") { if let current { store.jumpToMark(current, forward: false) } }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("下一个重点标记") { if let current { store.jumpToMark(current, forward: true) } }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Button("在播放的位置加重点标记") { if let id = store.playingID { store.addMark(id, at: store.playhead) } }
                    .keyboardShortcut("d", modifiers: [.command, .option])
                    .disabled(store.playingID == nil)
                Divider()
                Button("放慢") {
                    let i = BeanStore.rates.firstIndex(of: store.playRate) ?? 1
                    store.setRate(BeanStore.rates[max(0, i - 1)])
                }
                .keyboardShortcut("[", modifiers: .command)
                Button("加快") {
                    let i = BeanStore.rates.firstIndex(of: store.playRate) ?? 1
                    store.setRate(BeanStore.rates[min(BeanStore.rates.count - 1, i + 1)])
                }
                .keyboardShortcut("]", modifiers: .command)
                Button("正常速度") { store.setRate(1) }
                    .keyboardShortcut("0", modifiers: .command)
            }
            CommandMenu("语音输入") {
                Button("试一次（录 5 秒，只显示结果）") { dictation.tryOnce() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
            CommandMenu("预览") {
                Button("结束设备预览") { store.card.endPreview() }
                Button("看看：「录好了」卡片") { store.offerKeep(id: 0, seconds: 25, from: String(localized: "这台 Mac"), onMac: true) }
                Button("看看：做成视频（选主播）") {
                    if !maker.busy { maker.prepare(text: "这是一段示例口播稿。", recording: 0, title: "示例", template: "口播稿") }
                    openWindow(id: "video-preview")
                }
                Button("看看：得到录音卡（示例数据）") { store.card.showPreview(); nav.route = .device }
                Divider()
                Button("预览录音开始提示") { notch.preview(started: true) }
                Button("预览录音结束提示") { notch.preview(started: false) }
            }
        }

        Window("连接 AI 助手", id: "connect") {
            ConnectView().environment(store).environment(connector).environment(renoise)
                .frame(minWidth: 620, minHeight: 520)
        }
        .defaultSize(width: 720, height: 760)

        // 「做成视频」单开一个窗口看（预览菜单里使用；正常入口是录音「改写」页里的按钮，弹出单）
        Window("做成视频", id: "video-preview") {
            VideoSheet().environment(store).environment(maker)
        }
        .windowResizability(.contentSize)

        Window("诊断日志", id: "log") {
            LogView().environment(store)
        }
        .defaultSize(width: 720, height: 480)

        // 菜单栏常驻：不用切回豆仓窗口就能开始、停止录音
        MenuBarExtra {
            MenuBarContent().environment(store)
        } label: {
            Image(systemName: store.isRecording ? "record.circle.fill" : "waveform.circle")
        }

        Settings {
            SettingsView().environment(store).environment(dictation).environment(connector)
        }
    }
}

struct MenuBarContent: View {
    @Environment(BeanStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if store.link == .ready {
            Text(store.recState == .paused ? String(localized: "\(store.displayDeviceName) 录音已暂停") : store.isRecording ? String(localized: "\(store.displayDeviceName) 正在录音") : String(localized: "\(store.displayDeviceName) 已连接") + (store.info.map { " · \($0.micBattery)%" } ?? ""))
            switch store.recState {
            case .idle: Button("开始录音") { store.startRecording() }
            case .recording:
                Button("暂停") { store.pauseRecording() }
                Button("结束录音") { store.finishRecording() }
            case .paused:
                Button("继续录音") { store.resumeRecording() }
                Button("结束录音") { store.finishRecording() }
            }
        } else {
            Text(store.recordingOnMac ? "正在用这台 Mac 录音" : "密盒未连接")
            switch store.recState {
            case .idle: Button("用 Mac 录音") { store.startRecording() }
            case .recording:
                Button("暂停") { store.pauseRecording() }
                Button("结束录音") { store.finishRecording() }
            case .paused:
                Button("继续录音") { store.resumeRecording() }
                Button("结束录音") { store.finishRecording() }
            }
        }
        if !store.stages.isEmpty { Text("正在处理 \(store.stages.count) 条录音 · 还要\(BeanStore.spokenSpan(store.processingPlan().total, rough: true))") }
        Divider()
        Button("打开密盒助手") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button("退出密盒助手") { NSApp.terminate(nil) }
    }
}
