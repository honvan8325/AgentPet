import AppKit
import SwiftUI

@MainActor
final class PetPanelController: NSObject, NSWindowDelegate {
    private let model: AgentPetModel
    private let panel: NSPanel

    init(model: AgentPetModel) {
        self.model = model
        panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 120, height: 130),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: PetView(model: model))
        model.onPetSizeChange = { [weak self] in self?.applyLayout() }
        model.onPetLayoutChange = { [weak self] in self?.applyLayout() }
        model.onPetDragEnd = { [weak self] in self?.clampAndSave() }
        restoreFrame()
    }

    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }
    func toggle() { panel.isVisible ? hide() : show() }

    func windowDidChangeScreen(_ notification: Notification) { clampAndSave() }

    func savePosition() { clampAndSave() }

    private func applyLayout() {
        let old = panel.frame
        let scale = CGFloat(model.petSize.pixelScale)
        let size = NSSize(
            width: 120 * scale,
            height: (96 + 4 + (model.showUsageHUD ? 14 : 0) + 16) * scale
        )
        panel.setFrame(
            CGRect(x: old.midX - size.width / 2, y: old.midY - size.height / 2, width: size.width, height: size.height),
            display: true,
            animate: true
        )
        clampAndSave()
    }

    private func restoreFrame() {
        let scale = CGFloat(model.petSize.pixelScale)
        let size = NSSize(
            width: 120 * scale,
            height: (96 + 4 + (model.showUsageHUD ? 14 : 0) + 16) * scale
        )
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
        if let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            var frame = panel.frame
            let margin = min(56, frame.width / 3, frame.height / 3)
            frame.origin.x = min(max(frame.origin.x, visible.minX - frame.width + margin), visible.maxX - margin)
            frame.origin.y = min(max(frame.origin.y, visible.minY - frame.height + margin), visible.maxY - margin)
            if frame.origin != panel.frame.origin { panel.setFrameOrigin(frame.origin) }
        }
        UserDefaults.standard.set(panel.frame.origin.x, forKey: "petWindowX")
        UserDefaults.standard.set(panel.frame.origin.y, forKey: "petWindowY")
    }
}

@MainActor
final class DashboardWindowController {
    private let model: AgentPetModel
    private let window: NSWindow

    init(model: AgentPetModel) {
        self.model = model
        window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 390, height: 500),
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
            contentRect: CGRect(x: 0, y: 0, width: 420, height: 500),
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
