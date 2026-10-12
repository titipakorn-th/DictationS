import AppKit
import Combine
import Darwin
import SwiftUI

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
        for (title, value) in [("Qwen3-ASR 0.6B", "0.6b"), ("Qwen3-ASR 1.7B", "1.7b")] {
            let actions = NSMenu()
            actions.delegate = self
            for (actionTitle, action) in [
                ("Use this model", #selector(selectModel(_:))),
                ("Remove downloaded model…", #selector(removeModel(_:))),
            ] {
                let item = NSMenuItem(title: actionTitle, action: action, keyEquivalent: "")
                item.target = self
                item.representedObject = value
                actions.addItem(item)
            }
            let choice = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            choice.representedObject = value
            choice.submenu = actions
            modelMenu.addItem(choice)
            modelActionMenuSizes[ObjectIdentifier(actions)] = value
        }
        let modelItem = NSMenuItem(title: "Speech Model", action: nil, keyEquivalent: "")
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)
        speechModelMenu = modelMenu

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit DictationS", action: #selector(quitDictations), keyEquivalent: "q"))
        menu.items.last?.target = self
        item.menu = menu
        statusItem = item
    }

    func menuWillOpen(_ menu: NSMenu) {
        if let value = modelActionMenuSizes[ObjectIdentifier(menu)] {
            let size = value == "1.7b" ? "1.7B" : "0.6B"
            for item in menu.items {
                if item.action == #selector(selectModel(_:)) {
                    item.title = "Use Qwen3-ASR \(size)"
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
            let size = value == "1.7b" ? "1.7B" : "0.6B"
            item.title = "Qwen3-ASR \(size) — \(downloaded ? "Downloaded" : "Download on launch")"
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
        return value == "1.7b" ? "1.7b" : "0.6b"
    }

    private func modelFilesAvailable(_ size: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let models = home.appendingPathComponent("Library/Application Support/DictationS/models", isDirectory: true)
        let shared = models.appendingPathComponent("qwen3-asr-\(size)", isDirectory: true)
        return containsCompleteModel(in: shared)
    }

    private func modelFilesExist(_ size: String) -> Bool {
        guard ["0.6b", "1.7b"].contains(size) else { return false }
        let models = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DictationS/models", isDirectory: true)
        let directory = models.appendingPathComponent("qwen3-asr-\(size)", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return false }
        return !files.isEmpty
    }

    private func containsCompleteModel(in directory: URL) -> Bool {
        let files = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        guard ["config.json", "vocab.json", "merges.txt"].allSatisfy(files.contains) else { return false }
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
        let alreadySelected = selectedModel() == value
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DictationS", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try (value + "\n").write(to: directory.appendingPathComponent("model-size"), atomically: true, encoding: .utf8)
            if alreadySelected {
                receiveStatus("ready\tQwen3-ASR \(value == "1.7b" ? "1.7B" : "0.6B") is already selected.")
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
              ["0.6b", "1.7b"].contains(value), modelFilesExist(value) else { return }
        let selected = selectedModel()
        let removesActiveModel = selected == Optional(value) && ProcessInfo.processInfo.environment["DICTATIONS_MODEL_DIR"] == nil
        let displaySize = value == "1.7b" ? "1.7B" : "0.6B"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove Qwen3-ASR \(displaySize)?"
        alert.informativeText = removesActiveModel
            ? "DictationS will unload this model and stay open without a model. Choose a speech model later to download it again."
            : "This removes the downloaded model files from this Mac."
        alert.addButton(withTitle: "Remove Model")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DictationS", isDirectory: true)
        let models = support.appendingPathComponent("models", isDirectory: true)
        let destination = models.appendingPathComponent("qwen3-asr-\(value)", isDirectory: true)
        do {
            let expectedModels = FileManager.default.homeDirectoryForCurrentUser
                .resolvingSymlinksInPath()
                .appendingPathComponent("Library/Application Support/DictationS/models", isDirectory: true)
                .standardizedFileURL
            guard models.resolvingSymlinksInPath().standardizedFileURL == expectedModels,
                  destination.resolvingSymlinksInPath().standardizedFileURL == expectedModels
                    .appendingPathComponent("qwen3-asr-\(value)", isDirectory: true)
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
                : "ready\tQwen3-ASR \(displaySize) model removed.")
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
