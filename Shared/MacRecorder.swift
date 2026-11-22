import AVFoundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 不连录音豆也能录：用这台 Mac（或这台 iPhone）。Mac 上可以录麦克风、录电脑里播放的声音，或者两路一起录；iPhone 上只有麦克风。
/// 录完和录音豆的录音走同一条路——转写、整理、进知识库。
extension BeanStore {
    enum MacRec { case off, recording, paused }

    /// 界面上怎么称呼正在用的这台机器。
    #if os(macOS)
    static let thisDevice = String(localized: "这台 Mac"), deviceShort = "Mac"
    #else
    static let thisDevice = "这台 iPhone", deviceShort = "iPhone"
    #endif

    /// 用 Mac 录音时录哪一路。
    enum MacSource: String, CaseIterable, Identifiable {
        case mic, system, both
        var id: String { rawValue }
        var name: String {
            switch self {
            case .mic: String(localized: "麦克风")
            case .system: String(localized: "电脑里的声音")
            case .both: String(localized: "麦克风 + 电脑里的声音")
            }
        }
        /// 写进录音 origin 的那一路名字，存的是数据，固定中文（旧录音库里就是这么写的）。
        var storedName: String {
            switch self {
            case .mic: "麦克风"
            case .system: "电脑里的声音"
            case .both: "麦克风 + 电脑里的声音"
            }
        }
        var hint: String {
            switch self {
            case .mic: String(localized: "外界的声音：面对面开会、自己口述")
            case .system: String(localized: "电脑里播放的声音：视频、播客、网课")
            case .both: String(localized: "你说的话加对方的声音：线上会议、语音通话")
            }
        }
        var icon: String {
            switch self {
            case .mic: "mic"
            case .system: "desktopcomputer"
            case .both: "mic.badge.plus"
            }
        }
        var usesMic: Bool { self != .system }
        var usesSystem: Bool { self != .mic }
    }

