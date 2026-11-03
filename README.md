# Local Flow

[![Build and test](https://github.com/MarkMcChlery/local-flow/actions/workflows/build.yml/badge.svg)](https://github.com/MarkMcChlery/local-flow/actions/workflows/build.yml)

*Local whispers are louder than the chorus of the people.*

Fully local voice dictation for macOS. Hold a hotkey, speak, release, and clean punctuated text appears wherever your cursor is, in any app. No cloud, no account, no subscription. Audio never leaves your Mac.

**What it does**

- Hold `Option+Space` anywhere, speak, release: transcribed, cleaned text is typed at your cursor.
- Command Mode: select text in any app, hold `Option+Shift+Space`, say an instruction like "make this more formal", release: the selection is rewritten in place.
- AI clean-up (punctuation, capitalisation, filler removal) using Apple's built-in on-device model. Falls back to rule-based clean-up if unavailable. Your raw words are never lost: any AI failure inserts the plain transcript instead.
- Personal dictionary (fix consistently misheard names/jargon), voice snippets (say a trigger phrase, insert a template), dictation history with undo, raw mode for terminals and code editors, remappable hotkeys, launch at login.
- Optional voice memo archive: every dictation is also saved as a Markdown file, filed automatically into a topic folder guessed from its content (Settings -> Memos). Off by default.

**Requirements:** Apple Silicon Mac (M1 or later), macOS 14 or later (macOS 26 "Tahoe" with Apple Intelligence enabled for the AI clean-up pass and Command Mode; dictation with rule-based clean-up works without it), ~2 GB free disk, Xcode (free, App Store).

---

## Setup (one time, ~30 minutes, mostly waiting)

### Step 1: Install Xcode

1. Open the **App Store**, search for **Xcode**, click **Get**. It is large (~10 GB), let it finish.
2. Open Xcode once, accept the licence, and let it install its components. You can quit it afterwards; you never need to open it again.
3. Open **Terminal** (press `Cmd+Space`, type `Terminal`, press Return) and run:
   `sudo xcode-select -s /Applications/Xcode.app`
   (Type your Mac password when asked; it will not show as you type.)

### Step 2: Clone, build and install Local Flow

In Terminal:

```bash
git clone https://github.com/MarkMcChlery/local-flow.git
cd local-flow
./build.sh --install
```

The first build downloads the Swift dependencies and takes a few minutes. When it finishes, Local Flow launches and a **microphone icon appears in the menu bar** (top right of the screen).

### Step 3: Grant permissions

1. A system dialog asks about **Accessibility**: click *Open System Settings*, and switch **LocalFlow** on (Privacy & Security -> Accessibility). This is what lets it type into other apps.
2. Click the menu bar icon -> **Settings...** -> General tab. Click **Grant...** next to Microphone and allow it.
3. Both rows in Settings should now show green ticks.

### Step 4: First dictation

1. The first launch downloads the speech model (~630 MB, one time; the menu bar icon shows an hourglass while downloading).
2. When the status says **Ready**, click into any text field (Notes is a good test).
3. **Hold** `Option+Space`, **speak a sentence, release.** Your words appear, cleaned and punctuated.

That is it. Everything from here on works offline.

---

## Daily use

| Action                 | How                                                                        |
| ---------------------- | -------------------------------------------------------------------------- |
| Dictate                | Hold `Option+Space`, speak, release                                        |
| Rewrite selected text  | Select text, hold `Option+Shift+Space`, say the instruction, release       |
| Undo a bad insert      | Menu bar icon -> Undo last insert                                          |
| Fix a misheard name    | Settings -> Dictionary -> add wrong -> right pair                          |
| Voice template         | Settings -> Snippets (say the trigger phrase alone to insert the expansion) |
| Change hotkeys         | Settings -> General -> Hotkeys                                             |
| Toggle instead of hold | Settings -> General -> untick "Hold to talk"                               |
| Turn on voice memos    | Settings -> Memos -> tick "Save every dictation as a memo"                 |

Dictating into Terminal, VS Code, Xcode or iTerm inserts the raw transcript with no auto-capitalisation or clean-up (configurable in Settings -> Raw mode apps).

---

## Troubleshooting

| Problem                                         | Fix |
| ----------------------------------------------- | --- |
| `xcrun: error` or `no such module` during build | Full Xcode is not selected. Run `sudo xcode-select -s /Applications/Xcode.app`, then `sudo xcodebuild -license accept`, and rebuild. |
| Build fails resolving packages                  | Needs internet for the first build only. Check connection and re-run `./build.sh --install`. |
| Hotkey does nothing                             | Another app may own that shortcut. Change it in Settings -> Hotkeys. |
| No text appears after speaking                  | Accessibility permission missing, or was invalidated by an ad-hoc rebuild. System Settings -> Privacy & Security -> Accessibility: remove LocalFlow (minus button), re-add it, or toggle it off and on. |
| "Focus changed, so the text was copied"         | You switched apps while it was transcribing. Local Flow only types into the app you started in, so it copied the text to the clipboard instead: paste it with `Cmd+V`. |
| "Apple Intelligence not available" in Settings  | Enable it in System Settings -> Apple Intelligence & Siri and wait for its download to finish. Dictation still works meanwhile with rule-based clean-up. |
| Transcription is poor                           | Settings -> General -> try the Large v3 Turbo model (default) or check your mic input level in System Settings -> Sound. |
| Rebuilt the app and permissions broke           | The build was ad-hoc signed, so macOS sees a "new" app. Re-tick Accessibility (and mic if prompted), then set up a signing certificate (see below) so it stops happening. |
| Want to start fresh                             | Delete `/Applications/LocalFlow.app`, `~/Library/Application Support/LocalFlow`, (which includes the speech model cache). |

## Keep permissions across rebuilds (recommended)

macOS ties the Accessibility permission to the app's code signature. By default `build.sh` signs ad-hoc, which gives every build a new identity, so you have to re-tick Accessibility after each rebuild. Signing with the same certificate every time fixes this. You only need to do it once:

1. Open **Keychain Access** and choose **Keychain Access -> Certificate Assistant -> Create a Certificate...**
2. Name: `LocalFlow Dev`. Identity Type: **Self Signed Root**. Certificate Type: **Code Signing**. Click **Create**.
3. Run `./build.sh --install` and grant Accessibility one last time.

`build.sh` uses the certificate automatically when it finds it (use a different name with `LOCALFLOW_SIGN_IDENTITY="My Cert" ./build.sh`). The first time, macOS may ask to let `codesign` use the key: click **Always Allow**.

**Upgrading from an older build:** the speech model now lives in `~/Library/Application Support/LocalFlow/huggingface` instead of `~/Documents/huggingface`, so it downloads once more. Afterwards you can delete the old copy at `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml`. If you never changed the memo folder, new memos now go to `~/LocalFlow Memos`; older ones stay in `~/Documents/Voice Memos`.

## Privacy

Zero network use after the one-time model downloads (Whisper model from Hugging Face; Apple Intelligence via macOS itself). No analytics, no account, no logs leaving the machine. Dictation history is kept in memory only and disappears when the app quits. Dictionary and snippets are stored as plain JSON in `~/Library/Application Support/LocalFlow/`. If you turn on voice memos (Settings -> Memos, off by default), each dictation is additionally saved as a Markdown file under your chosen folder (default: `~/LocalFlow Memos`), still entirely on-device; nothing leaves the Mac.

## Development

Unit tests cover the deterministic text pipeline (rule-based cleaner, dictionary find/replace, snippet matching). Run them with `swift test`. CI runs the build and tests on every push and pull request (see the badge above).

## Distribution note

Builds are ad-hoc signed, which is fine for a Mac you build on. A copied `.app` will be blocked by Gatekeeper on other Macs, so each user should build from source (one script, see Setup). Notarised distribution would need a paid Apple Developer account.

## Project layout

```
LocalFlow/
├── Package.swift              # Dependencies: WhisperKit (Argmax OSS), KeyboardShortcuts
├── build.sh                   # Builds and installs the .app (no Xcode project needed)
├── Support/Info.plist         # App metadata + microphone permission text
└── Sources/LocalFlow/
    ├── LocalFlowApp.swift     # Menu bar app + hotkey definitions
    ├── AppController.swift    # State machine wiring everything together
    ├── AudioRecorder.swift    # Mic capture -> 16 kHz mono samples
    ├── Transcriber.swift      # WhisperKit speech-to-text
    ├── Cleaner.swift          # Apple Intelligence + rule-based clean-up
    ├── MemoArchiver.swift     # Optional: files each dictation into a topic folder
    ├── TextInjector.swift     # Puts text at the cursor (Accessibility / paste)
    ├── Stores.swift           # Dictionary + snippets (JSON persistence)
    └── SettingsView.swift     # Settings window
```

## Licence

MIT. Built on WhisperKit (Argmax OSS, MIT) and KeyboardShortcuts (MIT).
