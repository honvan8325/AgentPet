import AppKit
import Combine
import SwiftUI

struct PetView: View {
    @ObservedObject var model: AgentPetModel
    @ObservedObject private var sessions: SessionStore
    @ObservedObject private var codex: CodexClient
    @ObservedObject private var assets: SpriteAtlasStore
    @ObservedObject private var player: AnimationPlayer
    private let engine: PetBehaviorEngine
    @State private var isHovering = false
    @State private var isDragging = false
    @State private var effectTask: Task<Void, Never>?

    init(model: AgentPetModel) {
        self.model = model
        _sessions = ObservedObject(wrappedValue: model.sessions)
        _codex = ObservedObject(wrappedValue: model.codex)
        _assets = ObservedObject(wrappedValue: .shared)
        _player = ObservedObject(wrappedValue: model.animationPlayer)
        engine = model.behaviorEngine
    }

    private var behaviorContext: PetBehaviorContext {
        let activity: PetActivity
        switch model.petState {
        case .idle: activity = .idle
        case .typing: activity = .working
        case .needsInput: activity = .waiting
        case .unknown: activity = .unknown
        case .disconnected: activity = .disconnected
        case .syncing: activity = .syncing
        case .reconnecting: activity = .reconnecting
        case .paused: activity = .paused
        }
        let mood: PetMood
        switch activity {
        case .thinking: mood = .curious
        case .waiting, .disconnected, .reconnecting, .unknown: mood = .worried
        case .sleeping: mood = .sleepy
        default: mood = isHovering ? .curious : (sessions.runningCount > 0 ? .happy : .neutral)
        }
        return PetBehaviorContext(
            activity: activity,
            energy: PetEnergy.select(remaining: codex.usage?.energyWindow?.remaining) ?? .focused,
            mood: mood,
            runningCount: sessions.runningCount,
            needsInputCount: sessions.needsInputCount,
            isHovering: isHovering,
            isDragging: isDragging,
            isPaused: model.isPetPaused,
            reduceMotion: model.reduceMotion,
            themeID: model.selectedTheme.id
        )
    }

    private var metrics: PetSceneMetrics {
        PetSceneMetrics(
            manifest: assets.manifest,
            anchors: assets.anchors,
            includesHUD: hasVisibleHUD,
            hudWindowCount: codex.usage?.availableWindows.count ?? 0,
            bubbleSize: assets.bubblePixelSize,
            zoom: CGFloat(model.petSize.pixelScale)
        )
    }

    private var hasVisibleHUD: Bool {
        model.showUsageHUD && !(codex.usage?.availableWindows.isEmpty ?? true)
    }

