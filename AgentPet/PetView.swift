import AppKit
import Combine
import SwiftUI

enum EnergyTier: String, CaseIterable, Hashable {
    case fresh, focused, tired, exhausted, empty

    static func choose(_ remaining: Double?, manifest: SpriteManifest?) -> EnergyTier? {
        guard let remaining, remaining.isFinite, let manifest else { return nil }
        let value = Int(min(100, max(0, remaining)).rounded(.down))
        return allCases.first { tier in
            guard let range = manifest.tiers[tier.rawValue]?.range, range.count == 2 else { return false }
            return range[0]...range[1] ~= value
        }
    }
}

struct SpriteManifest: Decodable {
    struct Size: Decodable { let width: Int; let height: Int }
    struct Tier: Decodable {
        let range: [Int]
        let file: String
        let width: Int
        let height: Int
        let animationSpeedMultiplier: Double
    }
    struct Animation: Decodable { let row: Int; let frames: Int; let fps: Double; let loop: Bool; let tiers: [String] }
    struct Transition: Decodable { let row: Int; let frames: Int; let fps: Double; let loop: Bool; let tiers: [String]; let from: String; let to: String }
    struct Bubble: Decodable { let file: String; let size: [Int]; let showOnlyWhenRunningCountAbove: Int; let numberPosition: [Int] }
    struct HUD: Decodable {
        let file: String
        let size: [Int]
        let positions: [String: [Int]]
        let fillInsets: [Int]
        let fillSize: [Int]
        let showLabels: Bool
        let showPercent: Bool
        let showOuterPanel: Bool
        let taskBubble: Bubble
        let pixelFont: String
        let pixelFontGlyphs: String
    }
    struct Logic: Decodable { let idleActivityAfterSeconds: Double; let idleActivityIntervalSeconds: [Double] }

    let frameSize: Size
    let columns: Int
    let framesPerAnimation: Int
    let tiers: [String: Tier]
    let states: [String: Animation]
    let transitions: [String: Transition]
    let hud: HUD
    let logic: Logic

    func clip(named name: String) -> SpriteClip? {
        if let animation = states[name] {
            return SpriteClip(row: animation.row, frames: animation.frames, fps: animation.fps, loop: animation.loop, tiers: animation.tiers, from: nil, to: nil)
        }
        if let transition = transitions[name] {
            return SpriteClip(row: transition.row, frames: transition.frames, fps: transition.fps, loop: transition.loop, tiers: transition.tiers, from: transition.from, to: transition.to)
        }
        return nil
    }
}

struct SpriteClip {
    let row: Int
    let frames: Int
    let fps: Double
    let loop: Bool
    let tiers: [String]
    let from: String?
    let to: String?
}

@MainActor
private final class SpriteAssets {
    static let shared = SpriteAssets()
    let manifest: SpriteManifest?
    private var atlasTier: EnergyTier?
    private var atlas: CGImage?
    private var cachedKey: String?
    private var cachedTier: EnergyTier?
    private var cachedFrames: [NSImage] = []
    private var hudImages: [String: NSImage] = [:]
    private var glyphs: [Character: NSImage] = [:]
    private var fills: [String: NSImage] = [:]

