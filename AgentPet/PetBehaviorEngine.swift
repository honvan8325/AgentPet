import Combine
import Foundation

enum PetActivity: Equatable {
    case idle, working, thinking, waiting, sleeping
    case disconnected, reconnecting, syncing, paused, unknown
}

struct PetBehaviorContext: Equatable {
    let activity: PetActivity
    let energy: PetEnergy
    let mood: PetMood
    let runningCount: Int
    let needsInputCount: Int
    let isHovering: Bool
    let isDragging: Bool
    let isPaused: Bool
    let reduceMotion: Bool
    let themeID: String
}

@MainActor
final class PetBehaviorEngine: ObservableObject {
    let player: AnimationPlayer
    private let assets: SpriteAtlasStore
    private var context: PetBehaviorContext?
    private var configuration: PetBehaviorConfiguration?
    private var activityTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?
    private var queuedClips: [String] = []
    private var sequenceFallback = "idle.breathe"
    private var lastIdleClip: String?
    private var idleCooldowns: [String: Date] = [:]
    private var lastActivityAt = Date.now
    private var temporaryMood: PetMood?

    var frameInterval: TimeInterval {
        guard let clip = assets.manifest?.clips[player.playback.clipID] else { return 0.18 }
        return max(0.08, player.frameDelay(for: clip, at: .now))
    }

    init(player: AnimationPlayer, assets: SpriteAtlasStore = .shared) {
        self.player = player
        self.assets = assets
        loadBehavior()
    }

    func update(_ next: PetBehaviorContext) {
        let previous = context
        context = next
        if previous?.themeID != next.themeID {
            cancelTasks()
            loadBehavior()
            lastIdleClip = nil
            lastActivityAt = .now
            show(baseClip(for: next.activity), energy: next.energy, mood: next.mood, preservingTimeline: false)
            scheduleNextActivity()
            return
        }
        if previous?.activity != next.activity || previous?.isPaused != next.isPaused { lastActivityAt = .now }
        if let previous, previous.energy != next.energy {
            switch next.energy {
            case .tired: player.playEffect("sweat")
            case .exhausted, .empty: player.playEffect("warning")
            case .fresh, .focused: break
            }
        }

        let target = next.isPaused ? role("paused", fallback: "status.paused") : baseClip(for: next.activity)
        if [.waiting, .disconnected, .reconnecting, .paused].contains(next.activity) || next.isPaused {
            cancelActivity()
            if previous?.activity != next.activity || previous?.isPaused != next.isPaused {
                if let previous, let transition = assets.manifest?.transition(from: visualState, to: target) {
                    playSequence([transition, target], fallback: target)
                } else {
                    show(target, energy: next.energy, mood: next.mood)
                }
            } else if queuedClips.isEmpty {
                show(target, energy: next.energy, mood: next.mood)
            }
            if previous?.activity != next.activity || previous?.isPaused != next.isPaused {
                switch next.activity {
                case .waiting: player.playEffect("alert")
                case .reconnecting: player.playEffect("sync")
                case .disconnected: player.playEffect("warning")
                default: break
                }
            }
            return
        }
        if next.isDragging {
            cancelActivity()
            if player.playback.clipID != interaction("drag", fallback: "interact.drag_held")
                && player.playback.clipID != interaction("dragStart", fallback: "interact.drag_pickup") {
                let pickup = interaction("dragStart", fallback: "interact.drag_pickup")
                let transition = assets.manifest?.transition(from: visualState, to: pickup)
                playSequence([transition, pickup, interaction("drag", fallback: "interact.drag_held")].compactMap { $0 }, fallback: target)
            }
            return
        }
        if previous?.isDragging == true {
            let held = interaction("drag", fallback: "interact.drag_held")
            let landing = interaction("dragEnd", fallback: "interact.land")
            let drop = assets.manifest?.transition(from: held, to: landing)
            let settle = assets.manifest?.transition(from: landing, to: target)
            playSequence([interaction("dragDrop", fallback: "interact.drag_drop"), drop, landing, settle, target].compactMap { $0 }, fallback: target)
            scheduleNextActivity()
            return
        }
        let stateChanged = previous?.activity != next.activity || previous?.isPaused != next.isPaused
        if stateChanged {
            cancelActivity()
            if let previous, previous.activity == .working, next.activity == .idle,
               let manifest = assets.manifest {
                let working = baseClip(for: .working)
                let ended = role("turnEnded", fallback: "work.stopping")
                var sequence = [String]()
                if let transition = manifest.transition(from: visualState, to: working) { sequence.append(transition) }
                if let transition = manifest.transition(from: working, to: ended) { sequence.append(transition) }
                sequence.append(ended)
                if let transition = manifest.transition(from: ended, to: target) { sequence.append(transition) }
                sequence.append(target)
                playSequence(sequence, fallback: target)
            } else if let previous, previous.activity == .reconnecting, next.activity == .idle,
                      let manifest = assets.manifest {
                let connected = role("connected", fallback: "status.connected")
                let first = manifest.transition(from: visualState, to: connected)
                let second = manifest.transition(from: connected, to: target)
                playSequence([first, connected, second, target].compactMap { $0 }, fallback: target)
            } else if let transition = assets.manifest?.transition(from: visualState, to: target) {
                playSequence([transition, target], fallback: target)
            } else {
                show(target, energy: next.energy, mood: next.mood)
            }
            switch next.activity {
            case .waiting: player.playEffect("alert")
            case .reconnecting, .syncing: player.playEffect("sync")
            case .disconnected: player.playEffect("warning")
            case .sleeping: player.playEffect("zzz")
            default: break
            }
            scheduleNextActivity()
            return
        }

        if next.isHovering {
            guard next.activity == .idle else {
                if previous?.isHovering != true { player.playEffect("heart") }
                return
            }
            if !player.playback.clipID.hasPrefix("interact.hover") { playHoverNotice() }
            return
        }

        if previous?.isHovering == true {
            let peek = "interact.hover_peek"
            let transition = assets.manifest?.transition(from: peek, to: target)
            playSequence([peek, transition, target].compactMap { $0 }, fallback: target)
        } else if player.playback.clipID.hasPrefix("interact.hover") {
            show(target, energy: next.energy, mood: next.mood)
        } else if queuedClips.isEmpty {
            show(target, energy: next.energy, mood: temporaryMood ?? next.mood)
        }
        scheduleNextActivity()
    }

