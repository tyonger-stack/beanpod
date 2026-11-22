import Foundation
import Testing
@testable import BeanKit

struct XiaomiRemoteAudioTests {
    @Test func decodesHighNibbleFirstWithExpectedPCM() {
        var decoder = XiaomiRemoteAudio()
        let samples = decoder.ingest(Data([0x17, 0xF0, 0x28]))
        // Hand-calculated IMA samples exercise sign, magnitude and step changes.
        #expect(samples == [1, 12, -18, -14, 4, 1].map { Float($0) / 32768 })
    }

    @Test func preservesStateAcrossEveryPacketBoundary() {
        let stream = Data((0...255).map(UInt8.init))
        var continuous = XiaomiRemoteAudio()
        let expected = continuous.ingest(stream)
        #expect(expected.count == 512)
        for split in 0...stream.count {
            var decoder = XiaomiRemoteAudio()
            var actual = decoder.ingest(stream.prefix(split))
            #expect(decoder.ingest(Data()).isEmpty)
            actual += decoder.ingest(stream.suffix(stream.count - split))
            #expect(actual == expected)
        }
        var bytewise = XiaomiRemoteAudio()
        let actual = stream.flatMap { bytewise.ingest(Data([$0])) }
        #expect(actual == expected)
    }

    @Test func syncResetDiscardsPreviousPredictorAndStep() {
        var decoder = XiaomiRemoteAudio()
        _ = decoder.ingest(Data(repeating: 0x77, count: 50))
        decoder.reset()
        #expect(decoder.ingest(Data([0x17, 0xF0, 0x28])) ==
                [1, 12, -18, -14, 4, 1].map { Float($0) / 32768 })
    }

    @Test func syncResetAcceptsPredictorAndStep() {
        var decoder = XiaomiRemoteAudio()
        decoder.reset(predictor: -1000, stepIndex: 10)
        // step[10] = 19, then step[9] = 17: deltas +6 and -10.
        #expect(decoder.ingest(Data([0x1A])) == [-994, -1004].map { Float($0) / 32768 })
    }

    @Test func clampsPCMAndStepAtBothBounds() {
        var decoder = XiaomiRemoteAudio()
        decoder.reset(predictor: .max, stepIndex: Int.max)
        let positive = decoder.ingest(Data(repeating: 0x77, count: 50))
        #expect(positive == Array(repeating: Float(32767) / 32768, count: 100))
        decoder.reset(predictor: .min, stepIndex: 88)
        let negative = decoder.ingest(Data(repeating: 0xFF, count: 50))
        #expect(negative == Array(repeating: Float(-1), count: 100))
        decoder.reset(stepIndex: Int.min)
        #expect(decoder.ingest(Data(repeating: 0, count: 50)) == Array(repeating: Float(0), count: 100))
    }
}
