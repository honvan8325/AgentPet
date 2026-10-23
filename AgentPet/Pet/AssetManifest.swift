import Foundation

struct AssetFrame: Decodable, Hashable {
    let atlas: String
    let rect: [Int]
    let durationMs: Int

    var durationSeconds: TimeInterval { Double(max(1, durationMs)) / 1_000 }
}

struct AssetVariant: Decodable {
    let frames: [AssetFrame]
}

struct AssetClip: Decodable {
    let kind: String
    let interruptPolicy: String
    let variants: [String: AssetVariant]
    let fallback: String?
    let from: String?
    let to: String?
}

struct AssetAtlas: Decodable {
    let id: String
    let file: String
    let width: Int
    let height: Int
}

enum PetEnergy: String, CaseIterable, Decodable, Hashable {
    case fresh, focused, tired, exhausted, empty

    static func select(remaining: Double?) -> PetEnergy? {
        guard let remaining, remaining.isFinite else { return nil }
        let value = min(100, max(0, remaining))
        if value == 0 { return .empty }
        if value >= 75 { return .fresh }
        if value >= 45 { return .focused }
        if value >= 20 { return .tired }
        return .exhausted
    }
}

enum PetMood: String, CaseIterable, Decodable, Hashable {
    case neutral, happy, curious, shy, sleepy, worried
}

struct AssetAnchors: Decodable {
    let feet: [Int]
    let bubble: [Int]
    let hud: [Int]
    let laptop: [Int]
    let effects: [Int]
}

struct PetBehaviorConfiguration: Decodable {
    struct IdleBehavior: Decodable {
        let clip: String
        let weight: Double
        let cooldownSeconds: Double
    }

    let idleBehaviors: [IdleBehavior]
    let avoidImmediateRepeat: Bool
    let sleepAfterSeconds: Double
    let interactions: [String: String]
}

struct AssetManifest: Decodable {
    struct Canvas: Decodable {
        let outputWidth: Int
        let outputHeight: Int
        let scale: Int
        let feetAnchor: [Int]
    }

    struct HUD: Decodable {
        struct Layout: Decodable {
            let offsetY: Int
        }

        let barsFile: String
        let bubbleFile: String
        let size: [Int]
        let barPositions: [String: [Int]]
        let layout: Layout
        let singleWindowUsesTopSlot: Bool
    }

    struct Effect: Decodable {
        let path: String
        let frames: Int
        let outputSize: [Int]
    }

    let schemaVersion: Int
    let themeId: String
    let canvas: Canvas
    let atlases: [AssetAtlas]
    let clips: [String: AssetClip]
    let roles: [String: String]
    let hud: HUD
    let effects: [String: Effect]

    func validate() throws {
        guard schemaVersion == 3, !themeId.isEmpty,
              canvas.outputWidth > 0, canvas.outputHeight > 0, canvas.scale > 0,
              let idle = roles["idle"], clips[idle] != nil,
              !atlases.isEmpty,
              Set(atlases.map(\.id)).count == atlases.count,
              atlases.allSatisfy({ !$0.id.isEmpty && !$0.file.isEmpty && $0.width > 0 && $0.height > 0 }) else {
            throw AssetManifestError.invalid("The V3 manifest is missing required theme, canvas, idle role, or atlas data.")
        }
    }

    func variantKey(energy: PetEnergy, mood: PetMood) -> String {
        "\(energy.rawValue).\(mood.rawValue)"
    }

    func transition(from: String, to: String) -> String? {
        clips.first { $0.value.from == from && $0.value.to == to }?.key
    }
}

enum AssetManifestError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        if case .invalid(let message) = self { return message }
        return nil
    }
}