    private init() {
        guard let url = Bundle.main.url(forResource: "manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            manifest = nil
            return
        }
        manifest = try? JSONDecoder().decode(SpriteManifest.self, from: data)
        for name in ["bars", "fill_green", "fill_amber", "fill_red", "fill_empty", "digits", "task_bubble"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                hudImages[name] = image
            }
        }
        if let digits = hudImages["digits"]?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            for (index, character) in Array(manifest?.hud.pixelFontGlyphs ?? "0123456789").enumerated() {
                let rect = CGRect(x: index * 4, y: 0, width: 3, height: 5)
                if let glyph = digits.cropping(to: rect) {
                    glyphs[character] = NSImage(cgImage: glyph, size: NSSize(width: 3, height: 5))
                }
            }
        }
    }

    func clip(named key: String) -> SpriteClip? { manifest?.clip(named: key) }

    func effectiveFPS(for key: String, tier: EnergyTier?) -> Double {
        guard let manifest, let clip = manifest.clip(named: key) else { return 5 }
        let selectedTier = tier ?? .focused
        let multiplier = manifest.tiers[selectedTier.rawValue]?.animationSpeedMultiplier ?? 1
        return max(0.5, clip.fps * multiplier)
    }

    func duration(for key: String, tier: EnergyTier?) -> Double {
        guard let clip = clip(named: key) else { return 0 }
        return Double(clip.frames) / effectiveFPS(for: key, tier: tier)
    }

    func image(for key: String, tier: EnergyTier?, frame: Int) -> NSImage? {
        guard let manifest, let clip = manifest.clip(named: key) else { return nil }
        let selectedTier = tier ?? .focused
        guard clip.tiers.contains(selectedTier.rawValue) else { return nil }
        if atlasTier != selectedTier {
            guard let tierManifest = manifest.tiers[selectedTier.rawValue],
                  let filename = tierManifest.file.split(separator: "/").last.map(String.init),
                  let url = Bundle.main.url(forResource: (filename as NSString).deletingPathExtension, withExtension: "png"),
                  let source = NSImage(contentsOf: url),
                  let newAtlas = source.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  newAtlas.width == tierManifest.width,
                  newAtlas.height == tierManifest.height else { return nil }
            atlas = newAtlas
            atlasTier = selectedTier
            cachedTier = nil
            cachedKey = key
            cachedFrames.removeAll(keepingCapacity: true)
        }
        if cachedKey != key || cachedTier != selectedTier {
            guard let atlas else { return nil }
            cachedFrames = (0..<min(clip.frames, manifest.columns)).compactMap { index in
                let rect = CGRect(
                    x: index * manifest.frameSize.width,
                    y: clip.row * manifest.frameSize.height,
                    width: manifest.frameSize.width,
                    height: manifest.frameSize.height
                )
                guard let cgImage = atlas.cropping(to: rect) else { return nil }
                return NSImage(cgImage: cgImage, size: NSSize(width: manifest.frameSize.width, height: manifest.frameSize.height))
            }
            cachedTier = selectedTier
            cachedKey = key
        }
        guard atlasTier == selectedTier, !cachedFrames.isEmpty else { return nil }
        return cachedFrames[min(max(frame, 0), cachedFrames.count - 1)]
    }

    func hudImage(_ name: String) -> NSImage? { hudImages[name] }

    func bubbleImage() -> NSImage? {
        guard let file = manifest?.hud.taskBubble.file else { return hudImages["task_bubble"] }
        let name = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
        return hudImages[name]
    }

    func fillImage(_ name: String, width: Int) -> NSImage? {
        guard width > 0, let source = hudImages[name],
              let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let key = "\(name)-\(width)"
        if let cached = fills[key] { return cached }
        guard let cropped = cgImage.cropping(to: CGRect(x: 0, y: 0, width: min(width, cgImage.width), height: cgImage.height)) else { return nil }
        let image = NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
        fills[key] = image
        return image
    }

    func glyph(_ character: Character) -> NSImage? { glyphs[character] }
}

private struct SpritePlayback: Equatable {
    let id: UUID
    let key: String
    let tier: EnergyTier?
    let startDate: Date
    let holdSeconds: Double?
}

private struct PlaybackStep: ExpressibleByStringLiteral {
    let key: String
    let holdSeconds: Double?

    init(stringLiteral value: String) {
        key = value
        holdSeconds = nil
    }

    init(_ key: String, holdSeconds: Double? = nil) {
        self.key = key
        self.holdSeconds = holdSeconds
    }
}

private struct PetVisualContext: Equatable {
    let baseKey: String
    let tier: EnergyTier?
    let isTracking: Bool
    let runningCount: Int
    let needsInputCount: Int
    let isPaused: Bool
    let change: AppliedSessionChange?
}

