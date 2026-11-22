import AVFoundation
import Foundation

extension BeanStore {
    struct XiaomiCapture {
        let name: String
        let started: Date
        let url: URL
        let sink: MacMicrophoneCapture.Sink
        let captions: Bool
        let audioQueue = DispatchQueue(label: "com.andyhu.beanpod.xiaomi-audio", qos: .userInitiated)
    }

    var xiaomiRecording: Bool { xiaomiCapture != nil }

    var xiaomiLiveStatus: String {
        if xiaomiRecording {
            return liveNote ?? String(localized: "正在等待遥控器传送声音…")
        }
        if !settings.liveTranscribe {
            return String(localized: "未开启「边录边出字」。")
        }
        return localASRReadinessHint ?? String(localized: "本机字幕已就绪。")
    }

    func attachXiaomi() {
        xiaomi.onLink = { [weak self] link in
            guard let self else { return }
            if link != .connecting { self.xiaomiName = self.xiaomi.connectedName }
            self.xiaomiLink = link
            if link == .ready, let name = self.xiaomiName {
                self.toast("checkmark.circle.fill", String(localized: "\(name) 已连接"))
            }
        }
        xiaomi.onFound = { [weak self] in self?.xiaomiFound = $0 }
        xiaomi.onStart = { [weak self] in self?.beginXiaomiRecording() }
        xiaomi.onSamples = { [weak self] samples in
            guard let capture = self?.xiaomiCapture else { return }
            let sink = capture.sink, captions = capture.captions
            capture.audioQueue.async { sink.ingestMono16k(samples, captions: captions) }
        }
        xiaomi.onEnd = { [weak self] in self?.finishXiaomiRecording() }
        xiaomi.onLog = { [weak self] in self?.addLog($0) }
        xiaomi.start()
    }

    func connectXiaomi(_ device: FoundDevice) {
        xiaomiName = device.name
        xiaomi.connect(device.id)
    }

    func disconnectXiaomi() {
        xiaomi.disconnect(forget: true)
    }

    private func beginXiaomiRecording() {
        guard let name = xiaomiName, recState == .idle, !macStarting, dictationCaptureID == nil, live == nil else {
            toast("waveform", String(localized: "有录音或语音输入正在进行，结束后再按住遥控器语音键。"))
            return
        }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("beanpod-remote-\(UUID().uuidString).wav")
        let sink: MacMicrophoneCapture.Sink
        do {
            sink = try MacMicrophoneCapture.Sink(url: url, format: format)
        } catch {
            toast("exclamationmark.circle", String(localized: "无法保存遥控器录音。"))
            addLog("遥控器录音文件创建失败：\(error.localizedDescription)")
            return
        }
        if justRecorded != nil { keepJustRecorded() }
        refreshASRAvailability()
        let captions = settings.liveTranscribe && asrAvailable
        liveMarks = []
        liveSegments = []
        liveLevels = []
        liveLevelTotal = 0
        liveNote = settings.liveTranscribe ? localASRReadinessHint : String(localized: "未开启「边录边出字」。")
        xiaomiCapture = XiaomiCapture(name: name, started: .now, url: url, sink: sink, captions: captions)
        addLog("开始用\(name)录音")
        if captions { beginLocalCaptions(sink, maximumSeconds: 4) }
        macMeter = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
                guard let self, !Task.isCancelled, self.xiaomiRecording else { break }
                let status = sink.status()
                self.liveLevels = Array((self.liveLevels + [status.level]).suffix(240))
                self.liveLevelTotal += 1
                if status.error != nil {
                    self.liveNote = String(localized: "保存遥控器录音出错，已收到的声音会尽量保留。")
                } else if status.dropped {
                    self.liveNote = String(localized: "字幕处理较慢，已跳过部分实时字幕。完整录音仍会在结束后转写。")
                }
            }
        }
    }

    func finishXiaomiRecording() {
        guard let capture = xiaomiCapture else { return }
        xiaomiCapture = nil
        // STOP follows the final audio notification. Close after the queued writes have drained.
        capture.audioQueue.sync { capture.sink.close() }
        macMeter?.cancel()
        macMeter = nil
        macCaptionSession = nil
        macCaptionTask?.cancel()
        macCaptionTask = nil
        let marks = Self.mergeMarks(liveMarks)
        liveMarks = []
        if info?.recording == true {
            liveSegments = []
            liveLevels = []
            liveLevelTotal = 0
            liveNote = nil
            beginLiveTranscript()
        }
        let ask = settings.askKeep
        let previous = Set(recordings.map(\.id))
        importFile(capture.url, consume: true, processNow: false)
        guard let i = recordings.firstIndex(where: { !previous.contains($0.id) }) else {
            toast("exclamationmark.circle", String(localized: "这次遥控器没有录到可保存的声音。"))
            return
        }
        recordings[i].origin = capture.name
        recordings[i].title = nil
        recordings[i].marks = marks.filter { $0 <= recordings[i].duration + 1 }
        let id = recordings[i].id
        let duration = recordings[i].duration
        saveLibrary()
        if ask {
            offerKeep(id: id, seconds: duration, from: capture.name, onMac: true)
        } else if settings.autoProcess {
            process(id)
        }
        addLog("遥控器录音已保存（\(capture.name) · \(clock(duration))）")
    }
}
