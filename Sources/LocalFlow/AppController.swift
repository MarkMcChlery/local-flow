import SwiftUI
import AVFoundation
import ApplicationServices
import KeyboardShortcuts

enum LFError: LocalizedError {
    case modelNotReady
    case noMicrophone
    case noSelection
    case llmUnavailable

    var errorDescription: String? {
        switch self {
        case .modelNotReady: return "Speech model is still loading"
        case .noMicrophone: return "No microphone available"
        case .noSelection: return "Select some text first"
        case .llmUnavailable: return "Command Mode needs Apple Intelligence (macOS 26+)"
        }
    }
}

enum FlowState: Equatable {
    case startingUp
    case downloadingModel
    case idle
    case recording
    case recordingCommand
    case transcribing
    case cleaning
    case error(String)

    var symbolName: String {
        switch self {
        case .startingUp, .downloadingModel: return "hourglass"
        case .idle: return "mic"
        case .recording: return "mic.fill"
        case .recordingCommand: return "wand.and.rays"
        case .transcribing: return "waveform"
        case .cleaning: return "wand.and.stars"
        case .error: return "exclamationmark.triangle"
        }
    }

    var label: String {
        switch self {
        case .startingUp: return "Starting up…"
        case .downloadingModel: return "Downloading speech model (first run only)…"
        case .idle: return "Ready — hold your hotkey and speak"
        case .recording: return "Listening…"
        case .recordingCommand: return "Listening for a command…"
        case .transcribing: return "Transcribing…"
        case .cleaning: return "Cleaning up…"
        case .error(let message): return "Problem: \(message)"
        }
    }
}

struct HistoryItem: Identifiable {
    let id = UUID()
    let text: String
    /// Process the text was typed into, or nil if it was only copied to the
    /// clipboard. Undo is only sent while this app is frontmost.
    let targetPID: pid_t?
    let date = Date()
    var preview: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 48 ? String(trimmed.prefix(48)) + "…" : trimmed
    }
}

// Settings keys, shared between the controller and the settings UI.
enum SettingKey {
    static let whisperModel = "whisperModel"
    static let holdToTalk = "holdToTalk"
    static let llmCleanup = "llmCleanup"
    static let soundFeedback = "soundFeedback"
    static let injectionMethod = "injectionMethod" // "auto" or "paste"
    static let rawApps = "rawApps"
    static let saveMemos = "saveMemos"
    static let memoFolder = "memoFolder"
    static let memoTopics = "memoTopics"

    static let defaultModel = "large-v3-v20240930_626MB"
    static let defaultRawApps = "com.apple.Terminal, com.googlecode.iterm2, com.microsoft.VSCode, com.apple.dt.Xcode, dev.zed.Zed"
    // In the home folder rather than ~/Documents, which iCloud Drive may sync.
    static let defaultMemoFolder = "~/LocalFlow Memos"
    static let defaultMemoTopics = "Work, Personal, Ideas"
}

@MainActor
final class AppController: ObservableObject {
    static let shared = AppController()

    @Published var state: FlowState = .startingUp
    @Published var history: [HistoryItem] = []
    @Published var micGranted = false
    @Published var axGranted = false
    @Published var whisperReady = false
    @Published var llmAvailable = false

    let dictionaryStore = DictionaryStore()
    let snippetStore = SnippetStore()

    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let injector = TextInjector()

    private var commandKeyDown = false
    private var frontAppAtStart: String?
    // The app the user was in when they started speaking. Text is only typed
    // if that app is still frontmost when it is ready.
    private var targetPIDAtStart: pid_t?
    private var commandSelection: String?
    private var errorResetTask: Task<Void, Never>?

    var permissionsOK: Bool { micGranted && axGranted }

    var statusLine: String {
        if case .idle = state, !whisperReady { return "Loading speech model…" }
        return state.label
    }

    private var defaults: UserDefaults { .standard }

    private var holdToTalk: Bool {
        defaults.object(forKey: SettingKey.holdToTalk) as? Bool ?? true
    }

    private var soundFeedback: Bool {
        defaults.object(forKey: SettingKey.soundFeedback) as? Bool ?? true
    }