@MainActor
private final class PetAnimationCoordinator: ObservableObject {
    @Published private(set) var playback = SpritePlayback(id: UUID(), key: "unknown", tier: nil, startDate: Date(), holdSeconds: nil)

    private let assets = SpriteAssets.shared
    private var context: PetVisualContext?
    private var sequence: [PlaybackStep] = []
    private var sequenceIndex = 0
    private var hovering = false
    private var dragging = false
    private var idleTask: Task<Void, Never>?
    private var activityTaskRunning = false
    private var lastIdleActivity: String?
    private var idleSince = Date()

    var isPaused: Bool { context?.isPaused == true }

    func update(_ next: PetVisualContext) {
        let previous = context
        context = next
        let eventChanged = previous?.change?.revision != next.change?.revision && next.change != nil
        if previous?.baseKey != next.baseKey || previous?.isTracking != next.isTracking {
            idleSince = Date()
        }

        if next.isPaused {
            cancelActivityTask()
            sequence.removeAll()
            sequenceIndex = 0
            dragging = false
            if playback.key != "paused" || playback.tier != next.tier {
                show("paused", tier: next.tier)
            }
            return
        }

        if previous?.isPaused == true {
            cancelActivityTask()
            if next.baseKey == "typing", assets.clip(named: "unpause")?.from == "paused" {
                playSequence(["unpause"], fallback: next.baseKey, startingAt: "paused")
            } else {
                show(next.baseKey, tier: next.tier)
            }
            scheduleIdleActivity()
            return
        }

        if dragging {
            if playback.tier != next.tier {
                show(playback.key, tier: next.tier, holdSeconds: playback.holdSeconds)
            }
            return
        }

        if eventChanged {
            cancelActivityTask()
            if !next.isPaused, let change = next.change {
                handle(change, from: previous?.baseKey)
            }
            scheduleIdleActivity()
            return
        }

        if playback.tier != next.tier {
            show(playback.key, tier: next.tier, holdSeconds: playback.holdSeconds)
        }

        guard let previous, previous.baseKey != next.baseKey else {
            scheduleIdleActivity()
            return
        }

        cancelActivityTask()
        if playback.key == "sleeping", next.baseKey != "idle" {
            var wakeSteps: [PlaybackStep] = ["wake"]
            if let transition = next.change?.transition { wakeSteps.append(PlaybackStep(transition)) }
            playSequence(wakeSteps, fallback: next.baseKey, startingAt: "sleeping")
        } else if previous.baseKey == "syncing", next.baseKey == "idle" {
            playSequence(["end_sync"], fallback: next.baseKey, startingAt: previous.baseKey)
        } else if previous.baseKey == "disconnected", next.baseKey == "reconnecting" {
            playSequence(["reconnect"], fallback: next.baseKey, startingAt: previous.baseKey)
        } else if previous.baseKey == "reconnecting", next.baseKey == "idle" {
            playSequence(["connected"], fallback: next.baseKey, startingAt: previous.baseKey)
        } else if previous.baseKey == "typing", next.baseKey == "disconnected" {
            playSequence(["disconnect"], fallback: next.baseKey, startingAt: previous.baseKey)
        } else if previous.baseKey == "idle", next.baseKey == "syncing" {
            playSequence(["begin_sync"], fallback: next.baseKey, startingAt: previous.baseKey)
        } else if previous.baseKey == "idle", next.baseKey == "low_quota" {
            playSequence(["quota_low"], fallback: next.baseKey, startingAt: previous.baseKey)
        } else if previous.baseKey == "low_quota", next.baseKey == "critical_quota" {
            playSequence(["quota_critical"], fallback: next.baseKey, startingAt: previous.baseKey)
        } else {
            show(next.baseKey, tier: next.tier)
        }
        scheduleIdleActivity()
    }

