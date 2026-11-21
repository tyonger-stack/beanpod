import Foundation

nonisolated enum ChineseScript {
    static func simplified(_ text: String) -> String {
        // Kana and Hangul identify text whose shared Han characters must stay unchanged.
        let hasJapaneseOrKorean = text.unicodeScalars.contains { scalar in
            guard scalar.properties.generalCategory == .otherLetter else { return false }
            return switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F,
                 0x1B000...0x1B16F, 0x1100...0x11FF, 0x3130...0x318F,
                 0xA960...0xA97F, 0xAC00...0xD7FF, 0xFFA0...0xFFDC:
                true
            default:
                false
            }
        }
        guard !hasJapaneseOrKorean else { return text }
        return text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text
    }
}