    var body: some View {
        let scene = metrics
        ZStack(alignment: .topLeading) {
            TimelineView(.animation(
                minimumInterval: engine.frameInterval,
                paused: model.reduceMotion && engine.player.effect == nil && engine.player.playback.clipID.hasPrefix("idle.")
            )) { timeline in
                let manifest = assets.manifest
                let playback = player.playback
                let clip = manifest?.clips[playback.clipID]
                let frame = clip.flatMap { engine.player.frame(for: $0, at: timeline.date) }
                let image = frame.flatMap { assets.image(for: $0) }

                ZStack(alignment: .topLeading) {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.none)
                            .frame(width: scene.canvasWidth * scene.zoom, height: scene.canvasHeight * scene.zoom)
                            .offset(x: scene.spriteOrigin.x * scene.zoom, y: scene.spriteOrigin.y * scene.zoom)
                    }

                    if model.showUsageHUD, let snapshot = codex.usage, !snapshot.availableWindows.isEmpty {
                        PixelHUDView(snapshot: snapshot, manifest: manifest, assets: assets, scale: scene.zoom)
                            .offset(x: scene.hudOrigin.x * scene.zoom, y: scene.hudOrigin.y * scene.zoom)
                    }

                    if sessions.runningCount > 0, let bubble = assets.hudImage("bubble") {
                        ZStack(alignment: .topLeading) {
                            Image(nsImage: bubble)
                                .resizable()
                                .interpolation(.none)
                                .frame(width: scene.bubbleWidth * scene.zoom, height: scene.bubbleHeight * scene.zoom)
                            PixelCountView(count: sessions.runningCount, scale: scene.zoom, assets: assets)
                                .frame(
                                    width: scene.bubbleWidth * scene.zoom,
                                    height: scene.bubbleHeight * scene.zoom * 0.8
                                )
                        }
                        .offset(x: scene.bubbleOrigin.x * scene.zoom, y: scene.bubbleOrigin.y * scene.zoom)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        .animation(.easeOut(duration: 0.15), value: sessions.runningCount > 0)
                    }

                    if let effect = player.effect, let effectMetadata = manifest?.effects[effect.name] {
                        let elapsed = timeline.date.timeIntervalSince(effect.startedAt)
                        let index = min(effectMetadata.frames - 1, max(0, Int(elapsed / 0.1)))
                        if let effectImage = assets.effectImage(effect.name, frame: index) {
                            Image(nsImage: effectImage)
                                .resizable()
                                .interpolation(.none)
                                .frame(width: CGFloat(effectMetadata.outputSize[0]) * scene.zoom, height: CGFloat(effectMetadata.outputSize[1]) * scene.zoom)
                                .offset(
                                    x: (scene.effectAnchor.x - CGFloat(effectMetadata.outputSize[0]) / 2) * scene.zoom,
                                    y: (scene.effectAnchor.y - CGFloat(effectMetadata.outputSize[1]) / 2) * scene.zoom
                                )
                        }
                    }

                    PetInteractionView(
                        onClick: engine.click,
                        onDoubleClick: engine.doubleClick,
                        onRepeatedClick: engine.repeatedClick,
                        onHover: { isHovering = $0 },
                        onDragStart: { isDragging = true; model.isPetDragging = true },
                        onDragEnd: { isDragging = false; model.isPetDragging = false; model.onPetDragEnd?() },
                        onOpenDashboard: model.openDashboard,
                        onOpenSettings: model.openSettings,
                        onHidePet: model.hidePet
                    )
                    .frame(width: scene.canvasWidth * scene.zoom, height: scene.canvasHeight * scene.zoom)
                    .offset(x: scene.spriteOrigin.x * scene.zoom, y: scene.spriteOrigin.y * scene.zoom)
                }
                .frame(width: scene.width * scene.zoom, height: scene.height * scene.zoom, alignment: .topLeading)
            }
        }
        .frame(width: scene.width * scene.zoom, height: scene.height * scene.zoom, alignment: .topLeading)
        .onAppear { engine.update(behaviorContext) }
        .onChange(of: behaviorContext) { _, value in engine.update(value) }
        .onChange(of: player.effect?.id) { _, id in
            effectTask?.cancel()
            guard let id, let effect = player.effect,
                  let frames = assets.manifest?.effects[effect.name]?.frames else { return }
            effectTask = Task {
                do { try await Task.sleep(for: .seconds(Double(frames) * 0.1)) } catch { return }
                guard !Task.isCancelled else { return }
                player.finishEffect(id)
            }
        }
        .onChange(of: scene.width) { _, _ in model.onPetLayoutChange?() }
        .onChange(of: scene.height) { _, _ in model.onPetLayoutChange?() }
        .onDisappear {
            engine.stop()
            effectTask?.cancel()
            effectTask = nil
        }
        .preferredColorScheme(model.appearance.colorScheme)
    }
}

struct PetSceneMetrics {
    let zoom: CGFloat
    let canvasWidth: CGFloat
    let canvasHeight: CGFloat
    let width: CGFloat
    let height: CGFloat
    let spriteOrigin: CGPoint
    let bubbleOrigin: CGPoint
    let bubbleWidth: CGFloat
    let bubbleHeight: CGFloat
    let hudOrigin: CGPoint
    let effectAnchor: CGPoint

