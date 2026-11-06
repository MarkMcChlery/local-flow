# Meeting Mode: scope

Status: proposal, not started. Written 6 November 2026.

## Goal

Record a whole call (Teams, Zoom, Meet, FaceTime, anything), then produce a
transcript that says who said what, saved as Markdown next to the existing
voice memos. Everything stays on the Mac, like the rest of Local Flow.

**Non-goals for v1:** live captions, auto-joining or auto-starting on a
calendar event, naming speakers automatically, uploading or sharing anything.

## How it works

### Two audio sources

| Source | What it hears | How |
|---|---|---|
| Microphone | You | `AVAudioEngine`, as dictation does today (now resilient to AirPods switching format) |
| System audio | Everyone else on the call | Core Audio **process tap** (macOS 14.2+): `CATapDescription` + `AudioHardwareCreateProcessTap`, read through a private aggregate device |

Keeping the two sources apart is the key design choice:

- Everything on the mic channel is labelled **"Me"**. No diarization is needed for it.
- Only the system channel goes through speaker diarization, which labels
  **Speaker 1, Speaker 2, …**. That is easier and more accurate than
  separating a single mixed recording.
- With AirPods there is no echo: other voices go to your ears, not into the
  mic. On laptop speakers the mic also hears the call; phase 3 handles that.

Why a process tap rather than ScreenCaptureKit: it captures audio only, needs
the lighter "System Audio Recording Only" privacy permission rather than full
Screen Recording, and it can target a single app (e.g. only Teams) or all
system output.

### Pipeline

```
Start meeting ──► mic recorder ──► me.caf      (16 kHz mono, streamed to disk)
              └─► system tap   ──► others.caf  (16 kHz mono, streamed to disk)
Stop meeting  ──► WhisperKit (word timestamps) on each file, in 30 s chunks
              ──► SpeakerKit diarization on others.caf
              ──► addSpeakerInfo() merges words with speakers
              ──► merge both channels by timestamp
              ──► Markdown transcript (+ optional on-device summary)
              ──► delete the audio files (default; setting to keep them)
```

- **Audio goes to disk as it is recorded**, not into memory. An hour of
  16 kHz Float32 mono is about 230 MB per channel, too much to hold, and
  writing to disk means a crash loses nothing.
- **Transcription happens after the call** in v1. That is simpler and more
  accurate, and on Apple Silicon large-v3 runs faster than real time, so a
  1-hour call should take a few minutes (to be measured in phase 1).
- **Diarization:** `SpeakerKit` already ships in the `argmax-oss-swift`
  package Local Flow depends on (Pyannote models from
  `argmaxinc/speakerkit-coreml`, downloaded once). Usage, as in
  `ArgmaxCLI/TranscribeCLI.swift`: transcribe with `wordTimestamps = true`,
  `speakerKit.diarize(audioArray:)`, then
  `diarizationResult.addSpeakerInfo(to: transcription)`.

### Output

Saved to `<memo folder>/Meetings/2026-11-06 0930 <title>.md`:

```markdown
# Meeting: Weekly sync
**Date:** 6 November 2026, 09:30–10:12 (42 min)
**Speakers:** Me, Speaker 1, Speaker 2

## Summary            (optional, Apple Intelligence)
## Action items       (optional, Apple Intelligence)

## Transcript
**[00:00:04] Me:** Morning all, shall we start with the release?
**[00:00:09] Speaker 1:** Yes, so the build went out last night…
```

Speakers can be renamed after the call: a small editor in the History window
does a find-and-replace of "Speaker 1" → "Thandi" in that file.

**Summary:** the on-device Apple model has a small context window, so the
transcript is summarised in chunks and the chunk summaries are then combined.
If Apple Intelligence isn't available, the transcript is saved without a
summary, so it is never lost.

## User experience

- Menu bar → **Start meeting recording…** (optional title), plus a
  configurable hotkey. It never starts automatically.
- While recording: a red menu bar icon with elapsed time, and a
  **Stop meeting** item. Push-to-talk dictation is disabled during a
  meeting so the two can't conflict over the mic.
- On stop: a progress state ("Transcribing meeting… 40%"), then a
  notification "Meeting saved", which opens the file when clicked.
- Settings → **Meetings** tab: source (all system audio, or pick apps),
  keep audio files (off), summary on/off, consent reminder on/off.

## Consent and privacy

- Recording other people generally needs their consent. When a recording
  starts, show a reminder to tell participants (it can be switched off).
- For PayJustNow / Weaver calls, check company policy on recording and on
  keeping transcripts before using it, even though nothing leaves the Mac.
- Nothing is uploaded. Audio is deleted after transcription unless "keep
  audio" is on. Transcripts are plain Markdown in the folder you choose.
- New permission: **System Audio Recording Only**
  (`NSAudioCaptureUsageDescription` in `Info.plist`). The microphone and
  Accessibility permissions stay as they are.

## Phases

Each phase ships on its own and is usable.

### Phase 1: two-channel recording and a plain transcript
- `MeetingRecorder`: mic plus system tap, each streamed to a CAF file.
- Post-call chunked transcription of both files, merged by timestamp,
  labelled "Me" and "Others".
- Menu items, red recording indicator, Meetings folder output.
- **Done when:** a 30-minute Teams call with AirPods produces a transcript
  where your lines are "Me" and the other people's are "Others"; memory stays
  flat during recording; quitting mid-call keeps everything recorded so far.

### Phase 2: who said what
- SpeakerKit diarization on the system channel → Speaker 1/2/…
- Rename-speaker editor.
- **Done when:** a 3-person call is labelled with the right number of
  speakers and most turns attributed correctly (spot-checked).

### Phase 3: polish
- Summary and action items (Apple Intelligence, chunked).
- Echo handling for laptop speakers: drop mic segments that duplicate
  system-audio speech at the same time.
- Per-app source selection; settings tab.
- **Done when:** a call on laptop speakers doesn't produce duplicated lines,
  and the summary appears when Apple Intelligence is on.

### Later (not scoped)
Live captions during the call (WhisperKit's `AudioStreamTranscriber`),
calendar-based titles, speaker voice profiles that are remembered.

## Testing

- Unit tests: timestamp merging of the two channels, chunk boundaries (no
  words lost or duplicated at a 30 s edge), Markdown rendering, speaker
  rename, echo de-duplication logic.
- Fixture test: a short pre-recorded two-speaker WAV goes through the whole
  pipeline in CI (diarization models are cached like the Whisper model).
- Manual: Teams with AirPods, Teams on laptop speakers, a 60-minute call
  (memory and time to transcribe), plugging/unplugging AirPods mid-call.

## Risks and open questions

1. **Process tap API** is new (14.2) and sparsely documented. Prove it out
   with a small spike first: capture Teams audio to a file, before building
   anything else.
2. **AirPods mic quality** drops to the Bluetooth headset profile during
   calls. Transcription of your own voice may be a bit worse than dictation.
3. **Teams' virtual audio device** ("Microsoft Teams Audio") may route
   audio unusually. Test tapping the Teams process versus all output.
4. **SpeakerKit model size and speed** on long audio are unknown. Measure
   them in phase 2.
5. **Mic sharing**: Teams and Local Flow both open the mic. This should be
   fine on macOS, but confirm there are no audio glitches on the call.
6. **macOS minimum**: meeting mode needs 14.2+. The rest of the app stays 14.0+.

## Rough size

| Phase | Effort |
|---|---|
| Spike: capture Teams audio via a process tap | 0.5 day |
| Phase 1 | 2–3 days |
| Phase 2 | 1–2 days |
| Phase 3 | 2 days |
