import AppKit
import Combine
import Foundation

struct AnimationPlayback: Equatable {
    let revision: UInt64
    let clipID: String
    let energy: PetEnergy
    let mood: PetMood
    let startedAt: Date
}

struct EffectPlayback: Equatable {
    let id: UUID
    let name: String
    let startedAt: Date
}

@MainActor
final class AnimationPlayer: ObservableObject {
    @Published private(set) var playback = AnimationPlayback(
        revision: 0,
        clipID: "idle.breathe",
        energy: .focused,
        mood: .neutral,
        startedAt: .now
    )
    @Published private(set) var effect: EffectPlayback?

    private var revision: UInt64 = 0

    func play(
        _ clipID: String,
        energy: PetEnergy,
        mood: PetMood,
        preservingTimeline: Bool = true
    ) {
        let samePlayback = playback.clipID == clipID && playback.energy == energy
            && playback.mood == mood
        if samePlayback && preservingTimeline { return }
        let start = preservingTimeline && playback.clipID == clipID
            ? playback.startedAt
            : Date.now
        revision &+= 1
        playback = AnimationPlayback(
            revision: revision,
            clipID: clipID,
            energy: energy,
            mood: mood,
            startedAt: start
        )
    }

    func frame(for clip: AssetClip, at date: Date) -> AssetFrame? {
        guard let frames = clip.variants["\(playback.energy.rawValue).\(playback.mood.rawValue)"]?.frames,
              !frames.isEmpty else { return nil }
        return frames[frameIndex(frames: frames, elapsed: date.timeIntervalSince(playback.startedAt), looping: clip.kind == "loop")]
    }

    func frameIndex(
        frames: [AssetFrame],
        elapsed: TimeInterval,
        looping: Bool
    ) -> Int {
        guard !frames.isEmpty else {
            return 0
        }

        let total = frames.reduce(0) {
            $0 + max(1, $1.durationMs)
        }

        guard total > 0 else {
            return 0
        }

        let milliseconds = max(
            0,
            Int(elapsed * 1_000)
        )

        let position = looping
            ? milliseconds % total
            : min(milliseconds, total - 1)

        var accumulated = 0

        for (index, frame) in frames.enumerated() {
            accumulated += max(1, frame.durationMs)

            if position < accumulated {
                return index
            }
        }

        return frames.count - 1
    }

    func playEffect(_ name: String) {
        effect = EffectPlayback(id: UUID(), name: name, startedAt: .now)
    }

    func finishEffect(_ id: UUID) {
        guard effect?.id == id else { return }
        effect = nil
    }
}
