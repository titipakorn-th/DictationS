import AppKit
import Combine
import Darwin
import SwiftUI

/// The version of the running app, passed by the launcher.
private let appVersion = CommandLine.arguments.dropFirst().first ?? "unknown"

@MainActor
final class StatusModel: ObservableObject {
    @Published var kind = "loading"
    @Published var message = "Loading local speech model…"
    @Published var inputLevel = 0.0
    @Published var downloadProgress = 0.0

    func receive(_ line: String) {
        let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        if parts[0] == "level" {
            if let level = Double(parts[1]), level.isFinite {
                inputLevel = min(max(level, 0), 1)
            }
            return
        }
        if parts[0] == "progress" {
            if let progress = Double(parts[1]), progress.isFinite {
                downloadProgress = min(max(progress, 0), 1)
            }
            return
        }
        kind = parts[0]
        message = parts[1]
        downloadProgress = 0
        if kind != "recording" { inputLevel = 0 }
    }
}

struct IslandView: View {
    @ObservedObject var model: StatusModel

    private var tint: Color {
        switch model.kind {
        case "recording": return Color(red: 0.34, green: 0.91, blue: 0.61)
        case "error": return Color(red: 1.0, green: 0.38, blue: 0.36)
        case "complete": return Color(red: 0.46, green: 0.79, blue: 1.0)
        default: return Color.white
        }
    }

    private var title: String {
        switch model.kind {
        case "loading": return "Loading speech model"
        case "downloading": return "Preparing speech model"
        case "ready": return "DictationS is ready"
        case "recording": return "Listening"
        case "transcribing": return "Transcribing on this Mac"
        case "switching": return "Switching speech model"
        case "complete": return "Dictation complete"
        default: return "DictationS needs attention"
        }
    }

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle().fill(tint.opacity(0.14))
                Image(systemName: model.kind == "recording" ? "waveform" : "mic.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(model.message)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.67))
                    .lineLimit(model.kind == "error" ? 3 : 1)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            if model.kind == "downloading" {
                ZStack {
                    ProgressView(value: model.downloadProgress)
                        .progressViewStyle(.circular)
                        .tint(.white.opacity(0.9))
                        .frame(width: 31, height: 31)
                    Text("\(Int(model.downloadProgress * 100))")
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .accessibilityLabel("Model download \(Int(model.downloadProgress * 100)) percent")
                .animation(.linear(duration: 0.2), value: model.downloadProgress)
            } else if model.kind == "loading" || model.kind == "switching" || model.kind == "transcribing" {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.86))
            } else if model.kind == "recording" {
                HStack(alignment: .center, spacing: 3) {
                    ForEach(Array([10.0, 20.0, 14.0, 24.0, 12.0].enumerated()), id: \.offset) { bar in
                        Capsule().fill(tint)
                            .frame(width: 3, height: CGFloat(4 + bar.element * model.inputLevel))
                            .animation(.easeOut(duration: 0.12), value: model.inputLevel)
                    }
                }
            }
        }
        .padding(.horizontal, 17)
        .frame(width: model.kind == "error" ? 374 : 354, height: model.kind == "error" ? 82 : 68)
        .background(Color(red: 0.075, green: 0.08, blue: 0.09).opacity(0.97), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.13), lineWidth: 1))
        .shadow(color: .black.opacity(0.32), radius: 24, y: 8)
        .accessibilityElement(children: .combine)
    }

}

private enum IslandDismissal {
    /// Statuses that report a finished outcome, so the island fades out on its own.
    static let settledKinds: Set<String> = ["ready", "complete", "error"]
    /// How long a settled status stays on screen before the island starts to fade.
    static let settleDelay: TimeInterval = 1
    static let fadeDuration: TimeInterval = 0.2
}

/// A speech model DictationS can download and run.
private struct ModelChoice {
    let id: String
    let title: String
    /// Directory under `models/` that holds the downloaded files.
    let directory: String
    /// Files the model needs, by exact name.
    let files: [String]
    let kind: ModelKind
}

private enum ModelKind {
    /// A Qwen checkpoint: one weight file or an index plus shards.
    case qwen
    /// A Parakeet checkpoint: ONNX graphs and a vocabulary.
    case parakeet
}