    init(manifest: AssetManifest?, anchors: AssetAnchors?, includesHUD: Bool, hudWindowCount: Int, bubbleSize: CGSize, zoom: CGFloat) {
        self.zoom = zoom
        canvasWidth = CGFloat(manifest?.canvas.outputWidth ?? 128)
        canvasHeight = CGFloat(manifest?.canvas.outputHeight ?? 128)
        let margin: CGFloat = 4
        let conversion = CGFloat(manifest?.canvas.scale ?? 2)
        bubbleWidth = bubbleSize.width
        bubbleHeight = bubbleSize.height
        let bubbleX = CGFloat(anchors?.bubble.first ?? 49) * conversion
        let bubbleY = CGFloat(anchors?.bubble.last ?? 7) * conversion
        bubbleOrigin = CGPoint(x: margin + bubbleX, y: margin + bubbleY)
        let hudWidth = CGFloat(manifest?.hud.size[0] ?? 52)
        let hudHeight = CGFloat(manifest?.hud.size[1] ?? 24)
        let feet = manifest?.canvas.feetAnchor ?? [32, 58]
        let hudAnchor = anchors?.hud ?? [feet[0], feet[1] + 3]
        let hudX = CGFloat(hudAnchor.first ?? feet[0]) * conversion
        let hudY = CGFloat(hudAnchor.last ?? feet[1] + 3) * conversion
            + CGFloat(manifest?.hud.layout.offsetY ?? 6)
            - hudHeight / 2
        hudOrigin = CGPoint(x: margin + hudX - hudWidth / 2, y: margin + hudY)
        let effectX = CGFloat(anchors?.effects.first ?? 49) * conversion
        let effectY = CGFloat(anchors?.effects.last ?? 13) * conversion
        effectAnchor = CGPoint(x: margin + effectX, y: margin + effectY)
        spriteOrigin = CGPoint(x: margin, y: margin)
        let effectWidth = CGFloat(manifest?.effects.values.map { $0.outputSize[0] }.max() ?? 48)
        let effectHeight = CGFloat(manifest?.effects.values.map { $0.outputSize[1] }.max() ?? 48)
        let right = max(max(canvasWidth, bubbleX + bubbleWidth), effectX + effectWidth / 2)
        let visibleHUDHeight = hudWindowCount == 1 ? hudHeight / 2 : hudHeight
        let bottom = max(max(canvasHeight, effectY + effectHeight / 2), includesHUD ? hudY + visibleHUDHeight : 0)
        width = right + margin * 2
        height = bottom + margin * 2
    }
}

private struct PixelHUDView: View {
    let snapshot: UsageSnapshot
    let manifest: AssetManifest?
    let assets: SpriteAtlasStore
    let scale: CGFloat

    private var windows: [UsageWindow] { snapshot.availableWindows }
    private var singleWindow: Bool { windows.count == 1 }
    private var topSlot: Bool { manifest?.hud.singleWindowUsesTopSlot ?? true }

    var body: some View {
        let source = singleWindow ? assets.singleBarImage(topSlot: topSlot) : assets.hudImage("bars")
        let size = manifest?.hud.size ?? [52, 24]
        let barHeight = CGFloat(size[1]) / (singleWindow ? 2 : 1)
        ZStack(alignment: .topLeading) {
            if let source {
                Image(nsImage: source)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: CGFloat(size[0]) * scale, height: barHeight * scale)
            }
            ForEach(windows) { window in
                let bar = singleWindow
                    ? manifest?.hud.barPositions[topSlot ? "5H" : "7D"]
                    : manifest?.hud.barPositions[window.label]
                if let bar, bar.count == 4 {
                    let remaining = min(100, max(0, window.remaining))
                    Rectangle()
                        .fill(color(for: remaining))
                        .frame(
                            width: CGFloat(max(0, bar[2] - 4)) * CGFloat(remaining / 100) * scale,
                            height: CGFloat(max(1, bar[3] - 4)) * scale
                        )
                        .offset(
                            x: CGFloat(bar[0] + 2) * scale,
                            y: CGFloat(bar[1] + 2) * scale
                        )
                }
            }
        }
        .frame(width: CGFloat(size[0]) * scale, height: barHeight * scale, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private func color(for remaining: Double) -> Color {
        if remaining <= 18 { return Color(red: 0.92, green: 0.31, blue: 0.31) }
        if remaining <= 40 { return Color(red: 0.94, green: 0.66, blue: 0.22) }
        return Color(red: 0.31, green: 0.77, blue: 0.47)
    }
}

private struct PixelCountView: View {
    let count: Int
    let scale: CGFloat
    let assets: SpriteAtlasStore