    func finishPlayback(_ id: UUID) {
        guard playback.id == id,
              let clip = assets.clip(named: playback.key),
              !clip.loop || playback.holdSeconds != nil else { return }
        if sequenceIndex + 1 < sequence.count {
            sequenceIndex += 1
            let next = sequence[sequenceIndex]
            if !hovering, next.key == "hovering" {
                playSequence(["hover_end"], fallback: context?.baseKey ?? "unknown", startingAt: "hovering")
            } else {
                show(next.key, tier: context?.tier, holdSeconds: next.holdSeconds)
            }
        } else {
            sequence.removeAll()
            sequenceIndex = 0
            if dragging && playback.key == "grabbed" {
                show("dragging", tier: context?.tier)
            } else {
                show(context?.baseKey ?? "unknown", tier: context?.tier)
                if !activityTaskRunning { scheduleIdleActivity() }
            }
        }
    }

    func click() {
        guard !dragging, !isPaused else { return }
        guard !isImportantPlayback else { return }
        cancelActivityTask()
        if context?.baseKey == "idle" {
            playSequence(["click", "click_end"], fallback: "idle", startingAt: "idle")
        } else {
            playSequence(["booped"], fallback: context?.baseKey ?? "unknown", startingAt: context?.baseKey)
        }
    }

    func doubleClick() {
        guard !dragging, !isPaused else { return }
        guard !isImportantPlayback else { return }
        cancelActivityTask()
        if context?.baseKey == "idle" {
            playSequence(["click", "double_click", "giggling"], fallback: "idle", startingAt: "idle")
        } else {
            playSequence(["giggling"], fallback: context?.baseKey ?? "unknown", startingAt: context?.baseKey)
        }
    }

    func repeatedClick() {
        guard !dragging, !isPaused else { return }
        guard !isImportantPlayback else { return }
        cancelActivityTask()
        if context?.baseKey == "idle" {
            playSequence(["click", "annoy", "annoyed"], fallback: "idle", startingAt: "idle")
        } else {
            playSequence(["annoyed"], fallback: context?.baseKey ?? "unknown", startingAt: context?.baseKey)
        }
    }

    func setHovering(_ value: Bool) {
        guard hovering != value, !dragging else { return }
        hovering = value
        if value {
            cancelActivityTask()
            guard !isImportantPlayback else { return }
            if context?.baseKey == "idle" {
                playSequence(["hover", "hovering"], fallback: "idle", startingAt: "idle")
            } else {
                show("hovering", tier: context?.tier)
            }
        } else {
            guard ["hover", "hovering", "hover_end"].contains(playback.key) else { return }
            if playback.key == "hovering", assets.clip(named: "hover_end")?.from == "hovering" {
                playSequence(["hover_end"], fallback: context?.baseKey ?? "unknown", startingAt: "hovering")
            } else if playback.key != "hover" {
                show(context?.baseKey ?? "unknown", tier: context?.tier)
                scheduleIdleActivity()
            }
        }
    }

    func beginDrag() {
        guard !dragging, !isPaused else { return }
        dragging = true
        cancelActivityTask()
        sequence.removeAll()
        if context?.baseKey == "idle" {
            playSequence(["pickup", "drag", "dragging"], fallback: "dragging", startingAt: "idle")
        } else {
            playSequence(["grabbed", "drag", "dragging"], fallback: "dragging", startingAt: context?.baseKey)
        }
    }

    func endDrag() {
        guard dragging else { return }
        let reachedDragging = playback.key == "dragging"
        dragging = false
        sequence.removeAll()
        if isPaused { return }
        let fallback = context?.baseKey ?? "unknown"
        if reachedDragging {
            var steps: [PlaybackStep] = ["drop", "landing"]
            if fallback == "idle" { steps.append("drop_end") }
            playSequence(steps, fallback: fallback, startingAt: "dragging")
        } else {
            playSequence(["landing"], fallback: fallback, startingAt: visualState)
        }
    }

