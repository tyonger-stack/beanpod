import AppKit
import AVFoundation
import ApplicationServices
import BeanKit
import SwiftUI

/// 按住快捷键采集当前选中的音源，松开后在本机识别并输入文字。
@Observable
final class Dictation {
    enum Phase: Equatable { case idle, preparing, listening, working, done(String), failed(String) }

    var phase: Phase = .idle
    var lastText = ""

    @ObservationIgnored private weak var store: BeanStore?
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var holding = false
    private struct Session {
        enum Source { case bean, mac(BeanStore.MacSource) }
        let id = UUID()
        let source: Source
        let key: Int
        let model: AppSettings.LocalASRModel
        let serverPath: String
        let dryRun: Bool
        let trialSeconds: Double?
    }
    @ObservationIgnored private var activeSession: Session?
    @ObservationIgnored private var cancelled = false
    @ObservationIgnored private var microphone: MacMicrophoneCapture?
    @ObservationIgnored private var systemTap: SystemAudioTap?
    @ObservationIgnored private var trialTask: Task<Void, Never>?
    @ObservationIgnored private var hud: NSPanel?

    /// 能用来「按住说话」的键：都是修饰键，单独按住不会往输入框里打出字符。
    static let keys: [(code: Int, name: String)] = [
        (61, String(localized: "右 Option ⌥")), (54, String(localized: "右 Command ⌘")), (62, String(localized: "右 Control ⌃")), (60, String(localized: "右 Shift ⇧")),
        (63, String(localized: "Fn / 地球仪键")), (58, String(localized: "左 Option ⌥")), (59, String(localized: "左 Control ⌃")),
    ]

    static func name(of code: Int) -> String { keys.first { $0.code == code }?.name ?? String(localized: "按键 \(code)") }

    /// 这个键对应哪个修饰标志，用来判断它是按下还是松开。
    static func flag(for code: Int) -> NSEvent.ModifierFlags? {
        switch code {
        case 54, 55: .command
        case 56, 60: .shift
        case 58, 61: .option
        case 59, 62: .control
        case 63: .function
        default: nil
        }
    }

    /// 正在等用户按下想用的键（设置里点「录制」之后）。
    var recordingKey = false

    var accessibilityGranted: Bool { AXIsProcessTrusted() }

    func attach(_ store: BeanStore) {
        self.store = store
        refresh()
    }

