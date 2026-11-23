import AVFoundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import BeanKit
import Foundation
import Observation

@Observable
final class BeanStore {
    // 连接
    var link: BLEClient.Link = .idle
    var found: [FoundDevice] = []
    #if os(macOS)
    @ObservationIgnored let xiaomi = XiaomiRemoteClient()
    @ObservationIgnored let xiaomiBackButton = XiaomiRemoteBackButton()
    var xiaomiLink: BLEClient.Link = .idle
    var xiaomiFound: [FoundDevice] = []
    var xiaomiName: String?
    var xiaomiFailure: XiaomiRemoteClient.Failure?
    var xiaomiCapture: XiaomiCapture?
    #endif
    var deviceName = String(localized: "密盒")
    /// 界面上显示的名字：用户起过名就用用户的。
    var displayDeviceName: String { settings.deviceAlias.isEmpty ? deviceName : settings.deviceAlias }
    /// 这次录音是什么时候开始的，用来显示已录时长。
    var recordingSince: Date?
    var elapsedBase: TimeInterval = 0
    /// 设备上有一条开着的录音（正在录，或暂停着还没结束）。
    var sessionOpen = false
    @ObservationIgnored var pullWhenListed = false
    /// 项目（见 Projects.swift）。存在录音库旁边的 projects.json。
    var projects: [Project] = []
    /// 正在从链接导入的内容（见 App/LinkImport.swift，目前只有 Mac 上有）。
    var linkJobs: [LinkJob] = []
    @ObservationIgnored var linkWorker: Task<Void, Never>?
    /// 有一条链接要登录才能下，等用户去登录。
    var linkLogin: LinkLoginRequest?
    /// 刚录完、等用户说「留着」还是「不要」的那一条（见 KeepOrDiscard.swift）。
    var justRecorded: JustRecorded?
    /// Wi‑Fi 快传：正在进行的那一次（没有就是 nil），以及录音豆对「开热点」命令的回包。
    var wifi: WiFiSync?
    @ObservationIgnored var wifiReply: Packet?
    /// 快传没传完的，等蓝牙连回来后接着用蓝牙下。
    @ObservationIgnored var wifiFallback = false
    /// 刚连上录音豆，还没把「在外面录的」同步下来。列表和密钥都到位后才动手。
    @ObservationIgnored var syncOnConnect = false
    /// 刚连上、第一份清单还没回来：回来后一定说一句（有几条新录音 / 都同步过了 / 有录音被别处取走）。
    @ObservationIgnored var reportOnConnect = false
    /// 上次连接时录音豆里有哪些录音。下次连上对比：少了的又不是豆仓删的，多半是手机那边连过、同步走了。
    @ObservationIgnored var lastDeviceFiles: Set<UInt32> = Set((UserDefaults.standard.array(forKey: "lastDeviceFiles") as? [NSNumber] ?? []).map(\.uint32Value)) {
        didSet { UserDefaults.standard.set(lastDeviceFiles.map { NSNumber(value: $0) }, forKey: "lastDeviceFiles") }
    }
    /// 豆仓自己发过删除命令的录音，对比时不算「被取走」。
    @ObservationIgnored var deletedOnDevice: Set<UInt32> = []

    /// 语音输入时的实时收音：录音豆边录边把音频传过来。
    struct LiveCapture {
        var fileID: UInt32?
        var decryptor: FileDecryptor?
        /// 按序号存每一帧。实时传输是从请求那一刻开始的，开头的几帧要事后单独补。
        var frames: [UInt32: [UInt8]] = [:]
        var lastActivity = Date()
        var packets = 0
        /// 正在补开头：补到这个序号为止。
        var fillUntil: UInt32?
        /// 语音输入用的是临时录音，用完要删；实时转写录的是正式录音，不能删。
        var scratch = true

        var firstSequence: UInt32? { frames.keys.min() }

        /// 从 0 号帧开始、连续不断的那一段。
        var contiguous: Data {
            var out = Data()
            var n: UInt32 = 0
            while let f = frames[n] { out.append(contentsOf: f); n += 1 }
            return out
        }
    }
    @ObservationIgnored var live: LiveCapture?

    // 实时转写
    var liveActive = false
    var liveSegments: [Segment] = []
    /// 还没出字的那一小段已经攒了多少秒声音。
    var livePending: TimeInterval = 0
    var liveNote: String?
    @ObservationIgnored var liveTask: Task<Void, Never>?
    /// 暂停时把还没出字的那一小段立刻转出来，不等下一个停顿。
    @ObservationIgnored var liveFlush = false
    /// 实时音量，每 0.1 秒一格，给录音条上的波形用。
    var liveLevels: [Float] = []
    /// 回听的速度。
    var playRate: Float = { let r = UserDefaults.standard.float(forKey: "playRate"); return r > 0 ? r : 1 }()
    /// 这次录音一共算出过多少个音量值。liveLevels 只留最后一段，靠这个数知道它们各自是第几个。
    var liveLevelTotal = 0
    @ObservationIgnored var meterTask: Task<Void, Never>?
    /// 这次录音里打过的重点标记（秒）。
    var liveMarks: [TimeInterval] = []
    /// 这条录音是什么时候点的开始，用来把豆仓里点的标记对回下载下来的那条录音。
    @ObservationIgnored private var sessionStart: Date?
    /// 在豆仓里点的标记，等这条录音下载下来再写进去。
    @ObservationIgnored var pendingMarks: [(start: Date, file: UInt32, marks: [TimeInterval])] = []
    var rewriting: Set<UInt32> = []
    /// 正在让 AI 重新起标题的录音。
    var retitling: Set<UInt32> = []
    @ObservationIgnored var titleEditRevisions: [UInt32: UUID] = [:]
    /// 正在翻译的录音，和翻到第几成了（0…1）。
    var translating: [UInt32: Double] = [:]
    /// 正在做英语学习整理的录音（Study.swift）
    var studying: Set<UInt32> = []

    /// 用户刚手动改了一个词，问他要不要全部替换并记住。
    var pendingFix: PendingFix?
    struct PendingFix: Equatable { var recording: UInt32; var wrong: String; var right: String }
    /// 语音输入用完要从设备上清掉的临时录音。
    /// 记在本机，下次连上还认得；设备不肯删「当前文件」，要等它不再是当前文件时再删。
    @ObservationIgnored var scratchFiles: Set<UInt32> = Set((UserDefaults.standard.array(forKey: "scratchFiles") as? [NSNumber] ?? []).map(\.uint32Value)) {
        didSet { UserDefaults.standard.set(scratchFiles.map { NSNumber(value: $0) }, forKey: "scratchFiles") }
    }
    @ObservationIgnored var scratchTried: Set<UInt32> = []
    var info: DeviceInfo?
    var encryptionReady = false
    /// 最近删除（Trash.swift）：本机删掉的录音放 7 天，可以恢复。
    var trash: [TrashedRecording] = []