    private func handle(_ change: AppliedSessionChange, from previousState: String?) {
        guard !dragging else { return }
        if playback.key == "sleeping", change.transition == "start_work" {
            playSequence(["wake", "start_work"], fallback: context?.baseKey ?? "typing", startingAt: "sleeping")
            return
        }
        guard let transition = change.transition,
              assets.clip(named: transition)?.from == previousState else {
            show(context?.baseKey ?? "unknown", tier: context?.tier)
            return
        }
        var steps: [PlaybackStep] = [PlaybackStep(transition)]
        if transition == "finish",
           context?.runningCount == 0,
           context?.needsInputCount == 0 {
            steps.append(PlaybackStep("ready", holdSeconds: 0.5))
        }
        playSequence(steps, fallback: context?.baseKey ?? "unknown", startingAt: previousState)
    }

    private var visualState: String {
        assets.clip(named: playback.key)?.from ?? playback.key
    }

    private func playSequence(_ steps: [PlaybackStep], fallback: String, startingAt initialState: String? = nil) {
        sequence.removeAll()
        var target = initialState ?? visualState
        let finiteLoopStates: Set<String> = [
            "booped", "giggling", "annoyed", "grabbed", "landing", "celebrating",
            "stretching", "yawning", "coffee_break", "looking_around", "tiny_dance", "cap_adjust", "walking"
        ]
        for (index, step) in steps.enumerated() {
            guard let clip = assets.clip(named: step.key) else { continue }
            if let from = clip.from, from != target { continue }
            let hold = step.holdSeconds
                ?? (clip.loop && (index < steps.count - 1 || finiteLoopStates.contains(step.key)) ? 0.9 : nil)
            let finiteStep = PlaybackStep(step.key, holdSeconds: hold)
            sequence.append(finiteStep)
            target = clip.to ?? step.key
        }
        sequenceIndex = 0
        guard !sequence.isEmpty else {
            sequence.removeAll()
            show(fallback, tier: context?.tier)
            return
        }
        show(sequence[0].key, tier: context?.tier, holdSeconds: sequence[0].holdSeconds)
    }

    private func show(_ key: String, tier: EnergyTier?, holdSeconds: Double? = nil) {
        guard assets.clip(named: key) != nil else { return }
        playback = SpritePlayback(id: UUID(), key: key, tier: tier, startDate: Date(), holdSeconds: holdSeconds)
    }

    private var isImportantPlayback: Bool {
        ["start_work", "request_input", "needs_input", "interrupt", "finish", "ready", "celebrate", "celebrating", "settle", "drop", "landing"]
            .contains(playback.key)
    }

