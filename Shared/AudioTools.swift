@preconcurrency import AVFoundation
import Foundation

nonisolated enum ASRError: LocalizedError {
    case noServer, noModel, startFailed(String), http(Int, String), badAudio

    var errorDescription: String? {
        switch self {
        case .noServer: String(localized: "没找到 llama-server。请安装 llama.cpp（brew install llama.cpp），或在设置里指定它的位置。")
        case .noModel: String(localized: "没找到所选本机转写模型文件。请在设置里下载。")
        case .startFailed(let why): String(localized: "本机转写服务没启动起来：\(why)")
        case .http(let code, let body): String(localized: "转写服务返回错误 \(code)：\(String(body.prefix(160)))")
        case .badAudio: String(localized: "这条录音读不出来")
        }
    }
}

/// 读音频、切段、算音量、写 WAV。Mac 上的本机转写和手机上的云端转写都用这一套。
extension QwenASR {
    // MARK: 音频处理

    nonisolated static func loadMono16k(_ url: URL) throws -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else { throw ASRError.badAudio }
        let format = file.processingFormat
        if format.sampleRate == 16000, format.channelCount == 1 {
            let length = file.length
            guard length > 0 else { return [] }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(min(length, 65536))),
                  let channel = buffer.floatChannelData?[0] else { throw ASRError.badAudio }
            var samples: [Float] = []
            samples.reserveCapacity(Int(length))
            // A read can return fewer frames than requested, including for Float32 WAV.
            while file.framePosition < length {
                try file.read(into: buffer)
                guard buffer.frameLength > 0 else { throw ASRError.badAudio }
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            }
            return samples
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw ASRError.badAudio
        }
        try file.read(into: input)
        guard let converter = AVAudioConverter(from: format, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(input.frameLength) * 16000 / format.sampleRate) + 1024) else {
            throw ASRError.badAudio
        }
        nonisolated(unsafe) var pending: AVAudioPCMBuffer? = input
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if let b = pending { pending = nil; status.pointee = .haveData; return b }
            status.pointee = .endOfStream; return nil
        }
        guard error == nil, let d = output.floatChannelData else { throw ASRError.badAudio }
        return Array(UnsafeBufferPointer(start: d[0], count: Int(output.frameLength)))
    }

    /// 切成不超过 28 秒的段，切点选在 20–28 秒之间最安静的地方，尽量不把一句话拦腰切断。
    nonisolated static func chunk(_ samples: [Float], rate: Int = 16000) -> [Range<Int>] {
        let maxLen = 28 * rate, minLen = 20 * rate, window = rate / 5
        var ranges: [Range<Int>] = []
        var start = 0
        while samples.count - start > maxLen {
            var best = start + maxLen, bestEnergy = Float.greatestFiniteMagnitude
            var i = start + minLen
            while i + window <= start + maxLen {
                var e: Float = 0
                for j in stride(from: i, to: i + window, by: 4) { e += samples[j] * samples[j] }
                if e < bestEnergy { bestEnergy = e; best = i + window / 2 }
                i += window / 2
            }
            ranges.append(start..<best)
            start = best
        }
        if samples.count - start > rate / 4 { ranges.append(start..<samples.count) }
        return ranges
    }

    /// 沿着停顿把整段声音切成句子：每段最长 15 秒，切点落在停顿上。
    nonisolated static func sentenceChunks(_ samples: [Float], rate: Int = 16000) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        let longest = 15 * rate
        while samples.count - start > longest {
            let window = Array(samples[start..<(start + longest)])
            let frames = BeanStore.lastPause(in: window, forced: true) ?? (longest / 320)
            let cut = max(rate * 3 / 2, min(frames * 320, longest))
            ranges.append(start..<(start + cut))
            start += cut
        }
        if samples.count - start > rate / 4 { ranges.append(start..<samples.count) }
        return ranges
    }

    nonisolated static func rms(_ s: [Float]) -> Float {
        guard !s.isEmpty else { return 0 }
        var e: Float = 0
        for v in s { e += v * v }
        return (e / Float(s.count)).squareRoot()
    }

    nonisolated static func wav(_ samples: [Float], rate: Int = 16000) -> Data {
        var d = Data(capacity: 44 + samples.count * 2)
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + samples.count * 2)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(samples.count * 2)
        for s in samples {
            withUnsafeBytes(of: Int16(max(-1, min(1, s)) * 32767).littleEndian) { d.append(contentsOf: $0) }
        }
        return d
    }
}
