# VoiceInput

A minimal macOS menu-bar app for offline voice input. Press a hotkey, speak, press again, and your speech is transcribed locally by [WhisperKit](https://github.com/argmaxinc/WhisperKit) (Whisper `large-v3-turbo` by default) and injected into the focused text field.

No subscriptions. No cloud. No account. Just a microphone icon in your menu bar.

## Features

- **Fully offline** — transcription runs on-device via WhisperKit (Core ML, Apple Neural Engine).
- **Menu-bar only** — no Dock icon, no main window, out of your way.
- **Press-to-toggle** hotkey: press once to start, press again to stop.
- **Right ⌘ Command** or **Right ⌥ Option** as the hotkey.
- **Chinese + English mixed speech** handled cleanly (locked to `zh` by default — English words inside Chinese sentences are preserved as English).
- Supports 99 languages (switch from the menu).
- Six Whisper model sizes to choose from (`tiny` → `large-v3_turbo`).

## Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon recommended (Neural Engine dramatically speeds up inference)
- Xcode Command Line Tools

## Install

### Option A — Homebrew Cask (recommended)

```bash
brew install --cask haha1903/tap/voice-input
```

This installs a notarized, signed `.app` from the [GitHub Releases](https://github.com/haha1903/voice-input/releases). Updates ship via `brew upgrade --cask voice-input`.

To uninstall (keep user data):

```bash
brew uninstall --cask voice-input
```

To uninstall and wipe the downloaded Whisper model + preferences:

```bash
brew uninstall --cask --zap voice-input
```

### Option B — build from source

```bash
git clone https://github.com/haha1903/voice-input.git
cd voice-input
make install     # builds VoiceInput.app and copies it to /Applications
```

The first launch downloads the Whisper model (~3 GB, Core ML FP16) into
`~/Library/Application Support/VoiceInput/`. Subsequent launches are fully
offline. Hover the menu-bar mic icon to see load progress.

### Option C — use a stable signing identity (optional, source builds only)

By default `make build` uses ad-hoc signing. macOS TCC (Accessibility,
Microphone) treats every rebuild as a new app, so you'll have to re-grant
permissions each time you rebuild.

To avoid that, sign with your own Apple Development identity. Create
`Makefile.local` (gitignored):

```makefile
SIGN_ID := Apple Development: Your Name (TEAMID)
```

Then `make install` signs the app with that identity and TCC permissions
persist across rebuilds.

## Usage

1. After install, open **VoiceInput** once from `/Applications`.
2. Grant **Accessibility** permission when prompted (needed to inject
   keystrokes into the focused app). macOS will restart the app.
3. Grant **Microphone** permission the first time you trigger recording.
4. Click into any text field.
5. Press the hotkey — mic icon turns red, overlay says "Listening...".
6. Speak.
7. Press the hotkey again — overlay says "Transcribing...", text appears
   at the cursor about one second later.

### Menu

- **Enabled** — master toggle.
- **Hotkey** — Right ⌘ or Right ⌥.
- **Language** — default 中文 (`zh`), or English / 日本語 / 한국어 / Auto Detect.
- **Model** — `tiny` through `large-v3_turbo` (default). Larger = more accurate, slower to load.

## Why "press-to-toggle" instead of "hold-to-talk"?

Hold-to-talk (Fisper-style) requires continuous key pressure, which is
awkward for anything longer than a sentence. Press-to-toggle — the same
model as VoiceInk — lets you press, speak freely for as long as you want,
then press again to finalize. This is the only supported mode.

## Tech stack

| Layer | What |
|---|---|
| Recording | `AVAudioEngine` with a `NSLock`-protected PCM buffer |
| Resampling | `AVAudioConverter` to 16 kHz mono Float32 (what Whisper expects) |
| Transcription | [WhisperKit](https://github.com/argmaxinc/WhisperKit) (Core ML + ANE) |
| Model | `openai_whisper-large-v3_turbo`, FP16, ~3 GB |
| Hotkey | Carbon-level `CGEvent.tapCreate` with 250ms debounce |
| Text injection | `CGEvent` synthesized keystrokes + pasteboard fallback |
| Menu bar | `NSStatusItem` + custom `NSPanel` overlay |

Decoding is tuned for speed and stability:

- `prewarm: true` — Core ML graph compiled once at load.
- `temperatureFallbackCount: 0` — accept the first result, no fallback loops.
- `noSpeechThreshold: 0.6` + `compressionRatioThreshold: 2.4` — guards
  against Whisper's "repetition hallucination" on silent or very short
  clips.
- `detectLanguage: false` when a language is pinned — skips the language
  detection pass entirely.

## Credits

This project started as a fork of **[yetone/voice-input-src](https://github.com/yetone/voice-input-src)**, which used Apple's built-in `Speech` framework for recognition. The major changes in this fork:

- Swapped Apple Speech → WhisperKit (local Whisper), mainly for **Chinese + English mixed** accuracy.
- Added model picker, language picker, hotkey picker.
- Moved model storage to `~/Library/Application Support/VoiceInput/`.
- Added Info.plist embedding + entitlements so TCC permission prompts
  actually work with a Swift Package Manager build.
- App icon bundled.
- Removed the OpenAI-based LLM refinement path (pure local flow).

All credit for the original AVAudioEngine + CGEvent plumbing, overlay panel, and menu-bar scaffolding goes to [@yetone](https://github.com/yetone).

## License

[MIT License](LICENSE) — Copyright (c) 2025 yetone (original `voice-input-src`),
Copyright (c) 2026 Hai Chang (this fork's modifications).
