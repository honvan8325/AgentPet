import AppKit
import Combine
import SwiftUI

struct PetView: View {
    @ObservedObject var model: AgentPetModel
    @ObservedObject private var sessions: SessionStore
    @ObservedObject private var codex: CodexClient
    @ObservedObject private var chatGPTWeb: ChatGPTWebConnector
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
        _chatGPTWeb = ObservedObject(wrappedValue: model.chatGPTWeb)
        _assets = ObservedObject(wrappedValue: .shared)
        _player = ObservedObject(wrappedValue: model.animationPlayer)
        engine = model.behaviorEngine
    }

    private var behaviorContext: PetBehaviorContext {
        var activity: PetActivity
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
        let mayShowWebThinking = !model.isPetPaused && !isDragging &&
            sessions.runningCount == 0 && sessions.needsInputCount == 0 &&
            chatGPTWeb.generatingCount > 0 &&
            (activity == .idle || activity == .unknown || activity == .disconnected)
        if mayShowWebThinking { activity = .webThinking }
        let mood: PetMood
        switch activity {
        case .webThinking: mood = .curious
        case .waiting, .disconnected, .reconnecting, .unknown: mood = .worried
        default: mood = isHovering ? .curious : (sessions.runningCount > 0 ? .happy : .neutral)
        }
        return PetBehaviorContext(
            activity: activity,
            energy: PetEnergy.select(remaining: codex.usage?.energyWindow?.remaining) ?? .focused,
            hasQuotaData: codex.usage?.energyWindow != nil,
            mood: mood,
            runningCount: sessions.runningCount,
            isHovering: isHovering,
            isDragging: isDragging,
            isPaused: model.isPetPaused,
            reduceMotion: model.reduceMotion,
            themeID: model.selectedTheme.id,
            eventRevision: sessions.lastChange?.revision ?? 0,
            lifecycleEvent: sessions.lastChange?.event,
            lifecycleTransition: sessions.lastChange?.transition,
            chatGPTCompletionRevision: model.chatGPTCompletionRevision
        )
    }

    private var metrics: PetSceneMetrics {
        PetSceneMetrics(
            manifest: assets.manifest,
            anchors: assets.anchors,
            includesHUD: hasVisibleHUD,
            hudWindowCount: codex.usage?.availableWindows.count ?? 0,
            bubbleSize: assets.bubblePixelSize,
            chatGPTEnabled: chatGPTWeb.isEnabled,
            zoom: CGFloat(model.petScale)
        )
    }

    private var hasVisibleHUD: Bool {
        model.showUsageHUD && !(codex.usage?.availableWindows.isEmpty ?? true)
    }

    var body: some View {
        let scene = metrics

        let codexChats = sessions.sessions.values
            .filter { $0.status == .running }
            .sorted {
                if $0.updatedAt == $1.updatedAt {
                    return $0.sessionID < $1.sessionID
                }
                return $0.updatedAt > $1.updatedAt
            }
            .map { session in
                guard let title = session.title,
                      !title.isEmpty else {
                    return "Untitled chat"
                }
                return title
            }

        let webChats = chatGPTWeb.generatingTabs.map { tab in
            guard let title = tab.title,
                  !title.isEmpty else {
                return "Untitled chat"
            }
            return title
        }

        ZStack(alignment: .topLeading) {
            TimelineView(
                .animation(
                    minimumInterval: 1.0 / 15.0,
                    paused: player.effect == nil &&
                        (
                            model.isPetPaused ||
                            (
                                model.reduceMotion &&
                                player.playback.clipID.hasPrefix("idle.")
                            )
                        )
                )
            ) { timeline in
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

                }
                .frame(width: scene.width * scene.zoom, height: scene.height * scene.zoom, alignment: .topLeading)
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
            .frame(width: scene.canvasWidth * 0.82 * scene.zoom, height: scene.canvasHeight * scene.zoom)
            .offset(
                x: (scene.spriteOrigin.x + scene.canvasWidth * 0.09) * scene.zoom,
                y: scene.spriteOrigin.y * scene.zoom
            )

            if model.showUsageHUD,
               let snapshot = codex.usage,
               !snapshot.availableWindows.isEmpty {
                PixelHUDView(
                    snapshot: snapshot,
                    manifest: assets.manifest,
                    assets: assets,
                    scale: scene.zoom
                )
                .offset(x: scene.hudOrigin.x * scene.zoom, y: scene.hudOrigin.y * scene.zoom)
            }

            if let bubble = assets.hudImage("bubble") {
                if !codexChats.isEmpty {
                    Button {
                        model.openDashboard()
                    } label: {
                        ConnectorBubbleView(
                            count: codexChats.count,
                            bubble: bubble,
                            zoom: scene.zoom,
                            assets: assets,
                            chatNames: codexChats
                        )
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .zIndex(1)
                    .offset(
                        x: scene.bubbleOrigin.x * scene.zoom,
                        y: scene.bubbleOrigin.y * scene.zoom
                    )
                    .transition(
                        .opacity.combined(
                            with: .scale(scale: 0.9)
                        )
                    )
                    .animation(
                        model.reduceMotion
                            ? nil
                            : .easeOut(duration: 0.15),
                        value: !codexChats.isEmpty
                    )
                    .accessibilityLabel(
                        "Codex: \(codexChats.count) running"
                    )
                    .accessibilityHint(codexChats.joined(separator: "\n"))
                }
                if !webChats.isEmpty {
                    let origin = !codexChats.isEmpty
                        ? scene.chatGPTBubbleOrigin
                        : scene.bubbleOrigin

                    Button {
                        chatGPTWeb.openActiveChatGPT()
                    } label: {
                        ConnectorBubbleView(
                            count: webChats.count,
                            bubble: bubble,
                            zoom: scene.zoom,
                            assets: assets,
                            chatNames: webChats
                        )
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .zIndex(1)
                    .offset(
                        x: origin.x * scene.zoom,
                        y: origin.y * scene.zoom
                    )
                    .transition(
                        .opacity.combined(
                            with: .scale(scale: 0.9)
                        )
                    )
                    .animation(
                        model.reduceMotion
                            ? nil
                            : .easeOut(duration: 0.15),
                        value: !webChats.isEmpty
                    )
                    .accessibilityLabel(
                        "ChatGPT Web: \(webChats.count) generating"
                    )
                    .accessibilityHint(webChats.joined(separator: "\n"))
                }
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
    let chatGPTBubbleOrigin: CGPoint
    let bubbleWidth: CGFloat
    let bubbleHeight: CGFloat
    let hudOrigin: CGPoint
    let effectAnchor: CGPoint

    init(manifest: AssetManifest?, anchors: AssetAnchors?, includesHUD: Bool, hudWindowCount: Int, bubbleSize: CGSize, chatGPTEnabled: Bool, zoom: CGFloat) {
        self.zoom = zoom
        canvasWidth = CGFloat(manifest?.canvas.outputWidth ?? 128)
        canvasHeight = CGFloat(manifest?.canvas.outputHeight ?? 128)
        let margin: CGFloat = 4
        let conversion = CGFloat(manifest?.canvas.scale ?? 2)
        let bubbleGap = 2 * conversion
        bubbleWidth = bubbleSize.width
        bubbleHeight = bubbleSize.height
        let bubbleY = CGFloat(anchors?.bubble.last ?? 7) * conversion
        let bubbleAnchorX = CGFloat(anchors?.bubble.first ?? 48) * conversion
        let bubbleSlots: CGFloat = chatGPTEnabled ? 2 : 1
        let nearestBubbleOffsetX = canvasWidth - bubbleAnchorX - bubbleWidth
        let leftmostBubbleOffsetX = nearestBubbleOffsetX - (bubbleSlots - 1) * (bubbleWidth + bubbleGap)
        spriteOrigin = CGPoint(x: margin + max(0, -leftmostBubbleOffsetX), y: margin)
        bubbleOrigin = CGPoint(x: spriteOrigin.x + nearestBubbleOffsetX,
                               y: spriteOrigin.y + bubbleY)
        let diagonalX = (bubbleWidth * 0.85 * zoom).rounded() / zoom
        let diagonalY = (bubbleHeight * 0.80 * zoom).rounded() / zoom
        chatGPTBubbleOrigin = CGPoint(x: bubbleOrigin.x - diagonalX,
                                      y: bubbleOrigin.y + diagonalY)
        let hudWidth = CGFloat(manifest?.hud.size[0] ?? 52)
        let hudHeight = CGFloat(manifest?.hud.size[1] ?? 24)
        let feet = manifest?.canvas.feetAnchor ?? [32, 58]
        let hudAnchor = anchors?.hud ?? [feet[0], feet[1] + 3]
        let hudX = CGFloat(hudAnchor.first ?? feet[0]) * conversion
        let hudY = CGFloat(hudAnchor.last ?? feet[1] + 3) * conversion
            + CGFloat(manifest?.hud.layout.offsetY ?? 6)
            - hudHeight / 2
        hudOrigin = CGPoint(x: spriteOrigin.x + hudX - hudWidth / 2, y: spriteOrigin.y + hudY)
        let hoverReadoutRight: CGFloat = includesHUD ? hudOrigin.x + hudWidth + 48 : 0
        let effectX = CGFloat(anchors?.effects.first ?? 49) * conversion
        let effectY = CGFloat(anchors?.effects.last ?? 13) * conversion
        effectAnchor = CGPoint(x: spriteOrigin.x + effectX, y: spriteOrigin.y + effectY)
        let effectWidth = CGFloat(manifest?.effects.values.map { $0.outputSize[0] }.max() ?? 48)
        let effectHeight = CGFloat(manifest?.effects.values.map { $0.outputSize[1] }.max() ?? 48)
        let right = max(max(spriteOrigin.x + canvasWidth, effectAnchor.x + effectWidth / 2), hoverReadoutRight)
        let visibleHUDHeight = hudWindowCount == 1 ? hudHeight / 2 : hudHeight
        let hudBottom = hudOrigin.y - margin + visibleHUDHeight
        let bottom = max(max(canvasHeight, effectY + effectHeight / 2), includesHUD ? hudBottom : 0)
        width = right + margin
        height = bottom + margin * 2
    }
}

private struct PixelHUDView: View {
    let snapshot: UsageSnapshot
    let manifest: AssetManifest?
    let assets: SpriteAtlasStore
    let scale: CGFloat
    @State private var hoveredWindowID: Int?

    private var windows: [UsageWindow] { snapshot.availableWindows }
    private var singleWindow: Bool { windows.count == 1 }
    private var topSlot: Bool { manifest?.hud.singleWindowUsesTopSlot ?? true }

    var body: some View {
        let source = singleWindow ? assets.singleBarImage(topSlot: topSlot) : assets.hudImage("bars")
        let size = manifest?.hud.size ?? [52, 24]
        let barHeight = CGFloat(size[1]) / (singleWindow ? 2 : 1)
        let cropOffsetY = singleWindow && !topSlot ? size[1] / 2 : 0
        ZStack(alignment: .topLeading) {
            if let source {
                Image(nsImage: source)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: CGFloat(size[0]) * scale, height: barHeight * scale)
                    .allowsHitTesting(false)
            }
            ForEach(windows) { window in
                let bar = singleWindow
                    ? manifest?.hud.barPositions[topSlot ? "5H" : "7D"]
                    : manifest?.hud.barPositions[window.label]
                if let bar, bar.count == 4 {
                    let remaining = min(100, max(0, window.remaining))
                    let barX = CGFloat(bar[0])
                    let barY = CGFloat(bar[1] - cropOffsetY)
                    let barWidth = CGFloat(bar[2])
                    let barHeight = CGFloat(bar[3])
                    let inset: CGFloat = 2
                    let innerWidth = max(0, CGFloat(bar[2]) - inset * 2)
                    let innerHeight = max(0, CGFloat(bar[3]) - inset * 2)
                    Rectangle()
                        .fill(color(for: remaining))
                        .frame(
                            width: innerWidth * CGFloat(remaining / 100) * scale,
                            height: innerHeight * scale
                        )
                        .offset(
                            x: (CGFloat(bar[0]) + inset) * scale,
                            y: (CGFloat(bar[1] - cropOffsetY) + inset) * scale
                        )
                        .allowsHitTesting(false)

                    Color.clear
                        .frame(width: barWidth * scale, height: (barHeight + 2) * scale)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside {
                                hoveredWindowID = window.id
                            } else if hoveredWindowID == window.id {
                                hoveredWindowID = nil
                            }
                        }
                        .offset(x: barX * scale, y: max(0, barY - 1) * scale)

                    if hoveredWindowID == window.id {
                        let percentage = Int(remaining.rounded(.down))
                        let labelX = ((barX + barWidth + 2) * scale).rounded()
                        let labelY = (barY * scale).rounded()

                        Text("\(percentage)%")
                            .font(.system(size: 5.5 * scale, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: true)
                            .shadow(color: .black.opacity(0.9), radius: 0.8 * scale)
                            .frame(width: 30 * scale, height: barHeight * scale, alignment: .leading)
                            .offset(x: labelX, y: labelY)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .frame(width: CGFloat(size[0]) * scale, height: barHeight * scale, alignment: .topLeading)
        .accessibilityHidden(true)
        .onChange(of: windows.map(\.id)) { _, ids in
            if let hoveredWindowID, !ids.contains(hoveredWindowID) {
                self.hoveredWindowID = nil
            }
        }
    }

    private func color(for remaining: Double) -> Color {
        if remaining <= 18 { return Color(red: 0.92, green: 0.31, blue: 0.31) }
        if remaining <= 40 { return Color(red: 0.94, green: 0.66, blue: 0.22) }
        return Color(red: 0.31, green: 0.77, blue: 0.47)
    }
}

private struct ConnectorBubbleView: View {
    let count: Int
    let bubble: NSImage
    let zoom: CGFloat
    let assets: SpriteAtlasStore
    let chatNames: [String]

    var body: some View {
        let width = bubble.size.width * zoom
        let height = bubble.size.height * zoom
        ZStack(alignment: .center) {
            Image(nsImage: bubble)
                .resizable()
                .interpolation(.none)
                .frame(width: width, height: height)
                .scaleEffect(x: -1, y: 1)
            PixelCountView(
                count: count,
                scale: zoom,
                assets: assets
            )
            .offset(y: -bubble.size.height * zoom * 0.13)
            .allowsHitTesting(false)
        }
        .frame(width: width, height: height, alignment: .center)
        .overlay {
            NativeTooltipHost(text: chatNames.joined(separator: "\n"))
                .frame(width: width, height: height)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct NativeTooltipHost: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.toolTip = text
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        view.toolTip = text
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
