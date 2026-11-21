import Foundation

/// The two FunASR models that use executables bundled with the Mac app.
nonisolated enum FunASRModel: String, Sendable {
    case paraformer
    case nano = "fun-asr-nano-2512"

    var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeanPod/Models/\(rawValue)", isDirectory: true)
    }

    var files: [ModelFile] {
        switch self {
        case .paraformer:
            [ModelFile(name: "paraformer-q8.gguf", repo: "FunAudioLLM/Paraformer-GGUF",
                       revision: "1a5063b305a2b4e418ccffaf7be2c02a3cac6c89", size: 236_929_024,
                       sha256: "42bf76ea1575a336aaca4c1b7c01a82b79113e6d04d0d6b799561bfcf07ee011")]
        case .nano:
            [ModelFile(name: "funasr-encoder-f16.gguf", repo: "FunAudioLLM/Fun-ASR-Nano-GGUF",
                       revision: "46e849502a867080d66d351b8dfb1018b607e509", size: 469_331_008,
                       sha256: "f92f91d01a24fbed6c863495b2ee8c6a6788144a02858b75743f0946668de8a2"),
             ModelFile(name: "qwen3-0.6b-q8_0.gguf", repo: "FunAudioLLM/Fun-ASR-Nano-GGUF",
                       revision: "46e849502a867080d66d351b8dfb1018b607e509", size: 804_753_280,
                       sha256: "819f385dc0e035dccc3d9e7edaf6b7b044b8ba7ace63cbcbf84c7e397eecbf27")]
        }
    }
}
