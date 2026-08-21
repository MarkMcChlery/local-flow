import SwiftUI
import AppKit
import KeyboardShortcuts
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            DictionaryTab()
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
            SnippetsTab()
                .tabItem { Label("Snippets", systemImage: "text.badge.plus") }
            MemosTab()
                .tabItem { Label("Memos", systemImage: "folder.badge.gearshape") }
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding()
        .onAppear { controller.refreshPermissions() }
    }
}

// MARK: - General

struct GeneralTab: View {
    @EnvironmentObject var controller: AppController

    @AppStorage(SettingKey.holdToTalk) private var holdToTalk = true
    @AppStorage(SettingKey.llmCleanup) private var llmCleanup = true
    @AppStorage(SettingKey.soundFeedback) private var soundFeedback = true
    @AppStorage(SettingKey.injectionMethod) private var injectionMethod = "auto"
    @AppStorage(SettingKey.whisperModel) private var whisperModel = SettingKey.defaultModel
    @AppStorage(SettingKey.rawApps) private var rawApps = SettingKey.defaultRawApps

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private let modelOptions: [(name: String, label: String)] = [
        ("large-v3-v20240930_626MB", "Large v3 Turbo, compressed (best mix of speed and accuracy)"),
        ("distil-whisper_distil-large-v3", "Distil Large v3 (fast, accurate, English)"),
        ("small.en", "Small English (lighter, quicker download)"),
        ("base.en", "Base English (fastest, least accurate)"),
    ]

    var body: some View {
        Form {
            Section("Permissions") {
                PermissionRow(
                    name: "Microphone",
                    granted: controller.micGranted,
                    action: { controller.requestMicrophone() }
                )
                PermissionRow(
                    name: "Accessibility",
                    granted: controller.axGranted,
                    action: {
                        controller.promptForAccessibility()
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                        )
                    }
                )
                Button("Re-check permissions") { controller.refreshPermissions() }
            }

            Section("Hotkeys") {
                KeyboardShortcuts.Recorder("Dictation:", name: .dictate)
                KeyboardShortcuts.Recorder("Command Mode:", name: .commandMode)
                Toggle("Hold to talk (off = press once to start, again to stop)", isOn: $holdToTalk)
            }

            Section("Speech model") {
                Picker("Whisper model:", selection: $whisperModel) {
                    ForEach(modelOptions, id: \.name) { option in
                        Text(option.label).tag(option.name)
                    }
                }
                .onChange(of: whisperModel) { _, newValue in
                    Task { await controller.loadWhisper(model: newValue) }
                }
                Text("Changing model triggers a one-time download. Models are cached locally.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Behaviour") {
                Toggle("AI clean-up pass (Apple Intelligence, on-device)", isOn: $llmCleanup)
                    .disabled(!controller.llmAvailable)
                if !controller.llmAvailable {
                    Text("Apple Intelligence model not available. Using rule-based clean-up only. Check System Settings → Apple Intelligence & Siri.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Toggle("Sound feedback on start/stop", isOn: $soundFeedback)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enable in
                        do {
                            if enable {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Picker("Text insertion:", selection: $injectionMethod) {
                    Text("Accessibility first, paste as fallback").tag("auto")
                    Text("Always paste (Cmd+V)").tag("paste")
                }
            }

            Section("Raw mode apps (no clean-up, exact transcript)") {
                TextField("Bundle IDs, comma separated", text: $rawApps, axis: .vertical)
                    .lineLimit(2...4)
                Text("Dictation into these apps skips capitalisation and clean-up. Useful for terminals and code editors.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct PermissionRow: View {
    let name: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)
            Text(name)
            Spacer()
            if !granted {
                Button("Grant…", action: action)
            }
        }
    }
}

// MARK: - Dictionary

struct DictionaryTab: View {
    @ObservedObject private var store = AppController.shared.dictionaryStore

    var body: some View {
        VStack(alignment: .leading) {
            Text("When the transcriber consistently mishears a word (a name, product, or jargon), add the wrong and right spellings here. Applied to every dictation.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach($store.pairs) { $pair in
                    HStack {
                        TextField("Misheard as…", text: $pair.wrong)
                        Image(systemName: "arrow.right")
                        TextField("Should be…", text: $pair.right)
                        Button {
                            store.remove(pair)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Button("Add word pair") { store.add() }
        }
        .padding(.top, 8)
    }
}

// MARK: - Snippets

struct SnippetsTab: View {
    @ObservedObject private var store = AppController.shared.snippetStore

    var body: some View {
        VStack(alignment: .leading) {
            Text("Say exactly the trigger phrase (and nothing else) and the expansion text is inserted instead. Example: trigger \"insert my address\".")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach($store.snippets) { $snippet in
                    VStack(alignment: .leading) {
                        HStack {
                            TextField("Trigger phrase…", text: $snippet.trigger)
                                .font(.headline)
                            Button {
                                store.remove(snippet)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        TextField("Expansion text…", text: $snippet.expansion, axis: .vertical)
                            .lineLimit(1...5)
                    }
                    .padding(.vertical, 4)
                }
            }

            Button("Add snippet") { store.add() }
        }
        .padding(.top, 8)
    }
}

// MARK: - Memos

struct MemosTab: View {
    @AppStorage(SettingKey.saveMemos) private var saveMemos = false
    @AppStorage(SettingKey.memoFolder) private var memoFolder = SettingKey.defaultMemoFolder
    @AppStorage(SettingKey.memoTopics) private var memoTopics = SettingKey.defaultMemoTopics

    var body: some View {
        Form {
            Section("Voice memos") {
                Toggle("Save every dictation as a memo", isOn: $saveMemos)
                Text("Each dictation is also saved as a Markdown file, filed into a topic folder guessed from its content. Filing needs Apple Intelligence; without it, memos land in \"Uncategorized\". Dictation itself is never affected by this, even if saving fails.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Folder") {
                HStack {
                    TextField("Memo folder", text: $memoFolder)
                    Button("Choose…") { chooseFolder() }
                }
                Text("A topic subfolder is created inside this one for each memo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Topics (comma separated)") {
                TextField("Topics", text: $memoTopics, axis: .vertical)
                    .lineLimit(1...3)
                Text("\"Uncategorized\" is always available too, as a catch-all — no need to add it yourself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = MemoArchiver.baseFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        memoFolder = url.path
    }
}

// MARK: - About

struct AboutTab: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "mic.badge.plus")
                .font(.system(size: 44))
            Text("Local Flow").font(.title2).bold()
            Text("Fully local dictation for macOS. Audio and text never leave this Mac. No account, no subscription, no telemetry.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Speech model").foregroundStyle(.secondary)
                    Text(controller.whisperReady ? controller.selectedModel : "loading…")
                }
                GridRow {
                    Text("AI clean-up").foregroundStyle(.secondary)
                    Text(controller.llmAvailable ? "Apple Intelligence (on-device)" : "Rule-based only")
                }
                GridRow {
                    Text("Built with").foregroundStyle(.secondary)
                    Text("WhisperKit (Argmax OSS), Foundation Models, KeyboardShortcuts")
                }
            }
            .font(.callout)
        }
        .padding()
    }
}
