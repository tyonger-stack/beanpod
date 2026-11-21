# Provenance — FunASR macOS helpers

## Runtime executable

- Upstream: https://github.com/modelscope/FunASR
- Release: `runtime-llamacpp-v0.2.6`, published 2026-08-30
- Asset: `funasr-llamacpp-macos-arm64.tar.gz` (7,357,524 bytes)
- Official release URL: https://github.com/modelscope/FunASR/releases/download/runtime-llamacpp-v0.2.6/funasr-llamacpp-macos-arm64.tar.gz
- GitHub release API digest: `sha256:bda59474202b887190f59d25b7b42c714469efae71276072c12fa0a38de68792`
- Locally verified archive SHA-256: `bda59474202b887190f59d25b7b42c714469efae71276072c12fa0a38de68792`
- Extracted items used: `llama-funasr-paraformer` and `llama-funasr-cli`
- Architecture: Mach-O arm64 (`lipo -info` verified)
- Dynamic dependencies: only `/System/Library/...` frameworks and `/usr/lib/libSystem.B.dylib`, `/usr/lib/libc++.1.dylib`; no `@rpath`, no Homebrew path.

The release archive also contains other FunASR executables and a downloader.
The package scripts install only the two named helpers and license notices.

## Model (test acquisition only; never package in the app)

- Publisher/repository: https://huggingface.co/FunAudioLLM/Paraformer-GGUF
- Pinned model revision: `1a5063b305a2b4e418ccffaf7be2c02a3cac6c89`
- File: `paraformer-q8.gguf`
- Size: 236,929,024 bytes
- Hugging Face LFS SHA-256: `42bf76ea1575a336aaca4c1b7c01a82b79113e6d04d0d6b799561bfcf07ee011`
- File's last commit: `45a1221b84fc3403f796b8efef9feedbf9161653` (2026-06-21)
- Model-card license: Apache-2.0 (verify separately before any redistribution).

The official release README specifies `-m paraformer-q8.gguf -a audio.wav`; its
model downloader selects the same repository and q8 filename for `paraformer`.

## Fun-ASR-Nano-2512 model

The Nano helper uses the official encoder/adaptor plus the matching Qwen3-0.6B
decoder. Both files are required. The app downloads weights separately; they are
not included in the application bundle.

- Publisher/repository: https://huggingface.co/FunAudioLLM/Fun-ASR-Nano-GGUF
- Source model: https://huggingface.co/FunAudioLLM/Fun-ASR-Nano-2512
- Pinned model revision: `46e849502a867080d66d351b8dfb1018b607e509`
- Model-card license: Apache-2.0
- `funasr-encoder-f16.gguf`: 469,331,008 bytes; SHA-256 `f92f91d01a24fbed6c863495b2ee8c6a6788144a02858b75743f0946668de8a2`
- `qwen3-0.6b-q8_0.gguf`: 804,753,280 bytes; SHA-256 `819f385dc0e035dccc3d9e7edaf6b7b044b8ba7ace63cbcbf84c7e397eecbf27`
- Total: 1,274,084,288 bytes

The release's `download-funasr-model.sh nano` selects this exact pair by default.
Metadata was checked against the publisher's Hugging Face API with `blobs=true`.

## Nano runtime contract

- Release tag resolves to source commit `a57c05bfe2a91b5e0cb0983479634eba3e28ede5`.
- Source: https://github.com/modelscope/FunASR/blob/a57c05bfe2a91b5e0cb0983479634eba3e28ede5/runtime/llama.cpp/fun-asr-nano/funasr-cli/funasr-cli.cpp
- Invocation: `GGML_METAL_DEVICES=0 llama-funasr-cli --enc ENCODER -m DECODER -a AUDIO --chunk 30`
- The encoder explicitly uses `ggml_backend_cpu_init()` with eight threads; the decoder sets `n_gpu_layers=0`. There is no `--backend`, `-t`, or GPU-layer argument in this release.
- The app must override `GGML_METAL_DEVICES` to `0` in the helper's environment. The linked llama.cpp Metal registry reads this variable as a device count; zero prevents creating Metal devices, including implicit operation offload. Linking the system Metal framework alone does not indicate GPU execution.
- Pinned llama.cpp revision: `803b7fcae893e9caaee3921779628fef83ac0965`. Device-count source: https://github.com/ggml-org/llama.cpp/blob/803b7fcae893e9caaee3921779628fef83ac0965/ggml/src/ggml-metal/ggml-metal.cpp
- Normal stdout is transcription text concatenated across chunks, followed by a newline. Diagnostics and the `[done]` line go to stderr. A `/sil` segment is a silence marker, not transcribed speech.
- `--help` prints usage to stderr and returns status 1. Unsupported flags also return status 1.
- `--srt` changes stdout to SRT entries. The application uses plain-text mode.

## Verified Nano smoke behavior

The signed, packaged helper was exercised on an Apple M4 Max with
`GGML_METAL_DEVICES=0` and the two SHA-verified model files above. Model, output,
KV-cache, and compute buffers were reported as CPU; no Metal device appeared in
the captured runtime logs. The official source model's `example/zh.mp3` at
revision `272c57b82523ada6fd87095e955f8e29100979ab` produced
`开放时间早上九点至下午五点。`.

A one-second all-zero WAV produced `the`, not `/sil`. The application must handle
silent input before invoking this helper; removing `/sil` alone does not prevent
silence hallucinations. This smoke check establishes local execution and CPU
selection, not broad recognition accuracy.