    func startMacRecording(_ source: MacSource? = nil) {
        guard dictationCaptureID == nil else { toast("waveform", String(localized: "语音输入正在进行，请稍后再录音")); return }
        #if os(macOS)
        guard !xiaomiRecording else { return }
        #endif
        guard macRec == .off, !macStarting else { return }
        let source = source ?? macSource
        macSource = source
        macStarting = true
        Task {
            defer { macStarting = false }
            var recorder: AVAudioRecorder?
            var tap: SystemAudioTap?
            var captionNote: String?
            #if os(macOS)
            var microphone: MacMicrophoneCapture?
            if source != .mic {
                captionNote = String(localized: "实时字幕目前只支持麦克风。电脑声音和混合录音会在结束后完整转写。")
            } else if !settings.liveTranscribe {
                captionNote = String(localized: "未开启「边录边出字」。录音结束后会完整转写。")
            } else if !asrAvailable {
                captionNote = localASRReadinessHint
            }
            #endif
            if source.usesMic {
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    problem = Problem(title: String(localized: "密盒助手用不了\(Self.thisDevice)的麦克风"),
                                      detail: String(localized: "到系统设置的「隐私与安全性 → 麦克风」里把密盒助手打开，再点一次录音。"), action: .micPermission)
                    return
                }
            }
            if source.usesSystem {
                let t = SystemAudioTap()
                do { try await t.start() } catch {
                    problem = Problem(title: String(localized: "密盒助手还不能录电脑里的声音"),
                                      detail: String(localized: "系统要你亲自允许一次：到「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」里把密盒助手打开，然后退出密盒助手再重新打开。\n密盒助手只取其中的声音，不会保存屏幕画面。"), action: .screenPermission)
                    addLog("系统声音没开始：\(error.localizedDescription)")
                    return
                }
                tap = t
            }
            if source.usesMic {
                #if os(iOS)
                // 手机上要先向系统申请「我要录音」，否则录音器开不起来；允许蓝牙耳机，别的声音压低
                let session = AVAudioSession.sharedInstance()
                try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
                try? session.setActive(true)
                #endif
                #if os(macOS)
                if source == .mic, settings.liveTranscribe, asrAvailable {
                    do { microphone = try MacMicrophoneCapture() }
                    catch {
                        captionNote = String(localized: "实时字幕未能启动，录音继续，结束后会完整转写。")
                        addLog("麦克风字幕启动失败：\(error.localizedDescription)")
                    }
                }
                let needsRecorder = microphone == nil
                #else
                let needsRecorder = true
                #endif
                if needsRecorder {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("beanpod-mac-\(UUID().uuidString).wav")
                    let format: [String: Any] = [
                        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1,
                        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                    ]
                    guard let r = try? AVAudioRecorder(url: url, settings: format), r.record() else {
                        await tap?.stop()
                        problem = Problem(title: String(localized: "\(Self.thisDevice)的麦克风没有开始录音"), detail: String(localized: "可能有别的软件正占着麦克风，或者没有接入任何麦克风。"))
                        return
                    }
                    r.isMeteringEnabled = true
                    recorder = r
                }
                macMicStarted = .now
            }
            macRecorder = recorder
            macTap = tap
            macRec = .recording
            elapsedBase = 0
            recordingSince = .now
            liveMarks = []; liveSegments = []; liveLevels = []; liveLevelTotal = 0
            liveNote = captionNote
            #if os(macOS)
            macMicrophone = microphone
            if let microphone { beginLocalCaptions(microphone.sink) }
            #endif
            addLog("开始用\(Self.thisDevice)录音：\(source.name)")
            macMeter?.cancel()
            macMeter = Task { [weak self] in
                while let self, !Task.isCancelled, self.macRec != .off {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard self.macRec == .recording else { continue }
                    var level: Float = 0.02
                    if let r = self.macRecorder {
                        r.updateMeters()
                        // 分贝换成 0…1：-50 dB 以下当作安静，-5 dB 算顶
                        level = max(level, min(1, (r.averagePower(forChannel: 0) + 50) / 45))
                    }
                    #if os(macOS)
                    if let microphone = self.macMicrophone {
                        let status = microphone.sink.status()
                        level = max(level, status.level)
                        if status.error != nil {
                            self.liveNote = String(localized: "麦克风采集出现错误，请结束录音并检查输入设备。")
                        } else if status.dropped {
                            self.liveNote = String(localized: "字幕处理较慢，已跳过部分实时字幕。完整录音仍会在结束后转写。")
                        }
                    }
                    #endif
                    if let t = self.macTap { level = max(level, t.takeLevel()) }
                    self.liveLevels = Array((self.liveLevels + [level]).suffix(240))
                    self.liveLevelTotal += 1
                }
            }
        }
    }

    #if os(macOS)
    func beginLocalCaptions(_ sink: MacMicrophoneCapture.Sink, maximumSeconds: Int = 12) {
        let session = UUID()
        macCaptionSession = session
        let server = settings.llamaServerPath, selection = settings.localASRModel
        liveNote = String(localized: "正在准备本机字幕模型，录音已开始…")
        macCaptionTask = Task { [weak self] in
            await QwenASR.shared.warmUp(serverPath: server, selection: selection)
            if let self, self.macCaptionSession == session, !Task.isCancelled {
                self.liveNote = String(localized: "在听，停顿后会显示字幕…")
            }
            while !Task.isCancelled {
                guard let self, self.macCaptionSession == session else { break }
                guard let chunk = sink.takeChunk(final: self.macRec == .paused, maximumSeconds: maximumSeconds) else {
                    do { try await Task.sleep(for: .milliseconds(350)) } catch { break }
                    continue
                }
                guard Self.hasSpeech(chunk.samples) else { continue }
                self.liveNote = String(localized: "正在本机识别这一句…")
                do {
                    let text = try await QwenASR.shared.transcribe(samples: chunk.samples, serverPath: server, selection: selection)
                    guard !Task.isCancelled, self.macCaptionSession == session else { break }
                    if !text.isEmpty, !Self.isFiller(text) {
                        self.liveSegments.append(Segment(start: chunk.start, text: self.applyVocabulary(text)))
                    }
                    self.liveNote = String(localized: "在听，停顿后会显示字幕…")
                } catch {
                    guard !Task.isCancelled, self.macCaptionSession == session else { break }
                    self.liveNote = String(localized: "实时字幕识别失败，录音继续，结束后会重新转写。")
                    self.addLog("本机字幕识别失败：\(error.localizedDescription)")
                    do { try await Task.sleep(for: .seconds(2)) } catch { break }
                }
            }
            await QwenASR.shared.stopIfIdle()
        }
    }
    #endif

    func pauseMacRecording() {
        guard macRec == .recording else { return }
        #if os(macOS)
        macMicrophone?.sink.setPaused(true)
        #endif
        macRecorder?.pause()
        macTap?.setPaused(true)
        elapsedBase = elapsed(); recordingSince = nil
        macRec = .paused
    }

    func resumeMacRecording() {
        guard macRec == .paused else { return }
        #if os(macOS)
        macMicrophone?.sink.setPaused(false)
        #endif
        macRecorder?.record()
        macTap?.setPaused(false)
        recordingSince = .now
        macRec = .recording
    }

    func finishMacRecording() {
        guard macRec != .off else { return }
        let marks = Self.mergeMarks(liveMarks)
        let recorder = macRecorder, tap = macTap, source = macSource, micStarted = macMicStarted
        #if os(macOS)
        let microphone = macMicrophone
        microphone?.stop()
        macMicrophone = nil
        macCaptionSession = nil
        macCaptionTask?.cancel()
        macCaptionTask = nil
        let capturedMicURL = microphone?.url ?? recorder?.url
        #else
        let capturedMicURL = recorder?.url
        #endif
        recorder?.stop()
        macMeter?.cancel(); macMeter = nil
        macRecorder = nil; macTap = nil
        macRec = .off
        elapsedBase = 0; recordingSince = nil
        Task {
            await tap?.stop()
            if let reason = tap?.error { addLog("系统声音采集中途报错：\(reason)") }
            // 把两路声音合成一个文件：各自解成 16 kHz 单声道，按开始时间对齐后相加
            let micURL = capturedMicURL, systemURL = tap?.url, systemStarted = tap?.startedAt
            let mixed: URL? = await Task.detached {
                let out = Self.mixMacAudio(micURL: micURL, systemURL: systemURL, micStarted: micStarted, systemStarted: systemStarted)
                guard out.count > 1600 else { return nil }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("beanpod-mac-\(UUID().uuidString).wav")
                return (try? QwenASR.wav(out).write(to: url, options: .atomic)) != nil ? url : nil
            }.value
            for u in [micURL, systemURL].compactMap({ $0 }) { try? FileManager.default.removeItem(at: u) }
            guard let mixed else {
                problem = Problem(title: String(localized: "这次没有录到声音"),
                                  detail: source.usesSystem ? String(localized: "电脑里这段时间没有播放任何声音，或者系统没有把声音交给密盒助手。") : String(localized: "麦克风没有录到内容。"))
                return
            }
            let before = Set(recordings.map(\.id))
            // 开着「录完先问一句」时先不整理，等用户说留着再整理
            importFile(mixed, consume: true, processNow: !settings.askKeep)
            // 刚导进来的那一条：标上来源和重点标记，标题留空（先显示时间，整理完会自动起名）
            if let i = recordings.firstIndex(where: { !before.contains($0.id) }) {
                recordings[i].origin = Self.deviceShort + " · " + source.storedName
                recordings[i].title = nil
                recordings[i].marks = marks.filter { $0 <= recordings[i].duration + 1 }
                saveLibrary()
                addLog("Mac 录音结束（\(source.name)）：\(Int(recordings[i].duration)) 秒，\(marks.count) 个标记")
                if settings.askKeep { offerKeep(id: recordings[i].id, seconds: recordings[i].duration, from: Self.thisDevice, onMac: true) }
            }
        }
    }
    nonisolated static func mixMacAudio(micURL: URL?, systemURL: URL?, micStarted: Date?, systemStarted: Date?) -> [Float] {
        let mic = micURL.flatMap { decodeAnyAudio($0) } ?? []
        var system = systemURL.flatMap { decodeAnyAudio($0) } ?? []
        if let a = micStarted, let b = systemStarted, !mic.isEmpty, !system.isEmpty {
            let offset = Int(b.timeIntervalSince(a) * 16000)
            if offset > 0 { system = [Float](repeating: 0, count: offset) + system }
            else if offset < 0 { system = Array(system.dropFirst(min(-offset, system.count))) }
        }
        var out = [Float](repeating: 0, count: max(mic.count, system.count))
        for i in mic.indices { out[i] += mic[i] }
        for i in system.indices { out[i] += system[i] }
        if !mic.isEmpty, !system.isEmpty {
            for i in out.indices { out[i] = max(-1, min(1, out[i])) }
        }
        return out
    }

}