    private func scheduleIdleActivity() {
        cancelActivityTask()
        guard let context,
              context.isTracking,
              !context.isPaused,
              sequence.isEmpty,
              !hovering,
              !dragging else { return }
        if context.baseKey == "typing", context.needsInputCount == 0 {
            activityTaskRunning = true
            idleTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(Double.random(in: 25...45)))
                    guard let self, !Task.isCancelled,
                          self.context?.baseKey == "typing",
                          (self.context?.runningCount ?? 0) > 0 else { return }
                    self.playSequence(["think", "resume_typing"], fallback: "typing")
                    let duration = ["think", "resume_typing"]
                        .map { self.assets.duration(for: $0, tier: self.context?.tier) }
                        .reduce(0, +)
                    try await Task.sleep(for: .seconds(duration))
                    guard !Task.isCancelled else { return }
                    self.activityTaskRunning = false
                    self.scheduleIdleActivity()
                } catch {}
            }
            return
        }
        guard context.baseKey == "idle",
              context.runningCount == 0,
              context.needsInputCount == 0 else { return }
        let initialDelay = assets.manifest?.logic.idleActivityAfterSeconds ?? 55
        activityTaskRunning = true
        idleTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(initialDelay))
                while !Task.isCancelled {
                    guard let self, self.context?.baseKey == "idle",
                          self.context?.isTracking == true else { return }
                    if Date().timeIntervalSince(self.idleSince) >= 300 {
                        self.playSequence(["sleep", "sleeping"], fallback: "idle")
                        self.activityTaskRunning = false
                        return
                    }
                    let activities: [(String, [String])] = [
                        ("stretching", ["stretch", "stretching", "stretch_finish"]),
                        ("yawning", ["yawn", "yawning"]),
                        ("coffee_break", ["caffeinate", "coffee_break"]),
                        ("looking_around", ["look", "looking_around"]),
                        ("tiny_dance", ["dance", "tiny_dance"]),
                        ("cap_adjust", ["adjust_cap", "cap_adjust"]),
                        ("walking", ["walking"])
                    ].filter { $0.0 != self.lastIdleActivity }
                    guard let activity = activities.randomElement() else { return }
                    self.lastIdleActivity = activity.0
                    let duration: Double
                    if activity.0 == "walking" {
                        let holdSeconds = Double.random(in: 1...2)
                        self.playSequence([PlaybackStep("walking", holdSeconds: holdSeconds)], fallback: "idle")
                        duration = holdSeconds
                    } else {
                        self.playSequence(activity.1.map { PlaybackStep($0) }, fallback: "idle")
                        duration = activity.1
                            .map { self.assets.duration(for: $0, tier: self.context?.tier) }
                            .reduce(0, +)
                    }
                    let interval = self.assets.manifest?.logic.idleActivityIntervalSeconds ?? [45, 125]
                    let wait = Double.random(in: interval[0]...interval[1])
                    try await Task.sleep(for: .seconds(duration + wait))
                }
            } catch {}
        }
    }

    private func cancelActivityTask() {
        idleTask?.cancel()
        idleTask = nil
        activityTaskRunning = false
    }
}

struct PetView: View {
    @ObservedObject var model: AgentPetModel
    @ObservedObject private var sessions: SessionStore
    @ObservedObject private var codex: CodexClient
    @ObservedObject private var hooks: HookIntegration
    @StateObject private var animator = PetAnimationCoordinator()

    init(model: AgentPetModel) {
        self.model = model
        _sessions = ObservedObject(wrappedValue: model.sessions)
        _codex = ObservedObject(wrappedValue: model.codex)
        _hooks = ObservedObject(wrappedValue: model.hooks)
    }

    private var energyTier: EnergyTier? {
        EnergyTier.choose(codex.usage?.fiveHour?.remaining, manifest: SpriteAssets.shared.manifest)
    }

    private var visualContext: PetVisualContext {
        PetVisualContext(
            baseKey: model.petState.animationKey,
            tier: energyTier,
            isTracking: hooks.state == .receivingEvents,
            runningCount: sessions.runningCount,
            needsInputCount: sessions.needsInputCount,
            isPaused: model.isPetPaused,
            change: sessions.lastChange
        )
    }

    private var pixelScale: CGFloat { CGFloat(model.petSize.pixelScale) }