    private var llmCleanupEnabled: Bool {
        defaults.object(forKey: SettingKey.llmCleanup) as? Bool ?? true
    }

    var selectedModel: String {
        defaults.string(forKey: SettingKey.whisperModel) ?? SettingKey.defaultModel
    }

    private var rawAppIDs: [String] {
        let raw = defaults.string(forKey: SettingKey.rawApps) ?? SettingKey.defaultRawApps
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }

    private var saveMemosEnabled: Bool {
        defaults.object(forKey: SettingKey.saveMemos) as? Bool ?? false
    }

    private var memoTopics: [String] {
        let raw = defaults.string(forKey: SettingKey.memoTopics) ?? SettingKey.defaultMemoTopics
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: - Startup

    func startup() {
        registerHotkeys()
        refreshPermissions()
        llmAvailable = Cleaner.appleModelAvailable
        Task { await loadWhisper(model: selectedModel) }

        // Prompt for Accessibility on first launch so the user sees the system dialog.
        if !axGranted {
            promptForAccessibility()
        }
    }

    func loadWhisper(model: String) async {
        whisperReady = false
        state = .downloadingModel
        do {
            try await transcriber.load(model: model)
            whisperReady = true
            state = .idle
        } catch {
            state = .error("Model load failed: \(error.localizedDescription)")
        }
    }

    func refreshPermissions() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        axGranted = AXIsProcessTrusted()
    }