    func click() { performInteraction(clips: [interaction("click", fallback: "interact.boop"), "emotion.shy"], mood: .shy, effect: "heart") }
    func doubleClick() { performInteraction(clips: ["interact.double_tap", "interact.giggle"], mood: .happy, effect: "sparkle") }
    func repeatedClick() { performInteraction(clips: ["interact.pout", "emotion.frustrated"], mood: .worried, effect: "sweat") }
    func stop() { cancelTasks() }

    private func performInteraction(clips: [String], mood: PetMood, effect: String) {
        guard let context, !context.isPaused, !context.isDragging,
              ![.waiting, .disconnected, .reconnecting].contains(context.activity) else { return }
        if context.activity != .idle {
            player.playEffect(effect)
            return
        }
        cancelActivity()
        temporaryMood = mood
        player.playEffect(effect)
        let transition = clips.first.flatMap { assets.manifest?.transition(from: visualState, to: $0) }
        playSequence([transition].compactMap { $0 } + clips, fallback: baseClip(for: context.activity))
    }

    private func baseClip(for activity: PetActivity) -> String {
        switch activity {
        case .idle: role("idle", fallback: "idle.breathe")
        case .working: role("working", fallback: "work.typing")
        case .thinking: role("thinking", fallback: "work.thinking")
        case .waiting: role("needsInput", fallback: "status.permission_notice")
        case .sleeping: "idle.sleep"
        case .disconnected: role("disconnected", fallback: "status.disconnected")
        case .reconnecting: role("reconnecting", fallback: "status.reconnecting")
        case .syncing: assets.manifest?.clips["work.syncing"] == nil ? role("connected", fallback: "status.connected") : "work.syncing"
        case .paused: role("paused", fallback: "status.paused")
        case .unknown: role("unknown", fallback: "status.unknown")
        }
    }