    var body: some View {
        let runningCount = sessions.runningCount
        let taskBubble = SpriteAssets.shared.manifest?.hud.taskBubble
        let bubbleWidth = CGFloat(taskBubble?.size.first ?? 20)
        let bubbleHeight = CGFloat(taskBubble?.size.dropFirst().first ?? 19)
        let numberX = CGFloat(taskBubble?.numberPosition.first ?? 6)
        let numberY = CGFloat(taskBubble?.numberPosition.dropFirst().first ?? 5)
        VStack(spacing: 4 * pixelScale) {
            ZStack(alignment: .topTrailing) {
                SpriteFrameView(playback: animator.playback, isPaused: animator.isPaused)
                    .frame(width: 96 * pixelScale, height: 96 * pixelScale)
                if runningCount > (taskBubble?.showOnlyWhenRunningCountAbove ?? 0),
                   let bubble = SpriteAssets.shared.bubbleImage() {
                    Image(nsImage: bubble)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: bubbleWidth * pixelScale, height: bubbleHeight * pixelScale)
                        .overlay(alignment: .topLeading) {
                            PixelDigits(text: "\(min(runningCount, 99))", scale: pixelScale)
                                .offset(x: numberX * pixelScale, y: numberY * pixelScale)
                        }
                        .offset(x: 10 * pixelScale, y: -8 * pixelScale)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(runningCount) Codex tasks running")
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 96 * pixelScale, height: 96 * pixelScale)

            if model.showUsageHUD {
                PixelHUDView(snapshot: codex.usage, scale: pixelScale)
                    .frame(width: 36 * pixelScale, height: 14 * pixelScale)
                    .offset(y: -6 * pixelScale)
            }
        }
        .padding(.top, 8 * pixelScale)
        .padding(.bottom, 8 * pixelScale)
        .frame(width: 120 * pixelScale, height: (96 + 4 + (model.showUsageHUD ? 14 : 0) + 16) * pixelScale)
        .background(Color.clear)
        .overlay {
            PetInteractionView(
                onClick: animator.click,
                onDoubleClick: animator.doubleClick,
                onRepeatedClick: animator.repeatedClick,
                onHover: animator.setHovering,
                onDragStart: animator.beginDrag,
                onDragEnd: {
                    animator.endDrag()
                    model.onPetDragEnd?()
                },
                onOpenDashboard: model.openDashboard,
                onOpenSettings: model.openSettings,
                onHidePet: model.hidePet
            )
        }
        .animation(.easeOut(duration: 0.18), value: runningCount > 0)
        .preferredColorScheme(model.appearance.colorScheme)
        .onAppear { animator.update(visualContext) }
        .onChange(of: visualContext) { _, context in animator.update(context) }
        .task(id: animator.playback.id) {
            let playback = animator.playback
            guard let clip = SpriteAssets.shared.clip(named: playback.key) else { return }
            let duration: Double
            if let holdSeconds = playback.holdSeconds {
                duration = holdSeconds
            } else if !clip.loop {
                duration = SpriteAssets.shared.duration(for: playback.key, tier: playback.tier)
            } else {
                return
            }
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            animator.finishPlayback(playback.id)
        }
        .help("\(model.petState.animationKey) · click to boop · drag to move")
    }
}

private struct SpriteFrameView: View {
    let playback: SpritePlayback
    let isPaused: Bool

    var body: some View {
        let assets = SpriteAssets.shared
        let clip = assets.clip(named: playback.key)
        let fps = assets.effectiveFPS(for: playback.key, tier: playback.tier)
        TimelineView(
            .animation(minimumInterval: 1 / fps, paused: isPaused)
        ) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(playback.startDate))
            let count = max(1, clip?.frames ?? 1)
            let frameNumber = isPaused ? 0 : Int(elapsed * fps)
            let frame = clip?.loop == true
                ? frameNumber % count
                : min(frameNumber, count - 1)
            if let image = assets.image(for: playback.key, tier: playback.tier, frame: frame) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .accessibilityLabel(playback.key)
            } else {
                Color.clear
            }
        }
    }
}

private struct PixelHUDView: View {
    let snapshot: UsageSnapshot?
    let scale: CGFloat
    private let assets = SpriteAssets.shared