    // 录音
    var recordings: [Recording] = []
    /// 自己录的（不含从链接导入的素材）。录音页、总览只看这些；素材只在素材库里
    var ownRecordings: [Recording] { recordings.filter { !$0.isMaterial && !$0.isDictation } }
    /// 语音输入记下的（侧栏「语音输入」）。
    var dictations: [Recording] { recordings.filter(\.isDictation) }
    /// 知识库和 AI 助手查询用的：默认不含语音输入。
    var knowledgeRecordings: [Recording] { settings.dictationInKnowledge ? recordings : recordings.filter { !$0.isDictation } }
    var loadingList = false
    var pull: PullProgress?
    var queue: [UInt32] = []
    /// 每条录音当前处在流水线的哪一步；不在表里就是空闲。
    var stages: [UInt32: Stage] = [:] { didSet { trackStages(from: oldValue) } }
    /// 每条录音当前这一步是什么时候开始的（ProcessingETA.swift 估剩余时间用）
    @ObservationIgnored var stageSince: [UInt32: Date] = [:]
    /// 这一批从什么时候开始处理的；都处理完了为空
    var batchSince: Date?
    /// 模型下载（ModelDownloader.swift）：转写模型、本机整理模型各一个。
    var qwenASRJob: DownloadJob?
    var qwenLLMJob: DownloadJob?
    var gemmaJob: DownloadJob?
    var paraformerJob: DownloadJob?
    var nanoASRJob: DownloadJob?
    var asrJob: DownloadJob? {
        switch settings.localASRModel {
        case .qwen: qwenASRJob
        case .gemma: gemmaJob
        case .paraformer: paraformerJob
        case .nano: nanoASRJob
        }
    }
    var llmJob: DownloadJob? { settings.localAnalysisModel == .gemma ? gemmaJob : qwenLLMJob }
    var modelDownload: Double? { asrJob?.fraction }
    var llmDownload: Double? { llmJob?.fraction }
    /// 正在保存或下载画面的素材（VideoKeep.swift）。
    var videoWorking: Set<UInt32> = []
    /// 画面文件有变化时加一，界面据此刷新「有没有画面」和占用。
    var videoRevision = 0
    /// 正在用 Homebrew 装 llama.cpp 时的进度说明；nil 表示没在装。
    var serverInstall: String?
    var modelAvailabilityRevision = 0
    var localLLMReady: Bool {
        _ = modelAvailabilityRevision
        return QwenASR.locateServer(custom: settings.llamaServerPath) != nil && LocalLLM.modelURL(selection: settings.localAnalysisModel) != nil
    }
    var asrAvailable: Bool {
        _ = modelAvailabilityRevision
        return QwenASR.runtimeAvailable(selection: settings.localASRModel, serverPath: settings.llamaServerPath)
            && QwenASR.modelInstalled(selection: settings.localASRModel)
    }

    var localASRReadinessHint: String? {
        _ = modelAvailabilityRevision
        let selection = settings.localASRModel
        guard QwenASR.modelInstalled(selection: selection) else {
            if let job = asrJob {
                switch job.state {
                case .running: return String(localized: "\(selection.asrName) 正在下载，完成后才能转写。")
                case .verifying: return String(localized: "\(selection.asrName) 正在校验，完成后才能转写。")
                case .paused: return String(localized: "\(selection.asrName) 下载已暂停，请到设置中继续下载。")
                case .failed(let reason): return String(localized: "\(selection.asrName) 下载失败：\(reason)")
                }
            }
            return String(localized: "\(selection.asrName) 还没下载，请到设置中下载模型。")
        }
        guard QwenASR.runtimeAvailable(selection: selection, serverPath: settings.llamaServerPath) else {
            return selection.funASR != nil
                ? String(localized: "应用中缺少 FunASR 转写程序，请重新安装完整版本。")
                : String(localized: "本机转写运行程序还没准备好，请到设置中安装或指定 llama-server。")
        }
        return nil
    }

    // 知识库问答
    var answer: String?
    var answerSources: [UInt32] = []
    var asking = false

    let settings = AppSettings()

    enum Stage: Equatable { case queued, transcribing(Double), analyzing }

    // 播放
    var playingID: UInt32?
    var isPlaying = false
    var playhead: TimeInterval = 0

    /// 出了问题时弹出来的说明：发生了什么、为什么、下一步能做什么。
    struct Problem: Equatable {
        var title: String
        var detail = ""
        var action: Action?
        enum Action: Equatable {
            case settings, device, download(UInt32), process(UInt32), screenPermission, micPermission
            var label: String {
                switch self {
                case .settings: String(localized: "打开设置")
                case .device: String(localized: "去设备页")
                case .download: String(localized: "重新下载")
                case .process: String(localized: "再试一次")
                case .screenPermission, .micPermission: String(localized: "打开系统设置")
                }
            }
        }
    }
    var problem: Problem?
    /// 只有一句话的提示。
    var notice: String? {
        get { problem?.title }
        set { problem = newValue.map { Problem(title: $0) } }
    }
    /// 窗口顶部滑出来的一条轻提示，几秒后自己消失。
    var banner: Banner?
    /// `undo`：这条提示能撤销时，要恢复的「最近删除」条目。
    struct Banner: Equatable { var icon: String; var text: String; var undo: [UUID] = []; var id = UUID() }

    /// 照着提示里给的办法去做。
    func resolve(_ action: Problem.Action) {
        switch action {
        case .download(let id): download(id)
        case .process(let id): process(id)
        #if os(macOS)
        case .screenPermission:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        case .micPermission:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        #else
        case .screenPermission, .micPermission:
            // 手机上只能跳到豆仓自己的那一页设置
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        #endif
        case .settings, .device: break      // 这两个要换页面，由界面自己处理
        }
    }

    func toast(_ icon: String, _ text: String, undo: [UUID] = [], seconds: Double? = nil) {
        let b = Banner(icon: icon, text: text, undo: undo)
        banner = b
        // 能撤销的多留一会儿，给人反应的时间
        Task { try? await Task.sleep(for: .seconds(seconds ?? (undo.isEmpty ? 3.5 : 7))); if banner == b { banner = nil } }
    }

    /// 录音豆是不是在充电盒里（在盒里时它在充电）。
    var inCase: Bool { info?.micCharging == true }
    var log: [String] = []

    @ObservationIgnored private let ble = BLEClient()
    /// 得到 AI 录音卡（CardSync.swift）：和录音豆各连各的，下载下来的录音进同一个录音库。
    let card = CardSync()
    @ObservationIgnored private var crypto = CryptoSession()
    @ObservationIgnored private var job: PullJob?
    @ObservationIgnored private var listPages: [RemoteFile] = []
    @ObservationIgnored private var listPage = 0
    @ObservationIgnored private var activeFileID: UInt32 = 0
    /// 设备眼里的「当前录音」：暂停不算结束，再开始会接着往这条里录。0 表示没有。
    @ObservationIgnored var currentDeviceFile: UInt32 = 0
    @ObservationIgnored private var listToken = 0
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored var worker: Task<Void, Never>?
    @ObservationIgnored var workQueue: [UInt32] = []
    /// 要重新转写的录音：旧文字稿留到新的转出来为止
    @ObservationIgnored var retranscribing: Set<UInt32> = []
    /// 这几条重新转写时走云端（录音页「交给云端重转」），不管平时用哪个引擎。
    @ObservationIgnored var viaCloud: Set<UInt32> = []

    private struct PullJob {
        let id: UInt32
        var expected: Int
        var decryptor: FileDecryptor?
        var encrypted = false
        var data = Data()
        var packets = 0
        var lastActivity = Date()
        /// 续传了几次，以及上次续传时已经收到多少，用来判断续传还有没有进展。
        var resumes = 0
        var sizeAtResume = 0
        /// 带标记的切片序号：录音时在录音豆上按过标记键的位置。
        var marks: Set<UInt32> = []
        /// 没等到数据时已经重新要过一次了。
        var retried = false
    }

    /// 示例数据模式（启动参数 -demo）：用 BeanPod/Demo/Recordings 里的示例录音库，不连蓝牙、不开 MCP、不同步飞书。
    /// 给 README 截图用，不碰真实录音（示例库由 scripts/make-demo-library.py 生成）。
    nonisolated static let demo = CommandLine.arguments.contains("-demo")