    private func role(_ name: String, fallback: String) -> String { assets.manifest?.roles[name] ?? fallback }
    private func interaction(_ name: String, fallback: String) -> String { configuration?.interactions[name] ?? fallback }

    private var visualState: String {
        assets.manifest?.clips[player.playback.clipID]?.to ?? player.playback.clipID
    }

    private func show(_ requested: String, energy: PetEnergy, mood: PetMood, preservingTimeline: Bool = true) {
        guard let manifest = assets.manifest else { return }
        let key = manifest.variantKey(energy: energy, mood: mood)
        let resolved: String
        if manifest.clips[requested]?.variants[key] != nil {
            resolved = requested
        } else {
            let candidates = [manifest.clips[requested]?.fallback, "idle.breathe"].compactMap { $0 }
            guard let fallback = candidates.first(where: { manifest.clips[$0]?.variants[key] != nil }) else {
                assets.recordDiagnostic("Clip \(requested) has no \(key) variant and no valid idle fallback.")
                return
            }
            resolved = fallback
            assets.recordDiagnostic("Clip \(requested) has no \(key) variant; used \(resolved).")
        }
        guard let resolvedClip = manifest.clips[resolved], resolvedClip.variants[key] != nil else { return }
        let previousRevision = player.playback.revision
        player.play(
            resolved,
            energy: energy,
            mood: mood,
            interruptPolicy: resolvedClip.interruptPolicy,
            preservingTimeline: preservingTimeline
        )
        if player.playback.revision == previousRevision, playbackTask != nil { return }
        playbackTask?.cancel()
        playbackTask = nil
        guard resolvedClip.kind == "once", let frames = resolvedClip.variants[key]?.frames else { return }
        let duration = max(0.01, frames.reduce(0) { $0 + $1.durationSeconds } - Date.now.timeIntervalSince(player.playback.startedAt))
        let revision = player.playback.revision
        playbackTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            guard !Task.isCancelled, self?.player.playback.revision == revision else { return }
            self?.finishPlayback()
        }
    }

    private func playSequence(_ clips: [String], fallback: String) {
        cancelPlayback()
        queuedClips = clips
        sequenceFallback = fallback
        playNext()
    }

    private func playHoverNotice() {
        guard let context else { return }
        let base = baseClip(for: context.activity)
        let hover = interaction("hover", fallback: "interact.hover_notice")
        let transition = assets.manifest?.transition(from: visualState, to: hover)
        playSequence([transition, hover].compactMap { $0 }, fallback: base)
        player.playEffect("heart")
    }

    private func playNext() {
        guard let context else { return }
        while !queuedClips.isEmpty {
            let next = queuedClips.removeFirst()
            guard let clip = assets.manifest?.clips[next] else { continue }
            if queuedClips.isEmpty, clip.kind == "loop", next == sequenceFallback {
                temporaryMood = nil
            }
            show(next, energy: context.energy, mood: temporaryMood ?? context.mood, preservingTimeline: false)
            if clip.kind == "loop" {
                if queuedClips.isEmpty {
                    let holdsState = context.isDragging || context.isHovering
                        || [.waiting, .disconnected, .reconnecting, .paused].contains(context.activity)
                        || next == sequenceFallback || next == "idle.sleep"
                    if holdsState {
                        scheduleNextActivity()
                    } else {
                        let revision = player.playback.revision
                        playbackTask = Task { [weak self] in
                            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
                            guard !Task.isCancelled, self?.player.playback.revision == revision else { return }
                            self?.finishPlayback()
                        }
                    }
                } else {
                    let revision = player.playback.revision
                    playbackTask = Task { [weak self] in
                        do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
                        guard !Task.isCancelled, self?.player.playback.revision == revision else { return }
                        self?.finishPlayback()
                    }
                }
            }
            return
        }
        temporaryMood = nil
        show(sequenceFallback, energy: context.energy, mood: context.mood)
        scheduleNextActivity()
    }

    private func finishPlayback() {
        playbackTask = nil
        if context?.isHovering == true, context?.activity == .idle, queuedClips.isEmpty {
            playHoverNotice()
            return
        }
        if queuedClips.isEmpty {
            temporaryMood = nil
            show(sequenceFallback, energy: context?.energy ?? .focused, mood: context?.mood ?? .neutral)
            scheduleNextActivity()
        } else {
            playNext()
        }
    }

    private func scheduleNextActivity() {
        cancelActivity()
        guard let context, !context.isPaused, !context.isDragging, !context.isHovering,
              queuedClips.isEmpty, [.idle, .working].contains(context.activity) else { return }
        let delay = context.activity == .working
            ? Double.random(in: (context.reduceMotion ? 35...55 : 18...32))
            : Double.random(in: (context.reduceMotion ? 35...55 : 13...24))
        activityTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, !Task.isCancelled, let current = self.context else { return }
            if current.activity == .working {
                self.playThinking()
            } else if let configuration = self.configuration,
                      Date.now.timeIntervalSince(self.lastActivityAt) >= configuration.sleepAfterSeconds,
                      !current.reduceMotion {
                self.playSequence(["idle.sleep"], fallback: self.baseClip(for: current.activity))
                self.player.playEffect("zzz")
            } else if !current.reduceMotion {
                self.playIdleBehavior()
            }
        }
    }

    private func playThinking() {
        guard let context, context.activity == .working else { return }
        let work = role("working", fallback: "work.typing")
        let thinking = role("thinking", fallback: "work.thinking")
        var sequence = [String]()
        if let transition = assets.manifest?.transition(from: work, to: thinking) { sequence.append(transition) }
        sequence.append(thinking)
        if let transition = assets.manifest?.transition(from: thinking, to: work) { sequence.append(transition) }
        sequence.append(work)
        temporaryMood = .curious
        playSequence(sequence, fallback: work)
        player.playEffect("question")
    }

    private func playIdleBehavior() {
        guard let context, context.activity == .idle, let configuration else { return }
        let now = Date.now
        let choices = configuration.idleBehaviors.filter {
            (idleCooldowns[$0.clip] ?? .distantPast) <= now
                && (!configuration.avoidImmediateRepeat || $0.clip != lastIdleClip)
                && assets.manifest?.clips[$0.clip] != nil
        }
        guard let selected = weightedChoice(choices, weight: \.weight) else { return }
        lastIdleClip = selected.clip
        idleCooldowns[selected.clip] = now.addingTimeInterval(selected.cooldownSeconds)
        playSequence([selected.clip], fallback: role("idle", fallback: "idle.breathe"))
        if selected.clip == "idle.sleep" || selected.clip == "idle.doze" { player.playEffect("zzz") }
    }

    private func weightedChoice<Value>(_ values: [Value], weight: KeyPath<Value, Double>) -> Value? {
        let total = values.reduce(0) { $0 + max(0, $1[keyPath: weight]) }
        guard total > 0 else { return nil }
        var choice = Double.random(in: 0..<total)
        for value in values {
            choice -= max(0, value[keyPath: weight])
            if choice < 0 { return value }
        }
        return values.last
    }

    private func loadBehavior() {
        guard let theme = assets.activeTheme,
              let url = Bundle.main.url(forResource: "behavior", withExtension: "json", subdirectory: theme.resourceDirectory),
              let data = try? Data(contentsOf: url) else {
            configuration = nil
            return
        }
        configuration = try? JSONDecoder().decode(PetBehaviorConfiguration.self, from: data)
    }

    private func cancelActivity() {
        activityTask?.cancel()
        activityTask = nil
    }

    private func cancelPlayback() {
        playbackTask?.cancel()
        playbackTask = nil
        queuedClips.removeAll()
    }

    private func cancelTasks() {
        cancelActivity()
        cancelPlayback()
        temporaryMood = nil
    }
}