private let modelChoices: [ModelChoice] = [
    ModelChoice(
        id: "0.6b",
        title: "Qwen3-ASR 0.6B",
        directory: "qwen3-asr-0.6b",
        files: ["config.json", "vocab.json", "merges.txt"],
        kind: .qwen
    ),
    ModelChoice(
        id: "parakeet-tdt-v3",
        title: "Parakeet TDT v3",
        directory: "parakeet-tdt-0.6b-v3",
        files: ["encoder-model.int8.onnx", "decoder_joint-model.int8.onnx", "vocab.txt"],
        kind: .parakeet
    ),
]

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = StatusModel()
    private var panel: NSPanel?
    private var statusItem: NSStatusItem?
    private var speechModelMenu: NSMenu?
    private var modelActionMenuSizes: [ObjectIdentifier: String] = [:]
    private var hideIslandWorkItem: DispatchWorkItem?
    private var statusGeneration = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMenuBarItem()
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 390, height: 86),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: IslandView(model: model))
        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 195, y: screen.visibleFrame.minY + 24))
        }
        panel.orderFrontRegardless()
        self.panel = panel

        DispatchQueue.global(qos: .utility).async { [weak self] in
            while let line = readLine() {
                DispatchQueue.main.async { self?.receiveStatus(line) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { NSApp.terminate(nil) }
        }
    }

    private func receiveStatus(_ line: String) {
        model.receive(line)
        statusGeneration += 1
        let generation = statusGeneration
        hideIslandWorkItem?.cancel()
        guard let panel else { return }

        panel.alphaValue = 1
        panel.orderFrontRegardless()
        guard IslandDismissal.settledKinds.contains(model.kind) else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.statusGeneration == generation,
                  IslandDismissal.settledKinds.contains(self.model.kind), let panel = self.panel else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = IslandDismissal.fadeDuration
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    guard self.statusGeneration == generation,
                          IslandDismissal.settledKinds.contains(self.model.kind) else {
                        panel.alphaValue = 1
                        panel.orderFrontRegardless()
                        return
                    }
                    panel.orderOut(nil)
                    panel.alphaValue = 1
                }
            }
        }
        hideIslandWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + IslandDismissal.settleDelay, execute: workItem)
    }

    private func installMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "DictationS")
        item.button?.toolTip = "DictationS"
        let menu = NSMenu()
        let modelMenu = NSMenu()
        modelMenu.delegate = self
        for choice in modelChoices {
            let actions = NSMenu()
            actions.delegate = self
            for (actionTitle, action) in [
                ("Use this model", #selector(selectModel(_:))),
                ("Remove downloaded model…", #selector(removeModel(_:))),
            ] {
                let item = NSMenuItem(title: actionTitle, action: action, keyEquivalent: "")
                item.target = self
                item.representedObject = choice.id
                actions.addItem(item)
            }
            let menuItem = NSMenuItem(title: choice.title, action: nil, keyEquivalent: "")
            menuItem.representedObject = choice.id
            menuItem.submenu = actions
            modelMenu.addItem(menuItem)
            modelActionMenuSizes[ObjectIdentifier(actions)] = choice.id
        }
        let modelItem = NSMenuItem(title: "Speech Model", action: nil, keyEquivalent: "")
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)
        speechModelMenu = modelMenu

        menu.addItem(.separator())
        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(.separator())
        let versionItem = NSMenuItem(title: "Version \(appVersion)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(NSMenuItem(title: "Quit DictationS", action: #selector(quitDictations), keyEquivalent: "q"))
        menu.items.last?.target = self
        item.menu = menu
        statusItem = item
    }

    func menuWillOpen(_ menu: NSMenu) {
        if let value = modelActionMenuSizes[ObjectIdentifier(menu)] {
            let title = modelChoices.first { $0.id == value }?.title ?? value
            for item in menu.items {
                if item.action == #selector(selectModel(_:)) {
                    item.title = "Use \(title)"
                    item.state = selectedModel() == Optional(value) ? .on : .off
                } else if item.action == #selector(removeModel(_:)) {
                    let exists = modelFilesExist(value)
                    let canRemove = exists && !["loading", "downloading", "switching"].contains(model.kind)
                    item.title = canRemove
                        ? "Remove downloaded model…"
                        : exists ? "Model is busy" : "Model not downloaded"
                    item.image = NSImage(
                        systemSymbolName: "trash",
                        accessibilityDescription: "Remove downloaded model"
                    )
                    item.isEnabled = canRemove
                }
            }
            return
        }
        guard menu === speechModelMenu else { return }
        for item in menu.items {
            guard let value = item.representedObject as? String else { continue }
            let downloaded = modelFilesAvailable(value)
            item.state = selectedModel() == Optional(value) ? .on : .off
            let title = modelChoices.first { $0.id == value }?.title ?? value
            item.title = "\(title) — \(downloaded ? "Downloaded" : "Download on launch")"
            item.image = NSImage(
                systemSymbolName: downloaded ? "checkmark.circle.fill" : "arrow.down.circle",
                accessibilityDescription: downloaded ? "Model downloaded" : "Model downloads on launch"
            )
        }
    }

    private func selectedModel() -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DictationS/model-size")
        let value = (try? String(contentsOf: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        if value == "none" { return nil }
        return modelChoices.contains { $0.id == value } ? value : "0.6b"
    }

    private func modelFilesAvailable(_ id: String) -> Bool {
        guard let choice = modelChoices.first(where: { $0.id == id }) else { return false }
        return containsCompleteModel(in: modelDirectory(choice), choice: choice)
    }

    private func modelFilesExist(_ id: String) -> Bool {
        guard let choice = modelChoices.first(where: { $0.id == id }) else { return false }
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: modelDirectory(choice).path)
        else { return false }
        return !files.isEmpty
    }

    private func modelDirectory(_ choice: ModelChoice) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DictationS/models", isDirectory: true)
            .appendingPathComponent(choice.directory, isDirectory: true)
    }

    private func containsCompleteModel(in directory: URL, choice: ModelChoice) -> Bool {
        let files = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        guard choice.files.allSatisfy(files.contains) else { return false }
        guard choice.kind == .qwen else { return true }
        if files.contains("model.safetensors") { return true }
        guard files.contains("model.safetensors.index.json"),
              let data = try? Data(contentsOf: directory.appendingPathComponent("model.safetensors.index.json")),
              let index = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let weights = index["weight_map"] as? [String: String] else { return false }
        return weights.values.allSatisfy { filename in
            !filename.contains("/") && !filename.contains("..") && files.contains(filename)
        }
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        let title = modelChoices.first { $0.id == value }?.title ?? value
        let alreadySelected = selectedModel() == value
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DictationS", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try (value + "\n").write(to: directory.appendingPathComponent("model-size"), atomically: true, encoding: .utf8)
            if alreadySelected {
                receiveStatus("ready\t\(title) is already selected.")
                return
            }
            statusItem?.menu?.items.first(where: { $0.title == "Speech Model" })?.submenu?.items.forEach {
                $0.state = ($0.representedObject as? String) == value ? .on : .off
            }
            receiveStatus("switching\tLoading the selected speech model…")
        } catch {
            receiveStatus("error\tCould not save model preference: \(error.localizedDescription)")
        }
    }

    @objc private func removeModel(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String,
              let choice = modelChoices.first(where: { $0.id == value }),
              modelFilesExist(value) else { return }
        let selected = selectedModel()
        let removesActiveModel = selected == Optional(value) && ProcessInfo.processInfo.environment["DICTATIONS_MODEL_DIR"] == nil
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove \(choice.title)?"
        alert.informativeText = removesActiveModel
            ? "DictationS will unload this model and stay open without a model. Choose a speech model later to download it again."
            : "This removes the downloaded model files from this Mac."
        alert.addButton(withTitle: "Remove Model")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DictationS", isDirectory: true)
        let models = support.appendingPathComponent("models", isDirectory: true)
        let destination = models.appendingPathComponent(choice.directory, isDirectory: true)
        do {
            // Resolve both sides before comparing. The support directory on disk
            // can be spelled differently than the path here — the filesystem is
            // case-insensitive, and only the resolved form compares equal.
            let expectedModels = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/DictationS/models", isDirectory: true)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            guard models.resolvingSymlinksInPath().standardizedFileURL == expectedModels,
                  destination.resolvingSymlinksInPath().standardizedFileURL == expectedModels
                    .appendingPathComponent(choice.directory, isDirectory: true)
                    .resolvingSymlinksInPath()
                    .standardizedFileURL else {
                throw CocoaError(.fileWriteNoPermission)
            }
            if removesActiveModel {
                try ("none\n").write(
                    to: support.appendingPathComponent("model-size"),
                    atomically: true,
                    encoding: .utf8
                )
                receiveStatus("switching\tUnloading the selected speech model…")
            }
            try FileManager.default.removeItem(at: destination)
            receiveStatus(removesActiveModel
                ? "ready\tModel removed. Choose a speech model to download it again."
                : "ready\t\(choice.title) model removed.")
        } catch {
            if removesActiveModel, let selected {
                try? (selected + "\n").write(
                    to: support.appendingPathComponent("model-size"),
                    atomically: true,
                    encoding: .utf8
                )
            }
            receiveStatus("error\tCould not remove model: \(error.localizedDescription)")
        }
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        latestRelease { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let release):
                    if isNewerVersion(release.version, than: appVersion) {
                        self.presentUpdateAvailable(release)
                    } else {
                        self.presentUpToDate(release)
                    }
                case .failure:
                    self.presentUpdateFailed()
                }
            }
        }
    }

    private func presentUpdateAvailable(_ release: UpdateRelease) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "DictationS \(release.version) is available"
        alert.informativeText = "You are running \(appVersion)."
        alert.addButton(withTitle: "Open Release Page")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.page)
        }
    }

    private func presentUpToDate(_ release: UpdateRelease) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "DictationS \(appVersion) is up to date"
        alert.informativeText = "The latest release is \(release.version)."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentUpdateFailed() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not check for updates"
        alert.informativeText = "GitHub did not return a release. Check your connection and try again."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func quitDictations() {
        let parent = getppid()
        if parent > 1 {
            let stopDownload = Process()
            stopDownload.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            stopDownload.arguments = ["-TERM", "-P", String(parent), "-x", "curl"]
            try? stopDownload.run()
            stopDownload.waitUntilExit()
            usleep(500_000)
            _ = kill(parent, SIGTERM)
        }
        NSApp.terminate(nil)
    }
}

@main
struct StatusIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