    let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(BeanStore.demo ? "BeanPod/Demo/Recordings" : "BeanPod/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() {
        loadLibrary()
        loadTrash()
        loadProjects()
        refreshASRAvailability()
        watchInbox()
        #if os(macOS)
        if !Self.demo { installCLI(); startMCPServer() }
        #endif
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if self?.settings.autoProcess == true { self?.upgradeRoughNotes() }
        }
        // 最近删除：到期的彻底删掉。启动时一次，之后每 6 小时一次
        Task { [weak self] in
            while let self {
                self.purgeTrash()
                self.purgeDictationAudio()
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
        ble.onLink = { [weak self] in self?.linkChanged($0) }
        ble.onFound = { [weak self] in self?.found = $0; self?.autoConnectIfObvious() }
        ble.onPacket = { [weak self] in self?.handle($0) }
        ble.onLog = { [weak self] in self?.addLog($0) }
        guard !Self.demo else { addLog("示例数据模式：\(recordings.count) 条示例录音，不连设备"); return }
        ble.start()
        #if os(macOS)
        attachXiaomi()
        #endif
        card.attach(self)
        // 没有记住的设备时，一打开就开始找，不用先点进设备页
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            if let self, self.link == .idle { self.scan() }
            self?.card.scanBriefly()
        }
        addLog("密盒助手启动，本地录音 \(recordings.count) 条")
    }

    // MARK: 连接

    func scan() {
        ble.scan()
        if card.link == .idle { card.scan() }
        #if os(macOS)
        if xiaomiLink != .scanning && xiaomiLink != .ready && xiaomiLink != .connecting { xiaomi.scan() }
        #endif
    }

    /// 附近只有一颗录音豆时，不用再点一下，直接连。用户主动断开过就不自动连，免得刚断开又连上。
    @ObservationIgnored var autoConnectAllowed = true
    @ObservationIgnored private var autoConnectTask: Task<Void, Never>?

    private func autoConnectIfObvious() {
        guard autoConnectAllowed, link == .scanning, autoConnectTask == nil else { return }
        guard found.filter(\.isBean).count == 1 else { return }
        autoConnectTask = Task { [weak self] in
            // 等一秒多，确认附近真的只有这一颗
            try? await Task.sleep(for: .milliseconds(1200))
            guard let self else { return }
            self.autoConnectTask = nil
            let beans = self.found.filter(\.isBean)
            if self.link == .scanning, beans.count == 1, let only = beans.first { self.connect(only) }
        }
    }
    func stopScan() {
        ble.stopScan()
        card.stopScan()
        #if os(macOS)
        xiaomi.stopScan()
        #endif
    }

    // Wi‑Fi 快传要用到的几样（见 WiFiSync.swift）
    var sessionCrypto: CryptoSession { crypto }
    func dropBLEForWiFi() { autoConnectAllowed = false; ble.disconnect(forget: false) }
    func resumeBLEAfterWiFi() { autoConnectAllowed = true; ble.reconnect() }
    /// 停下正在进行的蓝牙下载，并告诉录音豆别再传了。返回刚才是不是真有一条在传。
    func haltBLEDownloads() -> Bool {
        let active = job != nil
        cancelDownloads()
        if active { ble.send(Command.stopTransfer()) }
        return active
    }
    /// 把一条录音从下载里拿掉：排着队的取消排队，正在传的停下。
    func dropFromDownloads(_ id: UInt32) {
        queue.removeAll { $0 == id }
        if job?.id == id {
            failPull(id, nil)
            ble.send(Command.stopTransfer())
        }
    }
    /// 这条录音是不是在排队等下载（蓝牙的队列，或者这一次快传里还没轮到的）。
    func isQueued(_ id: UInt32) -> Bool {
        queue.contains(id) || (wifi.map { $0.waiting.contains(id) } ?? false)
    }
    func connect(_ device: FoundDevice) { deviceName = device.name; ble.connect(device.id) }
    func disconnect(forget: Bool = true) { autoConnectAllowed = false; ble.disconnect(forget: forget) }
    var waitingForKnownDevice: Bool { link == .connecting && ble.hasRememberedDevice }

