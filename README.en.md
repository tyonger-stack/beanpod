# Mi Box Assistant (based on BeanPod)

Mi Box Assistant is a derivative of upstream [BeanPod](https://github.com/andyhuo520/beanpod), retaining its acknowledgements and MIT license. This edition adds local model options and TeleAgent handoff. Build this edition from source below; upstream releases do not include these changes.

[简体中文](README.md) | **English**

[![macOS 26](https://img.shields.io/badge/macOS-26-black)](#what-to-prepare-first) [![MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE) [![Renoise MCP](https://img.shields.io/badge/video-Renoise%20MCP-ff7a1a)](https://renoise.ai/mcp?utm_medium=xcom&utm_source=official)

A native macOS app for managing the **Anker AI voice recorder "bean" (soundcore, model D3200)** on your computer. It pulls recordings to your Mac, transcribes them, turns them into notes and to-dos, and lets you ask questions about everything you've recorded. Transcription runs on your Mac — recordings are not uploaded.

**No recorder? It still works on its own** as a free, open-source recording and learning app: record with your Mac, import audio files, or paste podcast and video links (Apple Podcasts, Xiaoyuzhou, Ximalaya, Bilibili, YouTube, …), then transcribe locally and get notes. For language learning, click a sentence to jump back to it, loop a sentence, follow the live highlight, and tick "English study mode" for leveled vocabulary, phrases and hard-sentence breakdowns.

> A personal open-source project made for **learning, research and testing** — free to use, no commercial purpose. If you find it useful, a ⭐ **Star** is much appreciated; issues and PRs are welcome.

> The app's interface is available in **English** and **Simplified Chinese** (Chinese is the default). It follows your system language — English on a non-Chinese system — and can be set in Settings → General → Language.

[![BeanPod promo (click for the full video)](docs/media/beanpod-promo.gif)](docs/media/beanpod-promo.mp4)

▶ [Watch the full promo (1 min 42 s, 720p)](docs/media/beanpod-promo.mp4)

![Overview](docs/screenshots/overview.jpg)

> **Special thanks to two original authors**: the bean (Anker soundcore recorder) protocol was first documented by **[tacshi](https://github.com/tacshi)** in [tacshi/Soundcore](https://github.com/tacshi/Soundcore); the DeDao AI recording card protocol was captured, analyzed and verified by **[Shawn-TKD](https://github.com/Shawn-TKD)** in [Shawn-TKD/getseed-ble-protocol](https://github.com/Shawn-TKD/getseed-ble-protocol). BeanPod wouldn't exist without their work — see [Acknowledgements](#acknowledgements).

> Unofficial project. Not affiliated with the device maker or its partners; meant only for managing your own recordings on your own device. Product names and trademarks belong to their owners.
>
> If anything in this project infringes your rights (code, protocol material, images, trademarks or otherwise), please tell us in [Issues](../../issues) — once confirmed, it will be removed promptly.
>
> All screenshots in this README use [demo data](#demo-data-mode) — names and content are fictional.

## What it does

**The bean recorder**
- Find and connect to the bean, reconnect automatically afterwards; see battery, storage and firmware
- Start, pause, resume and stop recording from the Mac; recordings started with the button on the bean are picked up too
- Download recordings and decrypt them to standard `.ogg`. New recordings sync automatically as soon as it connects, with a one-line notice at the top of the window (and a system notification when BeanPod isn't in front): how many new recordings are syncing, "everything is already synced", or "recordings that were on the bean last time are gone" (the bean pairs with one device at a time — usually the phone app or Feishu connected and took them)
- Bluetooth is slow; long recordings can use **Wi‑Fi fast transfer** (~500 KB/s; the Mac goes offline for ~40 s during the transfer)
- Drop highlight marks while recording and jump to them when listening

![Recordings and notes: recordings by day on the left, each with a small source badge; generated notes and to-dos on the right](docs/screenshots/notes.jpg)

**DeDao (GetSeed) AI recording card (experimental — not yet tested on real hardware)**
- Also connects to the DeDao AI recording card (GetSeed, model GSC10): the device page lists recordings on the card; downloaded ones go into the same library and get transcribed, summarized and searchable
- Syncs new recordings on connect (shares the "auto download" switch with the bean); you can delete a recording from the card (asks first — it can't be undone)
- You can't start recording on the card from the Mac — press its button. No Wi‑Fi transfer
- The protocol comes from [Shawn-TKD/getseed-ble-protocol](https://github.com/Shawn-TKD/getseed-ble-protocol); see [Acknowledgements](#acknowledgements) and [docs/GETSEED.md](docs/GETSEED.md)

**Transcription**
- Choose Qwen3-ASR 0.6B, Gemma 4 E2B BF16, FunASR Paraformer Q8, or Fun-ASR-Nano-2512 for local transcription. Click a timestamp to listen from the start of that audio segment
- Live captions while recording on the "recording stage", which you can put on a screen for the room
- Fun-ASR-Nano-2512 runs on CPU and downloads two model files totaling about 1.27 GB on first use. It works offline after download
- Selecting Paraformer downloads the model if needed. Once downloaded, it works offline. System speech recognition is also available as a separate option
- Cloud transcription is available too (any OpenAI `/audio/transcriptions`-compatible service such as SiliconFlow, OpenAI, Groq, or Xiaomi MiMo). Use local by default and send the odd hard recording to the cloud from the "⋯" menu
- One-click model download in Settings: pinned version, SHA‑256 verified, resumable, automatically switches to mirrors (hf-mirror, ModelScope) when HuggingFace is slow; pause and cancel supported
- Correction vocabulary: words you fix in a transcript are replaced automatically in future transcriptions

![Transcript: every sentence has a time and speaker; highlighted sentences are marked](docs/screenshots/transcript.jpg)

**Notes**
- Detects the scene — meeting, interview, sales, conversation, phone call, creator content, conference, lesson, idea, … — each with its own note sections
- Generates a title, summary, sections, to-dos and people; set your profession and the notes adapt their focus
- Rewrite into a talking-head script, short-video script, long social post, article or follow-up email; foreign-language content can be translated side by side
- Choose the summarizing model: BeanPod's built-in local model (Qwen3‑4B, ~2.5 GB), a local Ollama / LM Studio, or a cloud service. Endpoints for Xiaomi MiMo, DeepSeek, Qwen, Kimi, Doubao, Zhipu GLM, MiniMax, SiliconFlow, OpenRouter, Gemini, Claude and OpenAI are built in — pick one and paste your own key; anything OpenAI-compatible works via "Custom". "Cloud first, fall back to local" is available. With a local model, transcripts never leave the Mac
- Cloud API keys are stored in the macOS Keychain
- Processing progress: the overview shows which step each recording is in (transcribing, summarizing, queued), a progress bar, time remaining, and when the whole batch will be done. Speeds are learned from your Mac's actual runs, so estimates improve over time

**Finding things again**
- Overview: pending items, to-dos, recent recordings
- Knowledge base: ask questions directly; answers cite the recordings they're based on. Filter by time, scene or person
- Projects: group several recordings into one project
- Tags: added automatically when summarizing; add, remove, rename and merge your own. The sidebar lists every tag. Tags you've edited are kept when re-summarizing
- Export Markdown (with frontmatter, ready for Obsidian) and M4A / WAV audio
- Sync from Feishu Minutes: if the bean's phone app connects first, recordings go into Feishu Minutes and disappear from the bean. The "Feishu Minutes" card on the device page uses Feishu's official CLI `lark-cli` to pull them back (ones already in BeanPod are recognized and skipped); with "auto sync" on it checks every 30 minutes. Needs a one-time authorization — see [Before you start](#before-you-start)
- Sentence-by-sentence listening (great for learning languages with podcasts): click a sentence to play from there; the sentence being read is highlighted and the words already spoken darken as it plays; "loop sentence" repeats it and counts the passes, "replay this sentence" plays it once and stops; ⌥↑ ⌥↓ previous/next, ⌥R replay, ⌥L loop; speed down to 0.5×. Xiaoyuzhou, Apple Podcasts and Ximalaya episode links are tested to import and transcribe
- English study mode: for recordings that are mostly English (podcasts, interviews, lessons), tick "English study mode" on the notes tab to get study notes instead of a regular summary: overall difficulty (CEFR) with the vocabulary level mix and speaking rate; 20–30 key words (IPA, part of speech, level, meaning, original sentence); phrases and collocations; hard sentences with translation, structure breakdown and grammar notes. Every original sentence has "listen" to jump back into the audio. Leave it unticked for normal notes
- Source badges: each recording shows where it came from — bean, Mac, iPhone, recording card, imported audio or text. The "Source" menu above the list filters by source
- Recently deleted: recordings deleted on this Mac are kept for 7 days with transcript, notes and tags intact, and can be restored as they were; there's an "Undo" right after deleting. Deleting from the bean or the card doesn't go through here

![Feishu Minutes sync on the device page: new ones pre-ticked, ones already in BeanPod recognized](docs/screenshots/feishu.jpg)

![Recently deleted: kept for 7 days and restorable](docs/screenshots/trash.jpg)

**Other sources**
- Record with the Mac when the bean isn't connected: microphone, system audio, or both
- Import audio files, or paste video / podcast links (YouTube, Bilibili, Douyin, Xiaohongshu, WeChat Channels, Weibo, Ximalaya, Apple Podcasts, …). Only for public content you have the right to use
- Video materials can keep their picture (up to 720p): by default clips under 5 minutes keep video and longer ones keep only audio; you can choose per import. The picture follows the playback bar in the detail view. Settings shows how much space video takes and cleans it up in one click (only the video — audio and transcript stay); audio-only materials can fetch their video later
- Dictation: hold a key and talk to the bean; when you let go, the text is typed into whatever app you're using. What you said is kept in its own "Dictation" section in the sidebar (like an input method's history: replay, copy, search, and which app it went into), separate from recordings and not summarized; promote anything important with "Turn into recording". Audio is kept 30 days by default and text forever; the knowledge base skips dictation by default — all adjustable in Settings

![Dictation: like an input method's history, remembering which app each sentence went into](docs/screenshots/dictation.jpg)

**Languages**
- Interface in Simplified Chinese (default) and English: follows the system by default (English when the system isn't Chinese), or pin it in Settings → General → Language. Model-written content (notes, titles, to-dos) has its own "Notes language" setting, which follows the interface by default
- All UI text lives in `App/Localizable.xcstrings` (Apple String Catalog). To add a language: build once, run `python3 scripts/i18n-sync.py --lang ja --missing ja.json` to get the strings to translate, then `--apply` them back, and add an option in `App/Language.swift`. PRs welcome

**AI assistants**
- BeanPod ships with an MCP server and a command-line tool; Claude Code, Codex, Claude desktop and OpenClaw connect in one click. Then you can look up recordings, notes and to-dos from your assistant, or have it save content into BeanPod. See [Connect AI assistants](#connect-ai-assistants)

## Before you start

- Requires **macOS 26**. A bean recorder unlocks the device features; without one you can still record with the Mac, import audio and paste links. The iPhone version lives in `Mobile/` and is experimental.
- The bean pairs with **one device at a time**. If the phone is connected, the Mac can't find it — turn off Bluetooth on the phone first.
- Recordings synced by the bean's phone app disappear from the bean (they go into Feishu Minutes). To get them back into BeanPod, enable Feishu Minutes sync — one-time setup:
  1. Install Feishu's CLI: `npm install -g @larksuite/cli`
  2. `lark-cli config init --new` and confirm in the browser — this creates a Feishu custom app for you
  3. `lark-cli auth login --domain minutes` and authorize reading your Minutes in the browser
  4. To pull **audio** (not just the transcript): in the Feishu developer console, enable `minutes:minutes.media:export` (export Minutes audio/video) for that app, create and publish a version, then run `lark-cli auth login --scope "minutes:minutes.media:export"`. Without it BeanPod pulls Feishu's transcript only — notes still work, but there's no audio
- Only tested on firmware 04.92, and only with devices already activated in the official app; whether a brand-new, never-activated device connects directly is unknown.
- Bluetooth download: a 26-second recording takes ~7 s; an hour takes over ten minutes. Use Wi‑Fi fast transfer for long recordings.
- Recording card support is written from a public protocol document and **hasn't been tested on real hardware**. It also pairs with one device at a time — turn off Bluetooth on the phone if the DeDao app is connected. Note: the DeDao app clears already-synced recordings from the card every time it connects; BeanPod doesn't.

## Permissions

The first launch shows an onboarding guide: connect the bean, download the transcription model, choose the summarizing model, check permissions, optional features — one step per page, each skippable. Reopen it any time from the menu bar: Help → Onboarding (帮助 → 上手引导).

![The permissions step: each item says what it's for, shows live status, and "Open" jumps straight to System Settings](docs/screenshots/onboarding.jpg)

| Permission | What it's for | Without it | Where |
|---|---|---|---|
| Bluetooth | Connecting the bean and the recording card | Devices can't be found; you can still record with the Mac or import | macOS asks on first launch; later in System Settings → Privacy & Security → Bluetooth |
| Microphone | Recording with the Mac; dictation with the Mac's mic | No Mac recording; the bean is unaffected | Asked the first time you record with the Mac; System Settings → Privacy & Security → Microphone |
| Screen & System Audio Recording | Recording the computer's sound (meeting apps, videos) | Microphone only | System Settings → Privacy & Security → Screen & System Audio Recording; reopen BeanPod if macOS asks |
| Accessibility | Dictation typing into other apps and listening for the hold-to-talk key | Dictation won't work; everything else does | System Settings → Privacy & Security → Accessibility |
| Notifications | Telling you a recording is ready, or the bean connected and is syncing (when BeanPod isn't in front) | Notices only appear at the top of BeanPod's window | System Settings → Notifications → BeanPod |

Each item in the guide has an "Open" button that jumps to the right place in System Settings. Two more things aren't system permissions — you prepare them yourself:

- In **Settings → Models → Transcription → Local**, choose Paraformer Q8 (237 MB) to use the runtime bundled with the Apple Silicon app. Qwen3-ASR (about 1 GB) and Gemma 4 E2B BF16 (about 10.3 GB with its audio projector) use llama.cpp. Fun-ASR-Nano-2512 runs on CPU and downloads two files totaling about 1.27 GB on first use
- **Feishu Minutes sync**: install Feishu's CLI and authorize, see [Before you start](#before-you-start)

## What to prepare first

Split into "required" and "only when you need it". If you download the app, only macOS 26 and Homebrew are required; building from source also needs Xcode and an Apple ID. The rest can wait.

**Required**

| What | Why | How |
|---|---|---|
| A Mac on **macOS 26** | Running BeanPod | Apple silicon (M-series) recommended — local transcription and the local summarizing model are much faster on it |
| **Xcode 26** (only when building from source) | Building BeanPod from source | Free on the Mac App Store; open it once, accept the license and let it install components |
| **Homebrew** | Installing build and runtime tools | Run the one-line installer from [brew.sh](https://brew.sh) |
| **Apple ID** (a free one is fine; only when building from source) | Signing BeanPod so the Bluetooth permission survives rebuilds | Xcode → Settings → Accounts → "+" → sign in. Your Team ID (10 letters/digits) is shown there |

**Only when you need it**

| What | When | How |
|---|---|---|
| A summarizing model | You want summaries, to-dos and knowledge-base answers (transcripts alone don't need one) | Either ① one-click download of the local model in BeanPod's settings (~2.5 GB, offline), or ② sign up with a cloud provider and get an API key: Xiaomi MiMo, DeepSeek, Qwen, Kimi, Doubao, Zhipu, MiniMax, SiliconFlow, OpenRouter, Gemini, Claude and OpenAI are built in — register on the provider's platform → create an API key → paste it into Settings → Models. Keys live in the Keychain |
| Cloud transcription (optional) | You don't want a local model, or want a better pass on a hard recording | Any OpenAI `/audio/transcriptions`-compatible service (SiliconFlow, OpenAI, Groq) or Xiaomi MiMo; get a key from their platform |
| **Claude Code** | Looking up recordings, notes and to-dos from Claude (MCP) | Install per the [Claude Code docs](https://docs.claude.com/en/docs/claude-code/overview) and sign in once with a Claude account (Pro / Max) or an Anthropic API key; then click "Connect" for Claude Code in BeanPod's Help → Connect AI assistants |
| **Claude desktop** | Querying recordings, notes and to-dos through MCP | Install and sign in, then use "Connect AI assistants". Digital-human video creation does not require Claude |
| **TeleAgent** | "Make a digital-human video" | Install and sign in, connect Renoise in MCP settings, then copy the task instructions into a new session with the project folder selected |
| **Renoise account** | "Make a video" uses it to generate the talking avatar and edit the video | Sign up at **[Renoise](https://renoise.ai/mcp?utm_medium=xcom&utm_source=official)** (browser sign-in, no API key to paste), then connect Renoise to TeleAgent — see [Turn recordings into videos with Renoise](#turn-recordings-into-videos-with-renoise-optional). You get a quote first; credits are spent only after you confirm |
| `yt-dlp` | Importing video / podcast links | `brew install yt-dlp`. The Xiaohongshu, Douyin and WeChat Channels downloaders are installed into a separate Python environment automatically on first use |
| Node.js + Feishu CLI | Pulling recordings back from Feishu Minutes | `brew install node`, then the four steps in [Before you start](#before-you-start) |
| Codex / OpenClaw | Asking BeanPod from those tools | Install them, then connect in one click from "Connect AI assistants"; OpenClaw can also bridge to WeChat |

## Install

No release download URL is provided for this derivative yet. Build from the current repository source.

### Build from source

**1. Tools**

```bash
brew install xcodegen llama.cpp ffmpeg yt-dlp
```

**2. Build**

```bash
xcodegen generate
```

```bash
xcodebuild -project BeanPod.xcodeproj -scheme BeanPod -derivedDataPath build build CODE_SIGN_IDENTITY="Apple Development" CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=<your Team ID>
```

Sign with your own Apple development certificate (a free Apple ID works; the Team ID is in Xcode → Settings → Accounts). It also builds unsigned, but then macOS asks for Bluetooth permission again after every rebuild and the bean can't be found until you allow it.

```bash
cp -R build/Build/Products/Debug/BeanPod.app /Applications/
```

```bash
open /Applications/BeanPod.app
```

Open it from Applications or Finder — don't run the executable inside the app bundle from Terminal, or it will crash for lack of permissions.

**3. First launch**

- The onboarding guide appears: allow Bluetooth, connect the bean, download the transcription model, choose a summarizing model, check the other permissions (see [Permissions](#permissions))
- If llama.cpp isn't installed, click "Install" in Settings → Models (uses Homebrew)
- BeanPod installs its CLI to `~/.local/bin/beanpod`; "Connect AI assistants" uses it

Tests for the core logic:

```bash
swift test
```

### Demo data mode

Want to see what BeanPod looks like, or take screenshots and demos without exposing your own recordings?

```bash
python3 scripts/make-demo-library.py
```

```bash
open -a BeanPod --args -demo
```

The script builds a fictional library in `~/Library/Application Support/BeanPod/Demo/Recordings/` (a coffee-shop team's weekly meeting, interview, phone call, dictation, recently deleted, …) with macOS text-to-speech audio; it needs `ffmpeg`. Launched with `-demo`, BeanPod reads only this demo library: no Bluetooth, no MCP server, no Feishu sync, and your own library is untouched. Quit and open normally to get your recordings back.

## Connect AI assistants

BeanPod exposes your library to AI assistants that support [MCP](https://modelcontextprotocol.io). What they can do:

| Tool | What it does |
|---|---|
| `search_recordings` | Search by keyword, time, scene, person or topic; with no filters, returns recent recordings |
| `get_recording` | The full notes of one recording: summary, sections, to-dos, people, topics, optionally the transcript |
| `list_todos` | To-dos across all recordings, open ones by default |
| `list_topics` | Overview: number and length of recordings, how often each scene, topic and person appears |
| `add_note` | Save a piece of text (a chat log, an idea, an excerpt) into BeanPod; it's summarized like a recording |
| `add_audio` | Hand an audio file on this Mac to BeanPod to transcribe and summarize |

The first four are read-only. The last two don't write to the library directly: content goes into an inbox (`~/Library/Application Support/BeanPod/Inbox/`) that BeanPod imports and processes while it's open.

### One-click connect

Menu Help → Connect AI assistants, or Settings → Connect: one card per assistant showing whether it's installed and connected, with connect, disconnect and "try it".

| Assistant | What BeanPod does |
|---|---|
| Claude Code | Runs `claude mcp add --scope user beanpod -- ~/.local/bin/beanpod mcp` |
| Codex | Runs `codex mcp add beanpod -- ~/.local/bin/beanpod mcp` |
| OpenClaw | Runs `openclaw mcp add beanpod --command ~/.local/bin/beanpod --arg mcp` |
| Claude desktop | Adds an entry to `claude_desktop_config.json` (backs it up first as `claude_desktop_config.backup-by-beanpod.json`); quit Claude desktop first, or it will write its own copy back |
| TeleAgent | After you quit TeleAgent, adds `mcp.beanpod` to the current account’s `~/.config/TeleAgent/users/<account>/TeleAgent.jsonc` using the local command. Each edit saves a `TeleAgent.backup-by-beanpod-*.jsonc` backup. The account comes from `~/.local/share/TeleAgent/current-owner.json`. Files with comments or an unsupported format are left unchanged; add BeanPod in TeleAgent’s MCP settings instead. |
| Grok Bot and other URL-only tools | Copy `http://127.0.0.1:8791/mcp` into them |

The URL endpoint only exists while BeanPod is open, and only listens on this Mac.

### Manual setup

For other MCP-capable tools, in their format:

```json
{
  "mcpServers": {
    "beanpod": { "command": "/Users/<your username>/.local/bin/beanpod", "args": ["mcp"] }
  }
}
```

### Command line

`beanpod` is also a CLI you can use in scripts:

```bash
beanpod search budget --from 7d --scene 会议
```

```bash
beanpod todos
```

| Command | What it does |
|---|---|
| `beanpod search [keyword] [--from date] [--to date] [--scene scene] [--person person] [--tag topic] [--limit N]` | Search recordings |
| `beanpod show <id> [--transcript]` | Notes of one recording |
| `beanpod todos [--all]` | To-dos |
| `beanpod topics` | Scenes, topics and people at a glance |
| `beanpod add-note title < text` | Save text into BeanPod |
| `beanpod add-audio <file>` | Hand audio to BeanPod to transcribe and summarize |
| `beanpod mcp` | Run as an MCP server (stdio) |
| `beanpod serve [--port 8791]` | Run as an MCP server (HTTP) |

Dates can be `2026-11-12`, `today`, `yesterday`, `7d`. Scene names are the Chinese ones shown in the app (e.g. 会议 = meeting).

### Ask BeanPod from WeChat

With [OpenClaw](https://github.com/openclaw/openclaw) and its WeChat plugin you can ask about your recordings and to-dos from WeChat. Connect OpenClaw in BeanPod first, then follow OpenClaw's instructions to install the WeChat plugin, scan to sign in, and configure a model.

### Turn recordings into videos with Renoise (optional)

On a recording's "Rewrite" tab, "Make a digital-human video" prepares a project and opens TeleAgent. Click "Copy task instructions", create a new TeleAgent session, select the project folder, paste and send. TeleAgent uses **[Renoise](https://renoise.ai/mcp?utm_medium=xcom&utm_source=official)** to generate and edit the presenter video. Once it writes the agreed result files, the video, cover and script appear under the recording.

**One-time setup**

1. Create a Renoise account, then install and sign in to TeleAgent
2. Add Renoise in TeleAgent's MCP settings using `https://renoise.ai/api/public/mcp` and complete authorization. The video window provides a "Copy MCP URL" button
3. Ask TeleAgent to check your Renoise balance to confirm the connection works

**When you use it**

- Mi Box Assistant checks whether TeleAgent is installed and prepares the task files. Opening the app does not create a session or send a task; paste and send it yourself
- TeleAgent plans and quotes first. Generation and spending begin only after you confirm in that session. Mi Box Assistant reads the quote, progress and result from the project folder
- A presenter: BeanPod includes two sample presenters (AI-generated fictional people, "Sample · Business" and "Sample · Casual"). The first time you use one, its photo is uploaded to your own Renoise account (no credits). To present it yourself, click "Add presenter" and upload a front-facing half-body photo of yourself, or enter the ID of a portrait already in your Renoise account; you must confirm "this is me, or I have the person's permission". Renoise reviews portraits at generation time; "under review" or "rejected" is shown on the card and that presenter can't be used yet

Presenter records and thumbnails live in `~/Library/Application Support/BeanPod/Hosts/`. Removing a presenter from BeanPod doesn't delete the asset from your Renoise account.

The "Creative tools" card at the bottom of the Connect page can install and sign in to the Renoise CLI for you.

What an assistant does with the content depends on that assistant and the model service it uses.

## Privacy

- Recordings, transcripts and notes are stored on this Mac: `~/Library/Application Support/BeanPod/`
- Transcription is local by default. Audio is sent only if you choose cloud transcription (or "re-transcribe in the cloud" for a recording) — and only to the service you configured. Transcripts are sent only if you configure a cloud summarizing model
- BeanPod collects no usage data and has no server of its own

## Code layout

```
Sources/BeanKit/   Protocol and audio, UI-free, unit-testable
  Frame.swift        Frame encoding, checks, reassembly
  Commands.swift     Commands
  Models.swift       Parsing device info and recording lists
  GetSeed.swift      Recording-card frames, commands, lists, download stitching, Opus packets from Ogg
  Crypto.swift       Key agreement, file decryption, slice parsing
  OggOpus.swift      Wrapping raw Opus frames into Ogg
  OpusDecoder.swift  Decoding to WAV
Sources/beanpod/   CLI and MCP server (bundled in Contents/Helpers)
Shared/            Shared by Mac and iPhone: Bluetooth, library, transcription and notes pipeline, knowledge base
App/               Mac UI and Mac-only features (Wi‑Fi transfer, link import, notch panel, AI assistants, …)
  SocialDL/          Downloaders for Xiaohongshu, Douyin, WeChat Channels, … (Python)
Mobile/            iPhone UI (experimental)
docs/PROTOCOL.md   Protocol notes for the bean, each item sourced
docs/GETSEED.md    Recording-card protocol excerpt and its source
design/            UI mockups and "Xiaodou" mascot assets
docs/screenshots/  README screenshots (demo data)
docs/media/        Promo video and preview GIF
scripts/           Demo library generator
```

The log is at `~/Library/Logs/BeanPod.log`.

## Protocol

[docs/PROTOCOL.md](docs/PROTOCOL.md) documents every part of the protocol BeanPod uses with the bean: frame format, commands, recording list, download and decryption, Wi‑Fi transfer. Each item is marked with its source: tested on the device, checked against the official client, or taken from earlier notes and not yet independently verified.

The recording-card protocol excerpt is in [docs/GETSEED.md](docs/GETSEED.md); that protocol was compiled by someone else — see Acknowledgements.

These notes exist so you can use your own device on your own computer. This repository contains no vendor code, firmware or keys, and no decompiled code.

## Acknowledgements

The bean protocol work builds on the notes by **[tacshi](https://github.com/tacshi)** in [tacshi/Soundcore](https://github.com/tacshi/Soundcore), the first project to document this Anker soundcore recorder's protocol — BeanPod's connection, download and decryption all started from it. BeanPod's code is written independently in Swift and uses none of that project's code; checking on real hardware found and corrected a few field meanings, documented in the protocol notes.

The DeDao AI recording card protocol comes entirely from **[Shawn-TKD](https://github.com/Shawn-TKD)**'s [Shawn-TKD/getseed-ble-protocol](https://github.com/Shawn-TKD/getseed-ble-protocol) (MIT, Copyright (c) 2026 Shawn-TKD), whose author compiled and verified it through packet captures and firmware analysis. BeanPod implements it from scratch in Swift from that document without using its code; see [NOTICE](NOTICE).

Select the local summarization model independently of transcription. Paraformer uses FunASR's Apple Silicon runtime and Q8 weights. [FunASR GitHub release](https://github.com/modelscope/FunASR/releases/tag/runtime-llamacpp-v0.2.6) · [Paraformer GGUF](https://huggingface.co/FunAudioLLM/Paraformer-GGUF/blob/main/paraformer-q8.gguf). Qwen and Gemma use llama.cpp. [Qwen3-ASR GGUF](https://huggingface.co/ggml-org/Qwen3-ASR-0.6B-GGUF) · [Gemma GGUF](https://huggingface.co/ggml-org/gemma-4-E2B-it-GGUF) · [llama.cpp](https://github.com/ggml-org/llama.cpp). Video generation via [Renoise](https://renoise.ai/mcp?utm_medium=xcom&utm_source=official).

## License

[MIT](LICENSE)