    func promptForAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                self.micGranted = granted
            }
        }
    }

    // MARK: - Hotkeys

    private func registerHotkeys() {
        KeyboardShortcuts.onKeyDown(for: .dictate) { [weak self] in
            guard let self else { return }
            if self.holdToTalk {
                self.beginDictation()
            } else {
                // Toggle state is derived from the actual FlowState rather
                // than a separate flag, which could desync whenever
                // beginDictation bailed out on one of its guards (B2).
                if self.state == .recording {
                    self.endDictation()
                } else {
                    self.beginDictation()
                }
            }
        }
        KeyboardShortcuts.onKeyUp(for: .dictate) { [weak self] in
            guard let self, self.holdToTalk else { return }
            self.endDictation()
        }
        KeyboardShortcuts.onKeyDown(for: .commandMode) { [weak self] in
            self?.beginCommandMode()
        }
        KeyboardShortcuts.onKeyUp(for: .commandMode) { [weak self] in
            self?.endCommandMode()
        }
    }

    // MARK: - Dictation flow

    private func beginDictation() {
        guard state == .idle else { return }
        guard whisperReady else { flashError(LFError.modelNotReady.localizedDescription); return }
        guard micGranted else { requestMicrophone(); return }

        let frontApp = NSWorkspace.shared.frontmostApplication
        frontAppAtStart = frontApp?.bundleIdentifier?.lowercased()
        targetPIDAtStart = frontApp?.processIdentifier
        do {
            try recorder.start()
            state = .recording
            playSound("Pop")
        } catch {
            flashError("Could not start recording: \(error.localizedDescription)")
        }
    }

    private func endDictation() {
        guard state == .recording else { return }
        playSound("Bottle")
        let samples = recorder.stop()
        // Ignore accidental taps shorter than ~0.3 seconds of audio.
        guard samples.count > 4800 else { state = .idle; return }

        state = .transcribing
        Task {
            do {
                var text = try await transcriber.transcribe(samples)
                text = RuleCleaner.stripArtifacts(text)
                guard !text.isEmpty else { state = .idle; return }

                // 1. Voice snippets: exact trigger phrase expands to a template.
                if let expansion = snippetStore.expansion(for: text) {
                    insert(expansion)
                    return
                }

                // 2. Personal dictionary: fix consistently misheard words.
                text = dictionaryStore.apply(to: text)

                // 3. Clean-up pass, skipped for "raw" apps like terminals and editors.
                let isRawTarget = rawAppIDs.contains(frontAppAtStart ?? "")
                if !isRawTarget {
                    text = RuleCleaner.clean(text)
                    if llmCleanupEnabled && llmAvailable {
                        state = .cleaning
                        if let cleaned = await Cleaner.cleanDictation(text) {
                            text = cleaned
                        }
                        // On any LLM failure we silently keep the rule-cleaned text:
                        // never lose the user's words.
                    }
                }

                insert(text)

                // Memo archiving: only for genuine freeform dictation, never
                // snippet expansions (handled by the early return above) or
                // Command Mode rewrites. Fire-and-forget and best-effort —
                // a failure here must never affect the dictation just typed.
                if saveMemosEnabled {
                    let topics = memoTopics
                    Task { await MemoArchiver.archive(text: text, topics: topics) }
                }
            } catch {
                flashError(error.localizedDescription)
            }
        }
    }

    // MARK: - Command Mode flow

    private func beginCommandMode() {
        guard state == .idle else { return }
        guard whisperReady else { flashError(LFError.modelNotReady.localizedDescription); return }
        guard llmAvailable else { flashError(LFError.llmUnavailable.localizedDescription); return }
        guard micGranted else { requestMicrophone(); return }

        commandKeyDown = true
        targetPIDAtStart = NSWorkspace.shared.frontmostApplication?.processIdentifier
        Task {
            // Capture the selected text in the frontmost app before recording.
            let selection = await injector.copySelectedText()
            // If the key was already released while we were capturing the
            // selection, do not start recording at all: previously this
            // could leave the recorder running with no matching stop (B1).
            guard commandKeyDown else { return }
            guard let selection, !selection.isEmpty else {
                flashError(LFError.noSelection.localizedDescription)
                return
            }
            commandSelection = selection
            do {
                try recorder.start()
                state = .recordingCommand
                playSound("Pop")
            } catch {
                flashError("Could not start recording: \(error.localizedDescription)")
            }
        }
    }

    private func endCommandMode() {
        commandKeyDown = false
        guard state == .recordingCommand else { return }
        playSound("Bottle")
        let samples = recorder.stop()
        guard samples.count > 4800, let selection = commandSelection else {
            commandSelection = nil
            state = .idle
            return
        }

        state = .transcribing
        Task {
            do {
                let instruction = RuleCleaner.stripArtifacts(try await transcriber.transcribe(samples))
                guard !instruction.isEmpty else { state = .idle; return }

                state = .cleaning
                guard let rewritten = await Cleaner.applyCommand(instruction: instruction, to: selection) else {
                    flashError("The rewrite failed — your text is unchanged")
                    return
                }
                // The original selection is still selected in the target app,
                // so inserting replaces it.
                insert(rewritten)
            } catch {
                flashError(error.localizedDescription)
            }
        }
    }

    // MARK: - Insertion, history, undo

    private func insert(_ text: String) {
        let target = targetPIDAtStart
        targetPIDAtStart = nil
        commandSelection = nil

        // If focus moved while we were transcribing, typing now would put the
        // text into whatever app the user switched to. Copy it instead.
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let target, frontPID == target else {
            copyToClipboard(text)
            addToHistory(HistoryItem(text: text, targetPID: nil))
            flashError("Focus changed, so the text was copied to the clipboard instead")
            return
        }

        let method = defaults.string(forKey: SettingKey.injectionMethod) ?? "auto"
        injector.insert(text, preferAccessibility: method == "auto")
        addToHistory(HistoryItem(text: text, targetPID: target))
        state = .idle
    }

    private func addToHistory(_ item: HistoryItem) {
        history.insert(item, at: 0)
        if history.count > 20 { history.removeLast() }
    }

    func undoLastInsert() {
        guard let last = history.first else { return }
        guard let target = last.targetPID else {
            flashError("The last dictation was copied, not typed, so there is nothing to undo")
            return
        }
        // Cmd+Z goes to the frontmost app; only send it to the app we typed into.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target else {
            let name = NSRunningApplication(processIdentifier: target)?.localizedName ?? "the app you dictated into"
            flashError("Switch back to \(name) to undo")
            return
        }
        injector.sendUndoKeystroke()
        history.removeFirst()
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Helpers

    private func flashError(_ message: String) {
        state = .error(message)
        errorResetTask?.cancel()
        errorResetTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled, case .error = self.state {
                self.state = .idle
            }
        }
    }

    private func playSound(_ name: String) {
        guard soundFeedback else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