    private func linkChanged(_ new: BLEClient.Link) {
        let old = link
        link = new
        if new == .ready, old != .ready { toast("checkmark.circle.fill", String(localized: "密盒已连接")); Self.chime() }
        if old == .ready, new != .ready, wifi == nil { toast("wifi.slash", String(localized: "密盒已断开")) }
        poller?.cancel()
        guard new == .ready else {
            if let job { failPull(job.id, String(localized: "连接断开，下载中断")) }
            // 录音中断线：实时字幕收个尾关掉。不关的话它会一直挂着，以后每次录音都开不起来
            if liveActive { Task { await endLiveTranscript() } }
            queue.removeAll()
            info = nil; encryptionReady = false; loadingList = false
            syncOnConnect = false
            // Wi‑Fi 快传是自己主动断开蓝牙的：还没下载的那几条正要传，不能从列表里清掉
            if wifi != nil { return }
            for i in recordings.indices { recordings[i].onDevice = false }
            recordings.removeAll { !$0.downloaded }
            return
        }
        if let name = ble.connectedName, !name.isEmpty { deviceName = name }
        crypto = CryptoSession()
        syncOnConnect = settings.autoDownload || wifiFallback
        reportOnConnect = !wifiFallback
        wifiFallback = false
        scratchTried = []
        currentDeviceFile = 0
        // 用 Mac 录到一半时录音豆自己连上了：计时属于 Mac 那条录音，不能清零
        if macRec == .off && !macStarting { sessionOpen = false; elapsedBase = 0; recordingSince = nil }
        Task {
            // 设备处理命令需要一点间隔，挨个发
            ble.send(Command.deviceInfo())
            try? await Task.sleep(for: .milliseconds(400))
            ble.send(Command.syncTime())
            try? await Task.sleep(for: .milliseconds(300))
            ble.send(Command.keyExchange(publicKey: crypto.publicKey))
            try? await Task.sleep(for: .milliseconds(400))
            refreshFiles()
        }
        poller = Task { [weak self] in
            // 平时一分钟问一次状态；录音的时候五秒问一次，这样在录音豆上按键停下，这边很快就知道
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                ticks += 1
                guard let self, !Task.isCancelled, self.link == .ready, self.job == nil else { continue }
                guard ticks % 12 == 0 || (self.info?.recording == true && self.macRec == .off) else { continue }
                self.ble.send(Command.deviceInfo())
            }
        }
    }

    // MARK: 设备操作

    var isRecording: Bool {
        #if os(macOS)
        if let xiaomiCapture { return xiaomiCapture.started != nil }
        #endif
        return macRec == .recording || (link == .ready && info?.recording == true)
    }

    /// 用这台 Mac 的麦克风录音时的状态。
    var macRec: MacRec = .off
    #if os(macOS)
    @ObservationIgnored var macMicrophone: MacMicrophoneCapture?
    @ObservationIgnored var macCaptionTask: Task<Void, Never>?
    @ObservationIgnored var macCaptionSession: UUID?
    #endif
    @ObservationIgnored var macRecorder: AVAudioRecorder?
    @ObservationIgnored var macMeter: Task<Void, Never>?
    @ObservationIgnored var macTap: SystemAudioTap?
    @ObservationIgnored var macMicStarted: Date?
    @ObservationIgnored var macStarting = false
    @ObservationIgnored var dictationCaptureID: UUID?
    /// 录音豆连着，但这次想用 Mac 录。录音豆断开后自然就是用 Mac，不用管这个。
    var preferMac = false
    var usesMacSource: Bool { link != .ready || preferMac }
    /// 点「开始录音」时声音从哪来。
    var sourceName: String {
        #if os(macOS)
        if let xiaomiCapture { return xiaomiCapture.name }
        #endif
        return usesMacSource ? macSource.name : displayDeviceName
    }
    var sourceIcon: String {
        #if os(macOS)
        if xiaomiRecording { return "appletvremote.gen4.fill" }
        #endif
        return usesMacSource ? macSource.icon : "dot.radiowaves.left.and.right"
    }
    /// 用 Mac 录音时录哪一路：麦克风、电脑里的声音，还是两路一起。会记住上次的选择。
    var macSource: MacSource = MacSource(rawValue: UserDefaults.standard.string(forKey: "macSource") ?? "") ?? .mic {
        didSet { UserDefaults.standard.set(macSource.rawValue, forKey: "macSource") }
    }
    func chooseMacSource(_ source: MacSource) {
        macSource = source
        preferMac = link == .ready
    }
    /// 现在这条是不是用 Mac 的麦克风在录。
    var recordingOnMac: Bool { macRec != .off }

    enum RecState { case idle, recording, paused }

    /// 录音豆现在的状态：没在录、正在录、录到一半暂停着。
    var recState: RecState {
        #if os(macOS)
        if let xiaomiCapture { return xiaomiCapture.started == nil ? .paused : .recording }
        #endif
        if macRec != .off { return macRec == .recording ? .recording : .paused }
        guard link == .ready else { return .idle }
        if info?.recording == true { return .recording }
        return sessionOpen ? .paused : .idle
    }

    /// 已经录了多久（暂停的时间不算）。
    func elapsed(at now: Date = .now) -> TimeInterval {
        #if os(macOS)
        if let xiaomiCapture { return xiaomiCapture.elapsed(at: now) }
        #endif
        return elapsedBase + (recordingSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    func startRecording() {
        guard dictationCaptureID == nil else { toast("waveform", String(localized: "语音输入正在进行，请稍后再录音")); return }
        if justRecorded != nil { keepJustRecorded() }   // 上一条还没说留不留就又开始录了：当作留着
        // 录音豆没连上：直接用这台 Mac 的麦克风录
        if usesMacSource, recState == .idle { startMacRecording(); return }
        guard link == .ready, recState == .idle else { return }
        ble.send(Command.startRecording())
        info?.recording = true          // 先把界面切过去，不等设备回话
        sessionOpen = true
        elapsedBase = 0
        recordingSince = .now
        liveMarks = []
        sessionStart = .now
        beginLiveTranscript(reset: true)
        confirmSoon()
    }

    func pauseRecording() {
        #if os(macOS)
        guard !xiaomiRecording else { return }
        #endif
        if macRec != .off { pauseMacRecording(); return }
        guard recState == .recording else { return }
        ble.send(Command.pauseRecording())
        elapsedBase = elapsed()
        recordingSince = nil
        info?.recording = false
        liveFlush = true
        confirmSoon()
    }

    func resumeRecording() {
        #if os(macOS)
        guard !xiaomiRecording else { return }
        #endif
        guard dictationCaptureID == nil else { toast("waveform", String(localized: "语音输入正在进行，请稍后再录音")); return }
        if macRec != .off { resumeMacRecording(); return }
        guard recState == .paused else { return }
        ble.send(Command.startRecording())
        info?.recording = true
        recordingSince = .now
        // 接着录：实时声音也接着要
        if live == nil { beginLiveTranscript(reset: false) }
        else if currentDeviceFile != 0 { ble.send(Command.pullFile(currentDeviceFile, offset: 0, realtime: true)) }
        confirmSoon()
    }

    /// 结束这条录音。结束后设备才把它当成一条完整的录音，才能下载；下次再录是新的一条。
    func finishRecording() {
        #if os(macOS)
        if xiaomiRecording { finishXiaomiRecording(); return }
        #endif
        if macRec != .off { finishMacRecording(); return }
        guard link == .ready, recState != .idle else { return }
        let fid = currentDeviceFile, seconds = elapsed()
        ble.send(Command.stopRecording())
        if !liveMarks.isEmpty, let since = sessionStart {
            pendingMarks.append((since, currentDeviceFile, liveMarks))
        }
        // 先问一句留不留。问的这几秒里不下载、不整理；不知道是哪一条（录音豆没报编号）就不问，照旧直接下载
        let ask = settings.askKeep && fid != 0
        if ask { offerKeep(id: fid, seconds: seconds, from: displayDeviceName, onMac: false) }
        elapsedBase = 0
        recordingSince = nil
        info?.recording = false
        sessionOpen = false
        Task {
            await endLiveTranscript()
            try? await Task.sleep(for: .seconds(1))
            ble.send(Command.deviceInfo())
            try? await Task.sleep(for: .seconds(1))
            pullWhenListed = settings.autoDownload && !ask
            refreshFiles()
        }
    }

    /// 在录音豆上按键停下了录音（不是豆仓让它停的）。
    /// 以前只把状态改成「没在录」，列表里那条还挂着「正在录 · 还在录音豆里」，要手动刷新、手动下载。
    /// 现在：收掉实时出字，按设置问一句留不留，然后重新列一遍、把它下载下来转写整理。
    func deviceStopped(file: UInt32, finished: Bool, seconds: TimeInterval = 0) {
        addLog("密盒自己停止了录音（\(finished ? "结束" : "停下")）：\(file)")
        #if os(macOS)
        let ownsLiveView = !xiaomiRecording
        #else
        let ownsLiveView = true
        #endif
        if ownsLiveView {
            liveFlush = true
            if !liveMarks.isEmpty, let since = sessionStart {
                pendingMarks.append((since, file, liveMarks))
                liveMarks = []
            }
            Task { await endLiveTranscript() }
        }
        let ask = finished && settings.askKeep && file != 0 && !scratchFiles.contains(file)
        if ask { offerKeep(id: file, seconds: seconds, from: displayDeviceName, onMac: false) }
        else { syncOnConnect = syncOnConnect || settings.autoDownload; pullWhenListed = settings.autoDownload }
        // 稍等一下再列：设备刚停下时，列表里那条的结束时间还没写好
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if !loadingList, job == nil { refreshFiles() }
        }
    }

    /// 在现在这个时刻打一个重点标记。
    func markNow() {
        guard recState == .recording else { return }
        addMark(elapsed())
        toast("flag.fill", String(localized: "标记了 \(clock(elapsed()))"))
    }

    /// 相隔不到两秒的标记算同一个：按一下标记键，设备会连着标好几个切片。
    private func addMark(_ t: TimeInterval) {
        guard !liveMarks.contains(where: { abs($0 - t) < 2 }) else { return }
        liveMarks.append(t)
    }

    /// 把一串标记时刻合并成干净的列表：排好序，挨得太近的只留一个。
    nonisolated static func mergeMarks(_ times: [TimeInterval]) -> [TimeInterval] {
        var out: [TimeInterval] = []
        for t in times.sorted() where out.last.map({ t - $0 >= 2 }) ?? true { out.append(t) }
        return out
    }

    /// 一个键的开关：没在录就开始，在录或暂停着就结束。
    func toggleRecording() {
        if recState == .idle { startRecording() } else { finishRecording() }
    }

    private func confirmSoon() {
        Task {
            try? await Task.sleep(for: .seconds(1))
            ble.send(Command.deviceInfo())
        }
    }

    func refreshFiles() {
        guard link == .ready, job == nil else { return }
        listToken += 1
        let token = listToken
        listPages = []; listPage = 0; activeFileID = 0; loadingList = true
        ble.send(Command.listFiles(page: 0))
        Task {
            try? await Task.sleep(for: .seconds(8))
            if token == listToken, loadingList { finishList(complete: false) }
        }
    }

    func send(_ frame: Data) { ble.send(frame) }

    /// 录音豆放回充电盒、或从盒里取出来。放回去的时候顺手把还没下载的录音同步下来。
    private func caseChanged(from old: Bool?, to new: Bool) {
        guard let old, old != new else { return }
        if new {
            let pending = recordings.filter { $0.onDevice && !$0.downloaded && !$0.inProgress }.count
            toast("battery.100percent.bolt", pending > 0 && settings.autoDownload ? String(localized: "已开始充电，开始同步 \(pending) 条录音") : String(localized: "正在充电"))
            if settings.autoDownload { pullWhenListed = true; refreshFiles() }
        } else {
            toast("mic.fill", String(localized: "密盒已就绪，可以开始录音"))
        }
    }

    func deleteFromDevice(_ id: UInt32) {
        guard link == .ready else { return }
        deletedOnDevice.insert(id)
        ble.send(Command.deleteFile(id))
    }

    // MARK: 收包

    private func handle(_ p: Packet) {
        let isSlice = p.matches(0x1A, 0x08) || p.matches(0x1A, 0x12)
        if !isSlice { addLog("← \(p.raw.prefix(96).hex)\(p.raw.count > 96 ? " …(\(p.raw.count) 字节)" : "")") }

        switch (p.type, p.id) {
        case (0x01, 0x01):
            if let parsed = DeviceInfo(packet: p) {
                let wasInCase = info?.micCharging
                let wasRecording = info?.recording == true
                info = parsed
                caseChanged(from: wasInCase, to: parsed.micCharging)
                // 它刚才在录、现在停了，而且不是豆仓让它停的（豆仓点暂停或结束时会先把状态改掉，走不到这里）：
                // 是在录音豆上按的键。让实时出字把最后一句收掉，再重新列一遍，该同步的拉下来
                if wasRecording, !parsed.recording, macRec == .off {
                    deviceStopped(file: currentDeviceFile, finished: false)
                }
                // 正在用 Mac 录音时，计时归 Mac 那边管，录音豆报的状态不去动它
                if macRec == .off {
                    if parsed.recording, recordingSince == nil { recordingSince = .now; sessionOpen = true }
                    if !parsed.recording, let since = recordingSince { elapsedBase += Date.now.timeIntervalSince(since); recordingSince = nil }
                }
            }
        case (0x01, 0x03):
            let b = Array(p.payload)
            if b.count >= 2 {
                info?.micBattery = DeviceInfo.batteryPercent(b[0])
                info?.caseBattery = DeviceInfo.batteryPercent(b[1])
            }
        case (0x01, 0x04):
            let b = Array(p.payload)
            if b.count >= 2 {
                let wasInCase = info?.micCharging
                info?.micCharging = b[0] == 1; info?.caseCharging = b[1] == 1
                caseChanged(from: wasInCase, to: b[0] == 1)
            }
        case (0x18, 0x82):
            // 设备会把指令原样回显：01 是开始了，02 是暂停了。以它为准更新状态，
            // 否则语音输入松手后界面还以为在录，下一次按键会被当成「设备正忙」
            if p.isSuccess, let op = p.payload.first {
                // 豆仓自己点暂停、结束时会先把状态改掉；这里还当它在录，说明是在录音豆上按的键
                let fromDevice = macRec == .off && (info?.recording == true || sessionOpen)
                let file = currentDeviceFile
                switch op {
                case 1:
                    info?.recording = true; sessionOpen = true
                    if recordingSince == nil { recordingSince = .now }
                case 2:
                    if let since = recordingSince { elapsedBase += Date.now.timeIntervalSince(since) }
                    info?.recording = false; recordingSince = nil
                case 0:
                    let seconds = elapsed()
                    info?.recording = false; recordingSince = nil; elapsedBase = 0
                    sessionOpen = false; currentDeviceFile = 0
                    // 在录音豆上按键结束了这一条：和在豆仓里点「结束」一样，问留不留、然后下载转写
                    if fromDevice { deviceStopped(file: file, finished: true, seconds: seconds) }
                default: break
                }
            } else if live == nil {
                problem = Problem(title: String(localized: "密盒没有开始录音"), detail: String(localized: "它可能正在传文件，或者电量太低。等几秒再点一次；还不行就充电后重新连接。"))
            }
        case (0x1A, 0x05):
            wifiReply = p
        case (0x2E, 0x01):
            encryptionReady = crypto.completeHandshake(p)
            addLog(encryptionReady ? "密钥协商成功" : "密钥协商失败")
            syncAfterConnect()
        case (0x1B, 0x0E), (0x1A, 0x0E):
            guard loadingList, let page = FileListPage(packet: p) else { return }
            listPages += page.files
            if page.activeFileID != 0 { activeFileID = page.activeFileID }
            if page.hasMore, listPage < 200 {
                listPage += 1
                listToken += 1
                let token = listToken
                ble.send(Command.listFiles(page: listPage))
                Task {
                    try? await Task.sleep(for: .seconds(8))
                    if token == listToken, loadingList { finishList(complete: false) }
                }
            } else {
                finishList()
            }
        case (0x1A, 0x10):
            addLog(p.isSuccess ? "设备已删除一条录音" : "设备拒绝删除")
            if p.isSuccess { refreshFiles() } else if scratchFiles.isEmpty { problem = Problem(title: String(localized: "密盒没有删掉这条录音"), detail: String(localized: "它可能还在录这一条，或者正在传文件。结束录音、等传完再删。")) }
        case (0x1A, 0x06):
            if info?.recording == false { info?.recording = true }
            let b = Array(p.payload)
            // 记下正在录的是哪一条。以前只有开着实时出字才记，没开的时候结束录音就不知道该问哪一条、该删哪一条
            if b.count >= 4, macRec == .off, live == nil, recordingSince != nil {
                let fid = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
                if fid != 0 { currentDeviceFile = fid }
            }
            // 不是豆仓点的开始，是按了录音豆上的键：这边的计时、实时出字都要跟着启动。
            // 以前只把状态标成「录音中」，计时停在 0:00，要等一分钟一次的状态查询才突然开始走。
            if live == nil, recordingSince == nil, macRec == .off, b.count >= 4 {
                let fid = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
                if fid != 0 {
                    let resumed = sessionOpen && fid == currentDeviceFile   // 同一条录音暂停后接着录
                    addLog("密盒自己开始录音了（\(resumed ? "接着录" : "新的一条")）：\(fid)")
                    currentDeviceFile = fid
                    sessionOpen = true
                    recordingSince = .now
                    if !resumed {
                        elapsedBase = 0
                        #if os(macOS)
                        if !xiaomiRecording { liveMarks = [] }
                        #else
                        liveMarks = []
                        #endif
                        sessionStart = .now
                    }
                    beginLiveTranscript(reset: !resumed)
                    if !resumed { toast("record.circle", String(localized: "密盒开始录音了")) }
                    return
                }
            }
            // 语音输入：设备报出新录音的 id，立刻要求它边录边传
            if live != nil, live?.fileID == nil, b.count >= 4 {
                let fid = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
                if fid != 0 {
                    currentDeviceFile = fid
                    live?.fileID = fid
                    if live?.scratch == true { scratchFiles.insert(fid) }
                    ble.send(Command.pullFile(fid, offset: 0, realtime: true))
                }
            }
        case (0x1A, 0x07) where live != nil && job == nil:
            if let head = FileHead(packet: p) { live?.decryptor = crypto.fileDecryptor(head: head) }
            live?.lastActivity = .now
        case (0x1A, 0x08) where live != nil && job == nil, (0x1A, 0x12) where live != nil && job == nil:
            guard var l = live else { return }
            l.packets += 1
            if l.packets <= 2 { addLog("← 实时切片 #\(l.packets) 长 \(p.raw.count)：\(p.raw.prefix(24).hex)") }
            for s in Slice.parse(p) where l.frames[s.sequence] == nil && s.sequence < 400_000 {
                l.frames[s.sequence] = l.decryptor?.decrypt(s.data, sequence: s.sequence) ?? s.data
                if s.marked, !l.scratch { addMark(Double(s.sequence) * 0.02) }
            }
            l.lastActivity = .now
            // 开头补齐了就叫停，不用把整段再传一遍
            if let until = l.fillUntil, (0..<until).allSatisfy({ l.frames[$0] != nil }) {
                l.fillUntil = nil
                ble.send(Command.stopTransfer())
            }
            live = l
        case (0x1A, 0x07):
            guard var j = job else { return }
            j.lastActivity = .now
            if let head = FileHead(packet: p) {
                if let bytes = head.audioBytes { j.expected = bytes }
                j.encrypted = true
                j.decryptor = crypto.fileDecryptor(head: head)
            }
            job = j
            if j.encrypted, j.decryptor == nil { failPull(j.id, String(localized: "这条录音是加密的，但密钥没协商成功。请断开重连后再试。")) }
        case (0x1A, 0x08), (0x1A, 0x12):
            guard var j = job else { return }
            j.packets += 1
            if j.packets <= 3 || j.packets % 100 == 0 {
                addLog("← 切片包 #\(j.packets) 长 \(p.raw.count)：\(p.raw.prefix(40).hex)")
            }
            for s in Slice.parse(p) {
                if s.marked { j.marks.insert(s.sequence) }
                let plain = j.decryptor?.decrypt(s.data, sequence: s.sequence) ?? s.data
                // 按序号落位：丢包处留空，重传的覆盖原位置
                guard s.offset < 512 * 1024 * 1024 else { continue }
                if s.offset > j.data.count { j.data.append(Data(count: s.offset - j.data.count)) }
                if s.offset == j.data.count { j.data.append(contentsOf: plain) }
                else { j.data.replaceSubrange(s.offset..<min(s.offset + plain.count, j.data.count), with: plain.prefix(j.data.count - s.offset)) }
            }
            j.lastActivity = .now
            job = j
            pull = PullProgress(id: j.id, received: j.data.count, expected: j.expected)
            if j.expected > 0, j.data.count >= j.expected { finishPull() }
        case (0x1A, 0x0A):
            guard var j = job else { return }
            // 中途暂停过的录音，设备传到一段的结尾就会报「传完了」。没拿全就从断点接着要，
            // 直到拿全，或者续传也不再有新数据为止。
            if j.expected > 0, Double(j.data.count) < Double(j.expected) * 0.98, j.data.count > j.sizeAtResume, j.resumes < 200 {
                j.resumes += 1
                j.sizeAtResume = j.data.count
                j.lastActivity = .now
                job = j
                addLog("录音还没传全（\(j.data.count) / \(j.expected)），第 \(j.resumes) 次续传")
                ble.send(Command.pullFile(j.id, offset: UInt32(j.data.count / 160 * 166)))
            } else {
                finishPull()
            }
        default:
            break
        }
    }

    /// complete 为 false：等清单超时了，只拿到一部分，不能拿来判断「哪些录音不见了」。
    private func finishList(complete: Bool = true) {
        loadingList = false
        listToken += 1
        let remote = Dictionary(listPages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        currentDeviceFile = activeFileID
        // 一连上就发现设备上有条没结束的录音（比如在设备上按键录的）：界面上也要显示成暂停中
        if activeFileID != 0, !scratchFiles.contains(activeFileID) { sessionOpen = true }
        else if info?.recording != true {
            // 这条录音在录音豆那边已经结束了：这边的计时和实时出字也收尾
            if sessionOpen, macRec == .off {
                elapsedBase = 0; recordingSince = nil
                if live?.scratch == false { Task { await endLiveTranscript() } }
            }
            sessionOpen = false
        }
        let growing: UInt32? = info?.recording == true && activeFileID != 0 ? activeFileID : nil
        var merged: [Recording] = []
        for var r in recordings.filter(\.downloaded) {
            r.onDevice = remote[r.id] != nil
            r.inProgress = false
            // 本地这份比设备上的短（下载时还在录）：标成没下载，等录完重新下。
            // 旧文件先留着不删，新的下载成功后会自然覆盖它。
            if let f = remote[r.id], f.duration > r.duration + 1 {
                addLog("本地副本比设备上的短（\(Int(r.duration)) 秒 / \(Int(f.duration)) 秒），标记为待重新下载：\(r.id)")
                if playingID == r.id { stop() }
                var fresh = Recording(id: r.id, size: UInt32(f.audioBytes), date: f.startDate, duration: f.duration,
                                      onDevice: true, inProgress: f.id == growing)
                fresh.title = r.title; fresh.starred = r.starred
                merged.append(fresh)
                continue
            }
            merged.append(r)
        }
        let known = Set(merged.map(\.id))
        for f in remote.values where !known.contains(f.id) && !scratchFiles.contains(f.id) {
            merged.append(Recording(id: f.id, size: UInt32(f.audioBytes), date: f.startDate, duration: f.duration,
                                    onDevice: true, inProgress: f.id == growing))
        }
        saveLibrary()
        recordings = merged.sorted { ($0.date ?? .distantPast, $0.id) > ($1.date ?? .distantPast, $1.id) }
        // 正在录的那条，开始时间就是它的 id
        if complete {
            let now = Set(remote.keys)
            let gone = lastDeviceFiles.subtracting(now).subtracting(deletedOnDevice)
            if reportOnConnect { reportOnConnect = false; reportConnected(gone: gone) }
            lastDeviceFiles = now
            deletedOnDevice.formIntersection(now)
        }
        if pullWhenListed { pullWhenListed = false; syncOnConnect = false; downloadAll() }
        syncAfterConnect()
        sweepScratch(remote: Set(remote.keys))
    }

    /// 连上后第一份清单回来时一定说一句：有新录音（自动同步那边会说「开始同步」）、都同步过了、
    /// 或者上次在录音豆里的录音不见了又不是豆仓删的——录音豆同一时间只连一台设备，多半是手机那边连过、同步走了。
    private func reportConnected(gone: Set<UInt32>) {
        let open = sessionOpen ? currentDeviceFile : 0
        let pending = recordings.filter { $0.onDevice && !$0.downloaded && !$0.inProgress && $0.id != open }.count
        let missed = gone.filter { id in
            !recordings.contains { $0.id == id && $0.downloaded } && !trash.contains { $0.recording.id == id }
        }.count
        if !gone.isEmpty {
            addLog("上次在密盒里的 \(gone.count) 条不在了，密盒助手没删过（其中 \(missed) 条没下载过）：\(gone.sorted().map(String.init).joined(separator: " "))")
        }
        if pending > 0 {
            guard !settings.autoDownload else { return }
            announce("arrow.down.circle", String(localized: "密盒里有 \(pending) 条新录音，自动下载关着，可以在录音列表里下载"))
        } else if !gone.isEmpty {
            announce("iphone", String(localized: "密盒里没有新录音：上次在里面的 \(gone.count) 条不见了，可能被手机同步走了"),
                     body: (missed > 0 ? String(localized: "其中 \(missed) 条密盒助手还没下载过。") : "")
                        + String(localized: "密盒同一时间只连一台设备，手机上的设备配套 App 或飞书连过它的话，会把录音同步走，这期间新录的也在那边。"),
                     seconds: 10)
        } else if info?.recording != true, open == 0 {
            announce("checkmark.circle.fill", String(localized: "密盒已连上，录音都同步过了"))
        }
    }

    /// 刚连上录音豆：把在外面录的、还没下载过的录音自动拉下来。
    /// 要等列表和密钥都到位；录音豆正在录的时候不抢它的蓝牙，等它停了再同步。
    private func syncAfterConnect() {
        guard syncOnConnect, link == .ready, encryptionReady, !loadingList, job == nil else { return }
        guard info?.recording != true else { return }
        syncOnConnect = false
        // 还没结束的那条（暂停中）设备不让下载，等用户点了「结束」再同步
        let open = sessionOpen ? currentDeviceFile : 0
        let pending = recordings.filter { $0.onDevice && !$0.downloaded && !$0.inProgress && $0.id != open }
        if !pending.isEmpty {
            addLog("刚连上，自动同步 \(pending.count) 条还没下载的录音")
            announce("arrow.down.circle.fill", String(localized: "密盒里有 \(pending.count) 条新录音，开始同步"), body: String(localized: "下载完会自动转写整理。"))
            pending.forEach { download($0.id) }
        } else if open != 0, recordings.contains(where: { $0.id == open && !$0.downloaded }) {
            toast("pause.circle.fill", String(localized: "密盒里有一条还没结束的录音，点「结束」后会同步过来"))
        }
    }

    /// 清掉语音输入留在设备上的临时录音。每条每次连接只试一回，避免删不掉时反复重试。
    private func sweepScratch(remote: Set<UInt32>) {
        scratchFiles.formIntersection(remote)          // 设备上已经没有的，不用再记
        guard live == nil, job == nil else { return }
        guard let next = scratchFiles.first(where: { !scratchTried.contains($0) && $0 != activeFileID }) else { return }
        scratchTried.insert(next)
        addLog("清理语音输入的临时录音 \(next)")
        deletedOnDevice.insert(next)
        ble.send(Command.deleteFile(next))
    }

    // MARK: 下载

    func download(_ id: UInt32) {
        guard link == .ready, !queue.contains(id), job?.id != id,
              recordings.contains(where: { $0.id == id && $0.onDevice && !$0.downloaded && !$0.inProgress }) else { return }
        queue.append(id)
        startNextPull()
    }

    func downloadAll() { recordings.filter { $0.onDevice && !$0.downloaded && !$0.inProgress }.forEach { download($0.id) } }

    func cancelDownloads() {
        queue.removeAll()
        if let job { failPull(job.id, nil) }
    }

    private func startNextPull() {
        guard job == nil, link == .ready, !queue.isEmpty else { return }
        let id = queue.removeFirst()
        guard let rec = recordings.first(where: { $0.id == id }) else { return startNextPull() }
        job = PullJob(id: id, expected: Int(rec.size))
        pull = PullProgress(id: id, received: 0, expected: Int(rec.size))
        ble.send(Command.pullFile(id))
        Task { [weak self] in
            // 20 秒没有任何数据就判定失败，不限制总时长
            while let self, let j = self.job, j.id == id {
                if !j.data.isEmpty, Date.now.timeIntervalSince(j.lastActivity) > 3 {
                    self.addLog("3 秒没有新数据，按传完处理")
                    self.finishPull()
                    return
                }
                // 设备刚传完上一条，紧接着要下一条时常常只回一个文件头就没下文，隔几秒再要一次就正常
                if j.data.isEmpty, !j.retried, Date.now.timeIntervalSince(j.lastActivity) > 5 {
                    var again = j
                    again.retried = true; again.lastActivity = .now
                    self.job = again
                    self.addLog("没等到数据，再要一次：\(id)")
                    self.ble.send(Command.pullFile(id))
                } else if Date.now.timeIntervalSince(j.lastActivity) > 20 {
                    self.failPull(id, j.data.isEmpty ? String(localized: "设备没有回传数据。把密盒靠近电脑再试一次。") : String(localized: "传输中途停了，请重试。"))
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func finishPull() {
        guard let j = job else { return }
        job = nil; pull = nil
        // 还有下一条要下：让设备歇一秒半再要，不然它容易只回文件头
        defer { if !queue.isEmpty { Task { try? await Task.sleep(for: .seconds(1.5)); startNextPull() } } }
        let usable = j.data.count / OggOpus.frameSize * OggOpus.frameSize
        guard usable > 0 else { problem = Problem(title: String(localized: "这条录音是空的"), detail: String(localized: "密盒里这一条没有声音数据，可能刚开始就结束了。")); return }
        addLog("下载结束：\(j.packets) 个切片包，\(j.data.count) / \(j.expected) 字节")
        if j.expected > 0, Double(j.data.count) < Double(j.expected) * 0.95 {
            problem = Problem(title: String(localized: "这条录音没传完整"), detail: String(localized: "蓝牙中途断了一下，只收到 \(j.expected > 0 ? j.data.count * 100 / j.expected : 0)%。录音还在密盒里，没有丢。"), action: .download(j.id))
            return
        }
        storeAudio(id: j.id, data: j.data, sliceMarks: j.marks)
    }

    /// 把收齐的音频存成文件、记进录音库。蓝牙下载和 Wi‑Fi 快传共用。
    /// `processNow` 为 false 时先不转写整理（快传期间电脑不在原来的网络上，云端模型连不到）。
    @discardableResult
    func storeAudio(id: UInt32, data: Data, sliceMarks: Set<UInt32>, processNow: Bool = true) -> Bool {
        let usable = data.count / OggOpus.frameSize * OggOpus.frameSize
        guard usable > 0 else { return false }
        let packets = OggOpus.frames(fromRaw: data.prefix(usable))
        do {
            try OggOpus.mux(packets: packets).write(to: oggURL(id), options: .atomic)
            let seconds = try OpusDecoder.writeWAV(packets: packets, to: wavURL(id))
            if let i = recordings.firstIndex(where: { $0.id == id }) {
                recordings[i].downloaded = true
                recordings[i].duration = seconds
                // 重点标记：设备上按的（切片里带着）加上在豆仓里点的
                var marks = sliceMarks.map { Double($0) * 0.02 }
                if let k = pendingMarks.firstIndex(where: { m in
                    m.file == id || recordings[i].date.map { abs($0.timeIntervalSince(m.start)) < 15 } ?? false
                }) {
                    marks += pendingMarks.remove(at: k).marks
                }
                recordings[i].marks = Self.mergeMarks(marks.filter { $0 <= seconds + 1 })
                if !recordings[i].marks.isEmpty { addLog("这条录音有 \(recordings[i].marks.count) 个重点标记") }
            }
            saveLibrary()
            if processNow, settings.autoProcess { process(id) }
            return true
        } catch {
            addLog("保存失败，清掉半成品文件 \(id)：\(error.localizedDescription)")
            try? FileManager.default.removeItem(at: oggURL(id))
            try? FileManager.default.removeItem(at: wavURL(id))
            problem = Problem(title: String(localized: "录音没能存到这台 Mac"), detail: String(localized: "\(error.localizedDescription)\n看看磁盘是不是满了。录音还在密盒里，腾出空间后可以重新下载。"), action: .download(id))
            return false
        }
    }

    private func failPull(_ id: UInt32, _ message: String?) {
        guard job?.id == id else { return }
        job = nil; pull = nil
        if let message { problem = Problem(title: String(localized: "这条录音没下载下来"), detail: message, action: .device) }
        startNextPull()
    }

    // MARK: 本地库

    func oggURL(_ id: UInt32) -> URL { folder.appendingPathComponent("\(id).ogg") }
    func wavURL(_ id: UInt32) -> URL { folder.appendingPathComponent("\(id).wav") }
    private var libraryURL: URL { folder.appendingPathComponent("library.json") }

    private func loadLibrary() {
        guard let data = try? Data(contentsOf: libraryURL),
              var list = try? JSONDecoder().decode([Recording].self, from: data) else { return }
        let missing = list.filter { !$0.textOnly && !FileManager.default.fileExists(atPath: wavURL($0.id).path) }
        if !missing.isEmpty { addLog("记录里有 \(missing.count) 条录音的音频文件不在了：\(missing.map(\.id))") }
        list.removeAll { !$0.textOnly && !FileManager.default.fileExists(atPath: wavURL($0.id).path) }
        for i in list.indices { list[i].onDevice = false; list[i].downloaded = true; list[i].inProgress = false }
        recordings = list.sorted { ($0.date ?? .distantPast, $0.id) > ($1.date ?? .distantPast, $1.id) }
    }

    func saveLibrary() {
        let data = try? JSONEncoder().encode(recordings.filter(\.downloaded))
        try? data?.write(to: libraryURL, options: .atomic)
    }

    func rename(_ id: UInt32, to title: String) {
        guard let i = recordings.firstIndex(where: { $0.id == id }) else { return }
        titleEditRevisions[id] = UUID()
        recordings[i].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        recordings[i].titleEdited = !(recordings[i].title ?? "").isEmpty
        saveLibrary()
    }

    /// 从这台设备删除：先移到「最近删除」，7 天内能恢复（Trash.swift）。
    func removeLocal(_ id: UInt32) {
        addLog("用户从本机删除录音 \(id)")
        moveToTrash(id)
    }

    #if os(macOS)
    func reveal(_ id: UInt32) { NSWorkspace.shared.activateFileViewerSelecting([oggURL(id)]) }
    #endif

    /// 连上录音豆时「叮」一声。手机上用一下轻震代替。
    static func chime() {
        #if os(macOS)
        NSSound(named: "Glass")?.play()
        #else
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    // MARK: 播放

    func togglePlay(_ id: UInt32) {
        if playingID == id, let player {
            if player.isPlaying { player.pause(); isPlaying = false } else { player.play(); isPlaying = true; tick() }
            return
        }
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: wavURL(id)) else { problem = Problem(title: String(localized: "这条录音打不开"), detail: String(localized: "这台 Mac 上的音频文件可能坏了。如果密盒里还有这一条，删掉本地副本再重新下载就好。")); return }
        p.enableRate = true; p.rate = playRate
        player = p; playingID = id; playhead = 0
        p.play(); isPlaying = true
        tick()
    }

    func seek(_ time: TimeInterval) { player?.currentTime = time; playhead = time }

    // MARK: 逐句回听（文字稿里点句子、单句循环、这句再听）

    /// 单句循环的那一句：播到句尾跳回句首。loopCount 是第几遍（从 1 起）。
    var loopSpan: ClosedRange<TimeInterval>?
    var loopCount = 0
    /// 「这句再听」：播到这里自己停。
    @ObservationIgnored var stopAt: TimeInterval?

    /// 播一句：loop 为真就一直循环这句，否则播完这句自己停（「这句再听」）。
    func playSpan(_ id: UInt32, _ span: ClosedRange<TimeInterval>, loop: Bool) {
        // 先切到这条、跳到句首（切换录音会 stop()，把循环和停点清掉），再设循环 / 停点
        play(id, at: span.lowerBound)
        // 最后一句的句尾就是音频结尾：留一点余量，不然 100ms 一次的检查容易错过、播放器先自己停了
        let duration = recordings.first { $0.id == id }?.duration ?? span.upperBound
        let end = max(span.lowerBound + 0.3, min(span.upperBound, duration - 0.15))
        loopSpan = loop ? span.lowerBound...end : nil
        loopCount = loop ? 1 : 0
        stopAt = loop ? nil : end
    }

    func endLoop() { loopSpan = nil; loopCount = 0 }

    /// 往前或往后跳几秒。
    func skip(_ id: UInt32, by delta: TimeInterval) {
        guard let r = recordings.first(where: { $0.id == id }) else { return }
        let from = playingID == id ? playhead : 0
        play(id, at: max(0, min(r.duration - 0.2, from + delta)))
    }

    /// 0.5、0.75 给听外语跟读用
    static let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    func setRate(_ rate: Float) {
        playRate = rate
        player?.rate = rate
        UserDefaults.standard.set(rate, forKey: "playRate")
    }

    /// 跳到上一个或下一个重点标记。
    func jumpToMark(_ id: UInt32, forward: Bool) {
        guard let r = recordings.first(where: { $0.id == id }), !r.marks.isEmpty else { return }
        let now = playingID == id ? playhead : 0
        // 往回跳时留三秒余量：刚跳到一个标记，再按一次应该去更前面那个
        let target = forward ? r.marks.first { $0 - 2 > now + 0.5 } : r.marks.last { $0 - 2 < now - 3 }
        if let target { play(id, at: max(0, target - 2)) }
    }

    /// 回听时补一个重点标记，或者把已有的去掉。
    func addMark(_ id: UInt32, at time: TimeInterval) {
        guard let i = recordings.firstIndex(where: { $0.id == id }) else { return }
        recordings[i].marks = Self.mergeMarks(recordings[i].marks + [time])
        saveLibrary()
    }

    func removeMark(_ id: UInt32, _ time: TimeInterval) {
        guard let i = recordings.firstIndex(where: { $0.id == id }) else { return }
        recordings[i].marks.removeAll { $0 == time }
        saveLibrary()
    }

    #if os(macOS)
    /// 把录音另存成别的软件能打开的音频文件。
    func exportAudio(_ id: UInt32, m4a: Bool) {
        guard let r = recordings.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel()
        let day = r.date.map { $0.formatted(.iso8601.year().month().day()) + " " } ?? ""
        let safe = String((day + r.displayTitle).map { "/:\\?%*|\"<>".contains($0) ? "-" : $0 })
        panel.nameFieldStringValue = safe + (m4a ? ".m4a" : ".wav")
        panel.allowedContentTypes = [m4a ? .mpeg4Audio : .wav]
        guard panel.runModal() == .OK, let target = panel.url else { return }
        let source = wavURL(id)
        Task {
            do {
                try? FileManager.default.removeItem(at: target)
                if m4a {
                    guard let session = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetAppleM4A) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    try await session.export(to: target, as: .m4a)
                } else {
                    try FileManager.default.copyItem(at: source, to: target)
                }
                toast("checkmark.circle.fill", String(localized: "已导出到「\(target.lastPathComponent)」"))
                addLog("导出音频：\(target.path)")
            } catch {
                problem = Problem(title: String(localized: "音频没导出成功"), detail: error.localizedDescription + String(localized: "\n换一个文件夹再试试。"))
            }
        }
    }
    #endif

    /// 从文字稿的某一句开始播。
    func play(_ id: UInt32, at time: TimeInterval) {
        // 跳到循环那句外面去了：不再循环 / 不再到句尾停
        if let s = loopSpan, !s.contains(time) { endLoop() }
        stopAt = nil          // 「这句再听」的停点只对那一次有效；playSpan 会在跳过去之后重新设
        if playingID != id { togglePlay(id) }
        seek(time)
        if !isPlaying { player?.play(); isPlaying = true; tick() }
    }

    func stop() {
        loopSpan = nil; loopCount = 0; stopAt = nil
        ticker?.cancel(); player?.stop(); player = nil
        playingID = nil; isPlaying = false; playhead = 0
    }

    private func tick() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled, let self, let player = self.player {
                self.playhead = player.currentTime
                // 单句循环：到句尾回句首，记一遍
                if let span = self.loopSpan, self.playhead >= span.upperBound - 0.05 {
                    player.currentTime = span.lowerBound; self.playhead = span.lowerBound; self.loopCount += 1
                }
                // 这句再听：播完这句停在句尾
                if let end = self.stopAt, self.playhead >= end {
                    player.pause(); self.isPlaying = false; self.stopAt = nil
                    return
                }
                if !player.isPlaying {
                    // 循环的是最后一句、播放器已经播到结尾自己停了：回句首接着循环
                    if self.isPlaying, let span = self.loopSpan {
                        player.currentTime = span.lowerBound; self.playhead = span.lowerBound; self.loopCount += 1
                        player.play()
                        try? await Task.sleep(for: .milliseconds(100))
                        continue
                    }
                    if self.isPlaying { self.isPlaying = false; self.playhead = 0 }  // 自然播完
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    @ObservationIgnored private let logFile: FileHandle? = {
        let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/BeanPod.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }()

    func addLog(_ line: String) {
        let stamped = "\(Date.now.formatted(date: .omitted, time: .standard))  \(line)"
        logFile?.write(Data((stamped + "\n").utf8))
        log.append(stamped)
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }
}