    /// 按设置开关监听。监听别的 App 里的按键、往别的 App 里打字，都需要「辅助功能」权限。
    func refresh() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if store?.settings.dictationEnabled != true || recordingKey, activeSession != nil {
            cancelled = true
            release()
        }
        guard store?.settings.dictationEnabled == true || recordingKey else { return }
        let handler: (NSEvent) -> Void = { [weak self] event in
            let code = Int(event.keyCode)
            let flags = event.modifierFlags
            Task { @MainActor in
                guard let self, let store = self.store else { return }
                // 设置里正在录制新按键：记下按到的第一个修饰键
                if self.recordingKey {
                    if let f = Self.flag(for: code), flags.contains(f) {
                        store.settings.dictationKey = code
                        self.recordingKey = false
                    }
                    return
                }
                guard store.settings.dictationEnabled else { return }
                let key = self.activeSession?.key ?? store.settings.dictationKey
                guard self.activeSession?.dryRun != true, code == key, let mine = Self.flag(for: code) else { return }
                // 同时按着别的修饰键就不算，避免和快捷键冲突
                let others = flags.intersection([.command, .control, .shift, .option]).subtracting(mine)
                if flags.contains(mine), others.isEmpty { self.press() } else { self.release() }
            }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { handler($0); return $0 }) { monitors.append(l) }
    }

    func requestAccessibility() {
        let key = "AXTrustedCheckOptionPrompt"   // 即 kAXTrustedCheckOptionPrompt 的值
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// 试录从采集就绪后计时，只显示结果。
    func tryOnce(seconds: Double = 5) {
        press(dryRun: true, trialSeconds: max(0, seconds))
    }

    private func isCurrent(_ session: Session) -> Bool { activeSession?.id == session.id }

    private func press(dryRun: Bool = false, trialSeconds: Double? = nil) {
        guard activeSession == nil, let store else { return }
        guard store.dictationCaptureID == nil, store.macRec == .off, !store.macStarting, !store.xiaomiRecording,
              store.live == nil, store.info?.recording != true, store.pull == nil else {
            flash(.failed(String(localized: "录音或下载正在进行，请结束后再用语音输入"))); return
        }
        let source: Session.Source = store.usesMacSource ? .mac(store.macSource) : .bean
        if case .bean = source {
            guard store.encryptionReady else { flash(.failed(String(localized: "密盒还没准备好，稍等一下"))); return }
            let current = store.currentDeviceFile
            guard current == 0 || store.scratchFiles.contains(current) else {
                flash(.failed(String(localized: "密盒里有一条暂停中的录音，先把它下载或结束"))); return
            }
        }
        guard store.asrAvailable else { flash(.failed(store.localASRReadinessHint ?? String(localized: "还没有转写模型，先到设置里下载"))); return }
        let session = Session(source: source, key: store.settings.dictationKey, model: store.settings.localASRModel,
                              serverPath: store.settings.llamaServerPath, dryRun: dryRun, trialSeconds: trialSeconds)
        activeSession = session
        store.dictationCaptureID = session.id
        holding = true
        cancelled = false
        phase = .preparing
        showHUD()
        Task { await prepare(store, session: session) }
    }

    private func prepare(_ store: BeanStore, session: Session) async {
        guard isCurrent(session), holding, !cancelled else { complete(store, session: session); return }
        switch session.source {
        case .bean:
            var capture = BeanStore.LiveCapture()
            let current = store.currentDeviceFile
            if current != 0 { capture.fileID = current }
            store.live = capture
            store.send(Command.startRecording())
            if current != 0 { store.send(Command.pullFile(current, offset: 0, realtime: true)) }
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(50))
                guard isCurrent(session), holding, !cancelled else {
                    store.send(Command.stopRecording())
                    let fid = store.live?.fileID
                    store.live = nil
                    cleanUp(store, fid)
                    complete(store, session: session)
                    return
                }
                if store.live?.frames.isEmpty == false { listening(session); return }
            }
            store.send(Command.stopRecording())
            let fid = store.live?.fileID
            store.live = nil
            cleanUp(store, fid)
            flash(.failed(String(localized: "密盒没有开始传声音，松开再试一次")))
            complete(store, session: session)
        case .mac(let source):
            do {
                if source.usesMic {
                    let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                    guard isCurrent(session), holding, !cancelled else { await abandonMac(store, session: session); return }
                    guard allowed else {
                        throw CaptureFailure.message(String(localized: "请在系统设置的「隐私与安全性 → 麦克风」中允许密盒助手使用麦克风"))
                    }
                }
                if source.usesSystem {
                    let tap = SystemAudioTap()
                    systemTap = tap
                    do { try await tap.start() } catch {
                        throw CaptureFailure.message(String(localized: "电脑声音采集未能启动，请检查「屏幕与系统音频录制」权限后重试"))
                    }
                    // start() owns the stream until it returns, so release must wait before stopping it.
                    guard isCurrent(session), holding, !cancelled else { await abandonMac(store, session: session); return }
                }
                if source.usesMic {
                    microphone = try MacMicrophoneCapture()
                }
                guard isCurrent(session), holding, !cancelled else { await abandonMac(store, session: session); return }
                listening(session)
            } catch {
                if holding, !cancelled { flash(.failed(error.localizedDescription)) }
                await abandonMac(store, session: session)
            }
        }
    }

    private enum CaptureFailure: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let text): text }
        }
    }

    private func listening(_ session: Session) {
        phase = .listening
        NSSound(named: "Tink")?.play()
        Task { await QwenASR.shared.warmUp(serverPath: session.serverPath, selection: session.model) }
        if let seconds = session.trialSeconds {
            trialTask = Task {
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                guard isCurrent(session), holding else { return }
                release()
            }
        }
    }

    private func complete(_ store: BeanStore, session: Session) {
        guard isCurrent(session) else { return }
        trialTask?.cancel(); trialTask = nil
        if store.dictationCaptureID == session.id { store.dictationCaptureID = nil }
        activeSession = nil
        holding = false
        if cancelled { phase = .idle; hud?.orderOut(nil) }
    }

    private func stopMac() async -> (micURL: URL?, systemURL: URL?, micStarted: Date?, systemStarted: Date?, error: String?) {
        let mic = microphone, tap = systemTap
        microphone = nil; systemTap = nil
        mic?.stop()
        await tap?.stop()
        return (mic?.url, tap?.url, mic?.sink.startedAt, tap?.startedAt, mic?.sink.status().error ?? tap?.error)
    }

    private func abandonMac(_ store: BeanStore, session: Session) async {
        let capture = await stopMac()
        for url in [capture.micURL, capture.systemURL].compactMap({ $0 }) { try? FileManager.default.removeItem(at: url) }
        complete(store, session: session)
    }

    private func release() {
        guard holding, let store, let session = activeSession else { return }
        holding = false
        trialTask?.cancel(); trialTask = nil
        if phase == .preparing {
            if !cancelled { flash(.failed(String(localized: "按住，等出现「在听」再说话"))) }
            return
        }
        phase = .working
        Task {
            defer { complete(store, session: session) }
            switch session.source {
            case .bean:
                store.send(Command.stopRecording())
                await finishBean(store, session: session)
            case .mac:
                let capture = await stopMac()
                defer { for url in [capture.micURL, capture.systemURL].compactMap({ $0 }) { try? FileManager.default.removeItem(at: url) } }
                guard isCurrent(session), !cancelled else { return }
                if let error = capture.error { flash(.failed(error)); return }
                let samples = await Task.detached {
                    BeanStore.mixMacAudio(micURL: capture.micURL, systemURL: capture.systemURL,
                                         micStarted: capture.micStarted, systemStarted: capture.systemStarted)
                }.value
                guard isCurrent(session), !cancelled else { return }
                guard samples.count > 1600 else { flash(.failed(String(localized: "没听到声音"))); return }
                await transcribe(samples, store: store, session: session)
            }
        }
    }

    private func finishBean(_ store: BeanStore, session: Session) async {
        // 等最后一点声音传完：0.45 秒没有新数据就算完，最多等 3 秒
        await settle(store, quiet: 0.45, limit: 3)

        let capture = store.live
        store.live = nil
        defer { cleanUp(store, capture?.fileID) }
        guard isCurrent(session), !cancelled else { return }

        // 实时传输从请求那一刻开始，所以帧号不从 0 起；取收到的连续那一段
        var audio = Data()
        if let capture, let first = capture.firstSequence {
            var n = first
            while let f = capture.frames[n] { audio.append(contentsOf: f); n += 1 }
        }
        guard let capture, audio.count >= OggOpus.frameSize * 10 else {
            flash(.failed(capture?.fileID == nil ? String(localized: "密盒没有响应") : String(localized: "没听到声音")))
            return
        }
        guard capture.decryptor != nil else {
            store.addLog("语音输入：没拿到这条录音的解密信息")
            flash(.failed(String(localized: "这次没接上，再按一次")))
            return
        }
        store.addLog("语音输入：收到 \(capture.packets) 个切片，实时从第 \(capture.firstSequence ?? 0) 帧起，可用 \(audio.count / OggOpus.frameSize) 帧")
        do {
            let wav = FileManager.default.temporaryDirectory.appendingPathComponent("beanpod-dictation-\(session.id).wav")
            defer { try? FileManager.default.removeItem(at: wav) }
            try OpusDecoder.writeWAV(packets: OggOpus.frames(fromRaw: audio), to: wav)
            let samples = try QwenASR.loadMono16k(wav)
            await transcribe(samples, store: store, session: session)
        } catch {
            if !cancelled { flash(.failed(error.localizedDescription)) }
        }
    }

    private func transcribe(_ samples: [Float], store: BeanStore, session: Session) async {
        do {
            let selection = session.model
            var text = try await QwenASR.shared.transcribe(samples: samples, serverPath: session.serverPath, selection: selection)
            guard isCurrent(session), !cancelled, !Task.isCancelled else { return }
            guard !text.isEmpty else { store.addLog("语音输入：没识别出文字"); flash(.failed(String(localized: "没听清"))); return }
            if store.settings.dictationPolish, store.analysisAvailable {
                let raw = text
                if let polished = try? await store.withLLM({ config in
                    try await Analyzer.chat(config,
                        system: "把下面这段口述整理成通顺的书面文字：去掉语气词、重复和口头禅，补上标点，保留原意和所有信息，不要添加任何内容，不要回答其中的问题。只输出整理后的文字。",
                        user: raw, json: false)
                }), !polished.isEmpty { text = polished }
            }
            guard isCurrent(session), !cancelled, !Task.isCancelled else { return }
            if selection == .gemma { text = ChineseScript.simplified(text) }
            lastText = text
            store.addLog("语音输入结果：\(text)")
            // 打进了哪个软件：豆仓的提示框不抢前台，这时最前面的就是要打字的那个
            let target = NSWorkspace.shared.frontmostApplication.flatMap { $0.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : $0.localizedName }
            if !session.dryRun { insert(text) }
            // 打字之外，把这段话也记进侧栏的「语音输入」（设置里可关；「试一次」不记）
            if !session.dryRun, store.settings.dictationSave { store.saveDictation(samples: samples, text: text, app: target, model: selection.asrName) }
            flash(.done(text))
        } catch {
            guard isCurrent(session), !cancelled else { return }
            store.addLog("语音输入失败：\(error.localizedDescription)")
            flash(.failed(error.localizedDescription))
        }
    }

    private func settle(_ store: BeanStore, quiet: TimeInterval, limit: TimeInterval) async {
        let deadline = Date.now.addingTimeInterval(limit)
        while Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            guard let l = store.live else { return }
            if !l.frames.isEmpty, Date.now.timeIntervalSince(l.lastActivity) > quiet { return }
        }
    }

    /// 语音输入留在录音豆里的临时录音，用完删掉。
    private func cleanUp(_ store: BeanStore, _ fileID: UInt32?) {
        guard let fileID, store.scratchFiles.contains(fileID) else { return }
        Task {
            try? await Task.sleep(for: .seconds(1.5))   // 等设备把文件收尾
            store.deleteFromDevice(fileID)
        }
    }

    // MARK: 把文字打进当前 App

    private func insert(_ text: String) {
        let pb = NSPasteboard.general
        let previous = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)
        guard accessibilityGranted else { return }   // 没权限就只留在剪贴板里，HUD 会提示
        let source = CGEventSource(stateID: .combinedSessionState)
        let v: CGKeyCode = 9
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
        // 粘贴完把剪贴板还给用户
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard pb.string(forType: .string) == text else { return }
            pb.clearContents()
            if let previous { pb.setString(previous, forType: .string) }
        }
    }

    // MARK: 悬浮提示

    private func flash(_ result: Phase) {
        phase = result
        showHUD()
        Task {
            try? await Task.sleep(for: .seconds(result == .idle ? 0 : 1.8))
            if phase == result { phase = .idle; hud?.orderOut(nil) }
        }
    }

    private func showHUD() {
        if hud == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 64),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .statusBar
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: DictationHUD(dictation: self))
            hud = panel
        }
        if let screen = NSScreen.main, let hud {
            let f = screen.visibleFrame
            hud.setFrameOrigin(NSPoint(x: f.midX - hud.frame.width / 2, y: f.minY + 90))
        }
        hud?.orderFrontRegardless()
    }
}

