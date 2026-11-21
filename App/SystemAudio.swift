import AVFoundation
import ScreenCaptureKit

/// 抓这台 Mac 里正在播放的声音（视频、线上会议里对方说的话），不经过扬声器和麦克风。
/// 用的是系统的屏幕采集接口，只要其中的声音那一路；第一次用系统会问一次「屏幕与系统音频录制」的权限。
nonisolated final class SystemAudioTap: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("beanpod-system-\(UUID().uuidString).caf")
    private let queue = DispatchQueue(label: "beanpod.system-audio")
    private let lock = NSLock()
    private var stream: SCStream?
    private var file: AVAudioFile?
    private var paused = false
    private var peak: Float = 0
    private var firstBuffer: Date?
    private var failure: String?

    /// 第一段声音是什么时候到的，用来和麦克风那一路对齐。
    var startedAt: Date? { lock.withLock { firstBuffer } }
    var error: String? { lock.withLock { failure } }

    func start() async throws {
        // 这一步会触发系统的授权询问；没授权会直接抛错
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CocoaError(.featureUnsupported) }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true      // 不把密盒助手自己放的声音录进去
        config.sampleRate = 48000
        config.channelCount = 2
        // 画面用不上：开到最小、最慢，省电
        config.width = 2; config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        lock.withLock { self.stream = stream }
    }

    func setPaused(_ on: Bool) { lock.withLock { paused = on } }

    /// 上次问过之后最响的一下（0…1），画波形用。
    func takeLevel() -> Float {
        lock.withLock { defer { peak = 0 }; return peak }
    }

    func stop() async {
        let s = lock.withLock { () -> SCStream? in defer { stream = nil }; return stream }
        try? await s?.stopCapture()
        queue.sync { file = nil }       // 等最后一段写完再关文件
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let description = sampleBuffer.formatDescription else { return }
        if lock.withLock({ paused }) { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        do {
            try sampleBuffer.withAudioBufferList { list, _ in
                guard let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer) else { return }
                if file == nil {
                    file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
                    let duration = Double(pcm.frameLength) / format.sampleRate
                    lock.withLock { firstBuffer = Date().addingTimeInterval(-duration) }
                }
                try file?.write(from: pcm)
                // 这一小段的音量
                if let channels = pcm.floatChannelData, pcm.frameLength > 0 {
                    var energy: Float = 0
                    let n = Int(pcm.frameLength)
                    for i in 0..<n { let v = channels[0][i]; energy += v * v }
                    let level = min(1, (energy / Float(n)).squareRoot().squareRoot() * 2.2)
                    lock.withLock { peak = max(peak, level) }
                }
            }
        } catch {
            lock.withLock { failure = error.localizedDescription }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.withLock { failure = error.localizedDescription }
    }
}
