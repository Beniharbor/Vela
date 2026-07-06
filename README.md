# Vela

Local, on-device voice dictation for macOS. Hold a hotkey, speak, release — the text
appears wherever your cursor is. 100% local: no cloud, no account, no subscription.

Built per `~/Desktop/PRD.md`.

## Pipeline

```
Hold ⌥Space → mic capture (AVAudioEngine, 16 kHz)
  → WhisperKit STT (large-v3 turbo compressed, on-device, ANE)
    → [optional] Ollama cleanup (qwen2.5:3b, keep_alive: 0)
      → paste into focused app (clipboard + synthetic ⌘V)
```

## Build & run (no Xcode required — Command Line Tools only)

```bash
cd ~/Developer/Vela
Scripts/package.sh          # builds release + assembles build/Vela.app
open build/Vela.app
```

## First run

1. A waveform icon appears in the menu bar.
2. **Hold ⌥Space and speak.** First ever dictation downloads the Whisper model
   (~0.6 GB from Hugging Face) — expect a wait; later runs load from disk in seconds.
3. macOS will prompt for **Microphone** (first recording) and **Accessibility**
   (first insertion). Grant both. If the paste doesn't land right after granting
   Accessibility, quit and relaunch Vela once.
4. Release the key — text is pasted into whatever app is focused.

## AI cleanup (optional, off by default)

Keeps RAM light by default. To enable:

```bash
brew install ollama
ollama pull qwen2.5:3b     # or gemma2:2b for lighter
```

Then menu bar icon → Settings → General → enable "Clean up transcripts".
Vela starts/stops `ollama serve` on demand and uses `keep_alive: 0` so the LLM
leaves RAM immediately after each cleanup.

## Settings

- **Push-to-talk hotkey** (default ⌥Space, hold to record)
- **Whisper model** — large-v3 turbo compressed (default) down to base.en (lightest)
- **Idle unload** — Whisper is dropped from RAM after 2 min idle (configurable)
- **Vocabulary tab** — one term per line; biases Whisper and instructs the cleanup LLM

## RAM behavior (G3)

Idle: just the menu-bar app (~150 MB target). Whisper loads on demand and auto-unloads
after idle; the Ollama model unloads immediately after each request. Menu → "Unload
models now" forces an immediate release.

## Project layout

```
Sources/Vela/
  VelaApp.swift            app entry, menu bar UI
  DictationController.swift  pipeline orchestration + state
  AudioRecorder.swift      AVAudioEngine 16 kHz mono capture
  Transcriber.swift        WhisperKit wrapper, load-on-demand/auto-unload
  OllamaCleanup.swift      optional LLM cleanup, on-demand server lifecycle
  TextInjector.swift       clipboard + ⌘V injection, Unicode fallback
  AppSettings.swift        defaults + glossary
  SettingsView.swift       settings window
Resources/Info.plist       LSUIElement agent app, mic usage string
Scripts/package.sh         SPM build → Vela.app bundle + ad-hoc codesign
```