    var body: some View {
        let hud = assets.manifest?.hud
        let width = CGFloat(hud?.size.first ?? 36)
        let height = CGFloat(hud?.size.dropFirst().first ?? 14)
        ZStack(alignment: .topLeading) {
            if let image = assets.hudImage("bars") {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: width * scale, height: height * scale)
            }
            bar(
                window: snapshot?.fiveHour,
                position: hud?.positions["5H_bar"],
                inset: hud?.fillInsets ?? [1, 1],
                fillSize: hud?.fillSize ?? [30, 2]
            )
            bar(
                window: snapshot?.sevenDay,
                position: hud?.positions["7D_bar"],
                inset: hud?.fillInsets ?? [1, 1],
                fillSize: hud?.fillSize ?? [30, 2]
            )
        }
        .frame(width: width * scale, height: height * scale)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Codex usage: 5 hour \(value(snapshot?.fiveHour)), 7 day \(value(snapshot?.sevenDay))")
    }

    @ViewBuilder
    private func bar(
        window: UsageWindow?,
        position: [Int]?,
        inset: [Int],
        fillSize: [Int]
    ) -> some View {
        if let position,
           position.count == 4,
           inset.count == 2,
           fillSize.count == 2 {
            let barWidth = fillSize[0]
            let barHeight = fillSize[1]
            let x = CGFloat(position[0] + inset[0]) * scale
            let y = CGFloat(position[1] + inset[1]) * scale
            let remaining = window?.remaining
            let valid = remaining?.isFinite == true
            let percent = valid ? min(100, max(0, remaining ?? 0)) : 0
            let filled = valid ? Int((Double(barWidth) * percent / 100).rounded(.down)) : 0
            let fillName = !valid
                ? "fill_empty"
                : percent <= 18
                    ? "fill_red"
                    : percent <= 40
                        ? "fill_amber"
                        : "fill_green"

            if let background = assets.fillImage("fill_empty", width: barWidth) {
                Image(nsImage: background)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: CGFloat(barWidth) * scale, height: CGFloat(barHeight) * scale)
                    .offset(x: x, y: y)
            }

            if filled > 0, let foreground = assets.fillImage(fillName, width: filled) {
                Image(nsImage: foreground)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: CGFloat(filled) * scale, height: CGFloat(barHeight) * scale)
                    .offset(x: x, y: y)
            }
        }
    }

    private func value(_ window: UsageWindow?) -> String {
        guard let remaining = window?.remaining, remaining.isFinite else { return "unavailable" }
        return "\(Int(min(100, max(0, remaining)))) percent remaining"
    }
}

private struct PixelDigits: View {
    let text: String
    let scale: CGFloat
    private let assets = SpriteAssets.shared

    var body: some View {
        HStack(spacing: scale) {
            ForEach(Array(text.enumerated()), id: \.offset) { item in
                let character = item.element
                if let glyph = assets.glyph(character) {
                    Image(nsImage: glyph)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 3 * scale, height: 5 * scale)
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

    func updateNSView(_ nsView: PetInteractionNSView, context: Context) { update(nsView) }

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
        addTrackingArea(NSTrackingArea(
            rect: petHitRect,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        guard petHitRect.contains(localPoint) else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard petHitRect.contains(convert(event.locationInWindow, from: nil)) else { return }
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
        guard dragged else { return }
        window?.setFrameOrigin(CGPoint(x: dragStartWindow.x + delta.x, y: dragStartWindow.y + delta.y))
    }

    override func mouseUp(with event: NSEvent) {
        if dragged {
            dragged = false
            onDragEnd?()
            return
        }
        let now = Date()
        clickTimes = clickTimes.filter { now.timeIntervalSince($0) <= 2 }
        clickTimes.append(now)
        if clickTimes.count >= 4 {
            pendingClick?.cancel()
            pendingClick = nil
            clickTimes.removeAll()
            onRepeatedClick?()
        } else if event.clickCount > 1 {
            pendingClick?.cancel()
            pendingClick = nil
            onDoubleClick?()
        } else {
            pendingClick?.cancel()
            let click = DispatchWorkItem { [weak self] in
                self?.pendingClick = nil
                self?.onClick?()
            }
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

    private var petHitRect: CGRect {
        let scale = bounds.width / 120
        let hasHUD = bounds.height / max(scale, 1) > 120
        let bottomOffset = CGFloat(8 + (hasHUD ? 18 : 0)) * scale
        return CGRect(x: (bounds.width - 96 * scale) / 2, y: bottomOffset, width: 96 * scale, height: 96 * scale)
    }
}