    private var text: String { count > 99 ? "99+" : String(count) }

    var body: some View {
        HStack(spacing: 2 * scale) {
            ForEach(Array(text.enumerated()), id: \.offset) { _, character in
                if let glyph = assets.countGlyph(for: character) {
                    Image(nsImage: glyph)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: glyph.size.width * scale, height: glyph.size.height * scale)
                }
            }
        }
        .fixedSize()
        .accessibilityHidden(true)
    }
}

private struct PetInteractionView: NSViewRepresentable {
    let onClick: () -> Void
    let onDoubleClick: () -> Void
    let onRepeatedClick: () -> Void
    let onHover: (Bool) -> Void
    let onDragStart: () -> Void
    let onDragEnd: () -> Void
    let onOpenDashboard: () -> Void
    let onOpenSettings: () -> Void
    let onHidePet: () -> Void

    func makeNSView(context: Context) -> PetInteractionNSView {
        let view = PetInteractionNSView()
        update(view)
        return view
    }

    func updateNSView(_ view: PetInteractionNSView, context: Context) { update(view) }

    private func update(_ view: PetInteractionNSView) {
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.onRepeatedClick = onRepeatedClick
        view.onHover = onHover
        view.onDragStart = onDragStart
        view.onDragEnd = onDragEnd
        view.onOpenDashboard = onOpenDashboard
        view.onOpenSettings = onOpenSettings
        view.onHidePet = onHidePet
    }
}

private final class PetInteractionNSView: NSView {
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onRepeatedClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var onDragStart: (() -> Void)?
    var onDragEnd: (() -> Void)?
    var onOpenDashboard: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onHidePet: (() -> Void)?
    private var dragStartMouse = CGPoint.zero
    private var dragStartWindow = CGPoint.zero
    private var dragged = false
    private var pendingClick: DispatchWorkItem?
    private var clickTimes: [Date] = []

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? super.hitTest(point) : nil
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount > 1 { pendingClick?.cancel(); pendingClick = nil }
        dragStartMouse = NSEvent.mouseLocation
        dragStartWindow = window?.frame.origin ?? .zero
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        let mouse = NSEvent.mouseLocation
        let delta = CGPoint(x: mouse.x - dragStartMouse.x, y: mouse.y - dragStartMouse.y)
        if !dragged && hypot(delta.x, delta.y) > 4 {
            dragged = true
            pendingClick?.cancel()
            pendingClick = nil
            clickTimes.removeAll()
            onDragStart?()
        }
        if dragged { window?.setFrameOrigin(CGPoint(x: dragStartWindow.x + delta.x, y: dragStartWindow.y + delta.y)) }
    }

    override func mouseUp(with event: NSEvent) {
        if dragged { dragged = false; onDragEnd?(); return }
        let now = Date.now
        clickTimes = clickTimes.filter { now.timeIntervalSince($0) <= 2 }
        clickTimes.append(now)
        if clickTimes.count >= 4 {
            pendingClick?.cancel(); pendingClick = nil; clickTimes.removeAll(); onRepeatedClick?()
        } else if event.clickCount > 1 {
            pendingClick?.cancel(); pendingClick = nil; onDoubleClick?()
        } else {
            pendingClick?.cancel()
            let click = DispatchWorkItem { [weak self] in self?.pendingClick = nil; self?.onClick?() }
            pendingClick = click
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: click)
        }
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func rightMouseDown(with event: NSEvent) {
        pendingClick?.cancel()
        pendingClick = nil
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide Pet", action: #selector(hidePet), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func openDashboard() { onOpenDashboard?() }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func hidePet() { onHidePet?() }
}