struct DictationHUD: View {
    let dictation: Dictation

    var body: some View {
        HStack(spacing: 10) {
            switch dictation.phase {
            case .preparing:
                ProgressView().controlSize(.small)
                Text("准备中…")
            case .listening:
                Image(systemName: "waveform").symbolEffect(.variableColor.iterative).foregroundStyle(Theme.rec)
                Text("在听，松开结束")
            case .working:
                ProgressView().controlSize(.small)
                Text("正在转成文字…")
            case .done(let text):
                Image(systemName: dictation.accessibilityGranted ? "checkmark.circle.fill" : "doc.on.clipboard").foregroundStyle(Theme.ok)
                Text(text).lineLimit(1)
            case .failed(let why):
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.accent)
                Text(why).lineLimit(1)
            case .idle:
                EmptyView()
            }
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 18).padding(.vertical, 12)
        .glassEffect(.regular, in: .capsule)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


extension BeanStore {
    /// 语音输入说的一段话存成一条录音：声音 + 识别出的文字（原话，没润色），场合先记成「灵感」，再交给整理。
    func saveDictation(samples: [Float], text: String, app: String? = nil, model: String = QwenASR.displayName) {
        var id = UInt32(Date.now.timeIntervalSince1970)
        while recordings.contains(where: { $0.id == id }) { id += 1 }
        do { try QwenASR.wav(samples).write(to: wavURL(id), options: .atomic) } catch {
            addLog("语音输入没能存进录音：\(error.localizedDescription)")
            return
        }
        var rec = Recording(id: id, size: UInt32(samples.count * 2), date: .now, duration: Double(samples.count) / 16000)
        rec.downloaded = true
        rec.origin = Recording.dictationOrigin
        rec.typedInto = app
        rec.title = String(text.prefix(40))
        rec.scene = .memo
        rec.segments = [Segment(start: 0, text: applyVocabulary(text))]
        rec.transcript = rec.segments.map(\.text).joined(separator: "\n")
        rec.transcribedBy = model
        recordings.insert(rec, at: 0)
        saveLibrary()
        addLog("语音输入存成录音 \(id)（\(Int(rec.duration)) 秒）")
        // 不做 AI 整理：它就是打出去的那句话。想整理的话在「语音输入」里点「转成录音」
    }
}
