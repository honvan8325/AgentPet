import AppKit
import SwiftUI

@MainActor
final class PetPanelController: NSObject, NSWindowDelegate {
    private let model: AgentPetModel
    private let panel: NSPanel
    private var layoutNeedsApply = false

    init(model: AgentPetModel) {
        self.model = model
        let metrics = PetSceneMetrics(
            manifest: SpriteAtlasStore.shared.manifest,
            anchors: SpriteAtlasStore.shared.anchors,
            includesHUD: model.showUsageHUD && !(model.codex.usage?.availableWindows.isEmpty ?? true),
            hudWindowCount: model.codex.usage?.availableWindows.count ?? 0,
            bubbleSize: SpriteAtlasStore.shared.bubblePixelSize,
            chatGPTEnabled: model.chatGPTWeb.isEnabled,
            zoom: CGFloat(model.petScale)
        )
        panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: metrics.width * metrics.zoom, height: metrics.height * metrics.zoom),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = model.alwaysOnTop ? .floating : .normal
        panel.hidesOnDeactivate = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: PetView(model: model))
        model.onPetSizeChange = { [weak self] in self?.applyLayout() }
        model.onPetLayoutChange = { [weak self] in self?.applyLayout() }
        model.onPetDragEnd = { [weak self] in
            guard let self else { return }
            if layoutNeedsApply { applyLayout() } else { clampAndSave() }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        restoreFrame()
    }

    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }
    func toggle() { panel.isVisible ? hide() : show() }

    func windowDidChangeScreen(_ notification: Notification) {
        guard !model.isPetDragging else { return }
        clampAndSave()
    }

    func savePosition() { clampAndSave() }

    private func applyLayout() {
        guard !model.isPetDragging else { layoutNeedsApply = true; return }
        layoutNeedsApply = false
        let old = panel.frame
        let metrics = currentMetrics
        let size = NSSize(width: metrics.width * metrics.zoom, height: metrics.height * metrics.zoom)
        panel.level = model.alwaysOnTop ? .floating : .normal
        guard old.size != size else { clampAndSave(); return }
        panel.setFrame(
            CGRect(x: old.minX, y: old.maxY - size.height, width: size.width, height: size.height),
            display: true,
            animate: !model.reduceMotion
        )
        clampAndSave()
    }

    private func restoreFrame() {
        let metrics = currentMetrics
        let size = NSSize(width: metrics.width * metrics.zoom, height: metrics.height * metrics.zoom)
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "petWindowX") != nil,
           defaults.object(forKey: "petWindowY") != nil {
            panel.setFrame(
                CGRect(
                    x: defaults.double(forKey: "petWindowX"),
                    y: defaults.double(forKey: "petWindowY"),
                    width: size.width,
                    height: size.height
                ),
                display: false
            )
        } else {
            let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
            panel.setFrameOrigin(CGPoint(x: visible.maxX - size.width - 32, y: visible.minY + 28))
            panel.setContentSize(size)
        }
        clampAndSave()
    }

    private func clampAndSave() {
        if model.keepFullyVisible,
           let visible = panel.screen?.visibleFrame ?? nearestScreen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            var frame = panel.frame
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
            if frame.origin != panel.frame.origin { panel.setFrameOrigin(frame.origin) }
        }
        UserDefaults.standard.set(panel.frame.origin.x, forKey: "petWindowX")
        UserDefaults.standard.set(panel.frame.origin.y, forKey: "petWindowY")
    }

    @objc private func screenConfigurationDidChange(_ notification: Notification) {
        guard !model.isPetDragging else { return }
        if panel.screen == nil, let visible = nearestScreen?.visibleFrame {
            var frame = panel.frame
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
            panel.setFrameOrigin(frame.origin)
        }
        clampAndSave()
    }

    private var currentMetrics: PetSceneMetrics {
        PetSceneMetrics(
            manifest: SpriteAtlasStore.shared.manifest,
            anchors: SpriteAtlasStore.shared.anchors,
            includesHUD: hasVisibleHUD,
            hudWindowCount: model.codex.usage?.availableWindows.count ?? 0,
            bubbleSize: SpriteAtlasStore.shared.bubblePixelSize,
            chatGPTEnabled: model.chatGPTWeb.isEnabled,
            zoom: CGFloat(model.petScale)
        )
    }

    private var hasVisibleHUD: Bool {
        model.showUsageHUD && !(model.codex.usage?.availableWindows.isEmpty ?? true)
    }

    private var nearestScreen: NSScreen? {
        let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        return NSScreen.screens.min { left, right in
            hypot(left.frame.midX - center.x, left.frame.midY - center.y)
                < hypot(right.frame.midX - center.x, right.frame.midY - center.y)
        }
    }
}

@MainActor
final class DashboardWindowController {
    private let model: AgentPetModel
    private let window: NSWindow

    init(model: AgentPetModel) {
        self.model = model
        window = NSWindow(
            contentRect: CGRect(origin: .zero, size: DashboardView.contentSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AgentPet"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: DashboardView(model: model))
        window.center()
    }

    var isVisible: Bool { window.isVisible }

    func show() {
        Task { await model.refreshNow() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() { window.orderOut(nil) }
    func toggle() { isVisible ? hide() : show() }
}

@MainActor
final class SettingsWindowController {
    private let window: NSWindow

    init(model: AgentPetModel) {
        window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 440, height: 680),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AgentPet Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.center()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class OnboardingWindowController {
    private let window: NSWindow

    init(model: AgentPetModel) {
        let onboardingWindow = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 480, height: 390),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window = onboardingWindow
        window.title = "Welcome to AgentPet"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OnboardingView(model: model) { [weak onboardingWindow] in onboardingWindow?.close() })
        window.center()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
