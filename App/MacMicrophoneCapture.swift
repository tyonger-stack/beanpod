@preconcurrency import AVFoundation
import Foundation

final class MacMicrophoneCapture {
    let url: URL
    let sink: Sink
    private let engine = AVAudioEngine()

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("beanpod-mic-\(UUID().uuidString).wav")
        let format = engine.inputNode.outputFormat(forBus: 0)
        sink = try Sink(url: url, format: format)
        // AVAudioEngine calls this on its audio thread.
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { @Sendable [sink] buffer, _ in
            sink.ingest(buffer)
        }
        do { try engine.start() } catch {
            engine.inputNode.removeTap(onBus: 0)
            sink.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        sink.close()
    }

    nonisolated struct Chunk: Sendable {
        let start: TimeInterval
        let samples: [Float]
    }

    nonisolated final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var file: AVAudioFile?
        private let converter: AVAudioConverter
        private let outputFormat: AVAudioFormat
        private var samples: [Float] = []
        private var firstSample = 0
        private var paused = false
        private var level: Float = 0.02
        private var failure: String?
        private var dropped = false
        private var firstBuffer: Date?

        var startedAt: Date? { lock.withLock { firstBuffer } }

        init(url: URL, format: AVAudioFormat) throws {
            guard format.sampleRate > 0, format.channelCount > 0,
                  let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: format, to: mono) else {
                throw CocoaError(.fileWriteUnknown)
            }
            outputFormat = mono
            self.converter = converter
            file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        }

        func ingest(_ buffer: AVAudioPCMBuffer) {
            lock.lock(); defer { lock.unlock() }
            guard !paused, let file else { return }
            do { try file.write(from: buffer) } catch {
                failure = error.localizedDescription
                return
            }
            if firstBuffer == nil, buffer.frameLength > 0 {
                firstBuffer = Date().addingTimeInterval(-Double(buffer.frameLength) / buffer.format.sampleRate)
            }
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate)) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let data = output.floatChannelData?[0] else {
                failure = error?.localizedDescription ?? "PCM conversion failed"
                return
            }
            let incoming = Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
            queueCaptions(incoming)
        }

        /// 接收已解码的 16 kHz 单声道音频，保留整个 WAV，字幕只读取自己的队列。
        func ingestMono16k(_ incoming: [Float], captions: Bool) {
            guard !incoming.isEmpty else { return }
            lock.lock(); defer { lock.unlock() }
            guard let file,
                  let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(incoming.count)),
                  let channel = buffer.floatChannelData?[0] else { return }
            buffer.frameLength = AVAudioFrameCount(incoming.count)
            incoming.withUnsafeBufferPointer { source in
                if let baseAddress = source.baseAddress { channel.update(from: baseAddress, count: source.count) }
            }
            do { try file.write(from: buffer) } catch {
                failure = error.localizedDescription
                return
            }
            if firstBuffer == nil { firstBuffer = .now }
            queueCaptions(incoming, enabled: captions)
        }

        private func queueCaptions(_ incoming: [Float], enabled: Bool = true) {
            guard !incoming.isEmpty else { return }
            let rms = sqrt(incoming.reduce(Float(0)) { $0 + $1 * $1 } / Float(incoming.count))
            level = max(0.02, min(1, (20 * log10(max(rms, 0.00001)) + 50) / 45))
            guard enabled else { return }
            samples.append(contentsOf: incoming)
            let overflow = samples.count - 24 * 16000
            if overflow > 0 {
                samples.removeFirst(overflow)
                firstSample += overflow
                dropped = true
            }
        }

        func setPaused(_ value: Bool) {
            lock.lock(); defer { lock.unlock() }
            paused = value
        }

        func status() -> (level: Float, error: String?, dropped: Bool) {
            lock.lock(); defer { lock.unlock() }
            let result = (level, failure, dropped)
            dropped = false
            return result
        }

        func takeChunk(final: Bool = false, maximumSeconds: Int = 12) -> Chunk? {
            let limit = maximumSeconds * 16000
            let snapshot: (start: Int, window: [Float])? = lock.withLock {
                guard samples.count >= (final ? 4800 : 32000) else { return nil }
                return (firstSample, Array(samples.prefix(limit)))
            }
            guard let (start, window) = snapshot else { return nil }
            let cut: Int
            if final { cut = window.count }
            else if let frames = BeanStore.lastPause(in: window, forced: window.count >= limit) { cut = min(window.count, frames * 320) }
            else { return nil }
            guard cut > 0 else { return nil }
            return lock.withLock {
                guard firstSample == start else { return nil }
                samples.removeFirst(cut)
                firstSample += cut
                return Chunk(start: Double(start) / 16000, samples: Array(window.prefix(cut)))
            }
        }

        func close() {
            lock.lock(); defer { lock.unlock() }
            file = nil
        }
    }
}
