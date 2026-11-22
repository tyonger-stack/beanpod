import Foundation

/// Stateful IMA ADPCM decoder for Xiaomi remote audio (16 kHz, mono).
/// Audio notifications contain raw bytes, with the high nibble decoded first.
/// The caller resets the state on SYNC; notification boundaries do not reset it.
public struct XiaomiRemoteAudio {
    private var predictor = 0
    private var stepIndex = 0

    public init() {}

    public mutating func reset(predictor: Int16 = 0, stepIndex: Int = 0) {
        self.predictor = Int(predictor)
        self.stepIndex = min(88, max(0, stepIndex))
    }

    public mutating func ingest(_ packet: Data) -> [Float] {
        var samples: [Float] = []
        samples.reserveCapacity(packet.count * 2)
        for byte in packet {
            samples.append(decode(Int(byte >> 4)))
            samples.append(decode(Int(byte & 0x0F)))
        }
        return samples
    }

    private mutating func decode(_ nibble: Int) -> Float {
        let step = Self.steps[stepIndex]
        var difference = step >> 3
        if nibble & 1 != 0 { difference += step >> 2 }
        if nibble & 2 != 0 { difference += step >> 1 }
        if nibble & 4 != 0 { difference += step }
        predictor += nibble & 8 == 0 ? difference : -difference
        predictor = min(32767, max(-32768, predictor))
        stepIndex = min(88, max(0, stepIndex + Self.indexChanges[nibble & 7]))
        return Float(predictor) / 32768
    }

    private static let indexChanges = [-1, -1, -1, -1, 2, 4, 6, 8]

    private static let steps = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31,
        34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118,
        130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371,
        408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166,
        1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024,
        3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845,
        8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500,
        20350, 22385, 24623, 27086, 29794, 32767,
    ]
}
