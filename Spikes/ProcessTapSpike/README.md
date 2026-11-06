# Process tap spike

Throwaway CLI for risks #1 and #3 in `docs/meeting-mode.md`. It uses a private
Core Audio process tap and aggregate device to stream one app's audio (including
matching helpers), one PID, or all system output to **16 kHz mono Float32 CAF**.
It does not change or integrate with LocalFlow. Requires macOS **14.2+**; the
package remains macOS 14 / Swift tools 5.10, with Swift 5 language mode.

## Build and test

From the repository root, using Xcode's Swift toolchain:

```sh
swift build
swift build -c release
swift test
swift run ProcessTapSpike --list
```

The executable embeds `CLI/Info.plist` in `__TEXT,__info_plist` with linker
`-sectcreate` flags. Its bundle identifier is
`com.markmcchlery.localflow.tapspike`, and it declares
`NSAudioCaptureUsageDescription`. The manifest resolves the plist relative to
itself, so it also works with `swift --package-path ...`. The flags work in both
debug and release builds; no fallback is needed.

If running inside a restricted development sandbox that blocks the default
Clang module cache or nested SwiftPM sandbox, the validation commands used here
are `CLANG_MODULE_CACHE_PATH=/tmp/process-tap-module-cache swift build
--disable-sandbox` (and the equivalent `test`, `run`, and `build -c release`).
This does not grant audio access to a sandboxed process. SwiftPM may also emit
user-cache warnings in that environment.

## Run

Start the target application and play audio before enumerating it:

```sh
swift run ProcessTapSpike --list
swift run ProcessTapSpike --bundle com.microsoft.teams --seconds 30 --out ./teams.caf
swift run ProcessTapSpike --pid 12345 --seconds 10 --out ./process.caf
swift run ProcessTapSpike --all --seconds 30 --out ./system.caf
```

`--list` prints Core Audio object IDs, PIDs, bundle IDs, output-running state,
and `[Teams]` beside IDs containing `com.microsoft.teams`. Bundle matching is
case-sensitive equality or prefix matching, so all currently known helpers
are included. The process set is a snapshot: restart capture if new helpers
appear. All-output mode excludes this tool's own Core Audio process object.
If a sandbox produces only a table header, run the executable in Terminal
outside that sandbox to enumerate actual audio processes.

Choose exactly one target. `--list` is standalone. Duration defaults to 10
seconds and accepts positive finite fractional seconds. Output defaults to
`./tap-<UTC timestamp with milliseconds>Z.caf`. Use a `.caf` output path; an
existing file is refused. Parent directories must already exist. `--help`
prints usage. Invalid arguments print usage and exit nonzero.

Press **Ctrl-C** to stop early. The tool stops audio IO, drains the bounded
queue, flushes the converter, closes the file, then destroys the IO proc,
aggregate device, and tap. Error paths also close the file and release these
resources; teardown failures are reported with their OSStatus. SIGKILL cannot
run cleanup. Streamed files use bounded memory; no recording-sized buffer is
kept.

## Grant System Audio Recording permission

On the first capture, macOS may prompt to allow system audio recording. Allow
it for the executable or responsible terminal/host app shown by macOS. Check
**System Settings > Privacy & Security > Screen & System Audio Recording**
and enable System Audio Recording for that entry. Quit and relaunch the tool
or terminal if macOS requests it. Rebuilding an unsigned/ad-hoc CLI can change
how macOS identifies it; use the same built executable while comparing runs.
No microphone permission is needed by this spike.

See Apple's [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps)
for the permission and tap/aggregate-device workflow.

Every second the CLI prints elapsed wall time, RMS/peak dBFS for converted
samples processed in that interval, and cumulative frames written. At the end
it prints the tap's source format, actual written duration, and absolute file
path. The last partial interval contributes to whole-capture metering. An
empty/silent capture (whole-recording peak below -60 dBFS) warns about permission
or nothing playing. Silence/empty meter windows display -120 dBFS. Playing
local audio during a capture and listening to the resulting CAF is necessary
to establish that capture works; `--list` alone cannot establish this.

## Implementation and limits

- `Core/`: argument validation, process matching, streaming level meter,
  OSStatus formatting, deterministic UTC filenames; no Core Audio calls.
- `CLI/`: tap creation, source ASBD, default output device as main aggregate
  sub-device, tap UID/auto-start, IO callback, AVAudioConverter and AVAudioFile.
- `Ring/`: small additional C target using always-lock-free C11 atomic counters.
  A single producer/single consumer ring has 64 preallocated slots, two buffers
  per slot, 64 KiB per buffer (about 8 MiB total). Pages are touched before IO.
  The callback only validates and copies data, then publishes the slot. It does
  no file IO, conversion, locking, dispatch, logging, or allocation. The CLI
  thread drains at 5 ms intervals and converts/writes in blocks of at most 4096
  output frames. The ring drops incoming blocks if full or the layout is invalid;
  any drops produce a nonzero exit with a finalized partial CAF.
- Stereo PCM is supported in interleaved or planar form. The aggregate's tap
  input buffers follow the main sub-device's inputs; only the final tap buffers
  are copied, excluding any hardware microphone inputs. Both buffer count and
  channel/byte layout are checked in the callback.
- This spike intentionally does not handle live device switches or rebuild a
  tap on format changes. Stop/restart after changing output routes. Source
  format/layout changes can yield drops or silence and need manual observation.
- Output levels are measured after mono conversion, so opposite-phase stereo
  channels can cancel. Duration reports actual samples written, not wall time.
- A forced error can leave a partial recording on disk; it is never deleted.

## Manual comparison

Use identical Teams playback for bundle and all-output runs. Repeat with the
Teams virtual device selected, laptop speakers, and AirPods during a call.
Listen to both CAFs and note source ASBD, meter levels, missing audio, duration,
and Activity Monitor CPU/memory over a longer run. Run a quiet capture to check
the silence warning, and interrupt a longer run with Ctrl-C to check playback
of the finalized partial file. These hardware/permission checks have not been
established by the unit tests or sandbox process listing.

## Findings

- Teams process vs all output:
- Teams' virtual device behaviour:
- AirPods:
- Sample format seen: (2026-11-06, MacBook Pro Speakers, `--all`) tap 2 ch 48 kHz Float32 interleaved; 1 buffer per callback, 4096 bytes (512 frames), ~94 callbacks/s; 0 drops; output 16 kHz mono Float32 CAF verified with `afinfo`. All three `--io-queue` modes (dedicated/main/nil) captured audio.
- First-run note: the very first live `--all` run got 0 IO callbacks with `AudioDeviceStart` returning noErr; after adding `kAudioAggregateDeviceIsStackedKey: false` (and/or the System Audio Recording permission being granted in between) every mode works. Root cause not isolated.
- CPU/memory:
