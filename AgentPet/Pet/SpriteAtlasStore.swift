import AppKit
import Combine
import Dispatch
import Foundation
import ImageIO

@MainActor
final class SpriteAtlasStore: ObservableObject {
    static let shared = SpriteAtlasStore()

    @Published private(set) var manifest: AssetManifest?
    @Published private(set) var activeTheme: PetTheme?
    @Published private(set) var anchors: AssetAnchors?
    @Published private(set) var diagnosticMessage: String?

    private var themeURL: URL?
    private var atlasesByID: [String: AssetAtlas] = [:]
    private var atlasImages: [String: CGImage] = [:]
    private var leastRecentlyUsed: [String] = []
    private var lastFrameKey: String?
    private var lastFrameImage: NSImage?
    private var singleBarImageCache: [Bool: NSImage] = [:]
    private var countGlyphs: [Character: NSImage] = [:]
    private var accessoryImages: [String: NSImage] = [:]
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    private init() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.purgeAtlasCache() }
        }
        source.resume()
        memoryPressureSource = source
    }

    @discardableResult
    func selectTheme(_ theme: PetTheme) -> Bool {
        if activeTheme == theme, manifest != nil { return true }
        guard let root = Bundle.main.resourceURL?.appendingPathComponent(theme.resourceDirectory, isDirectory: true),
              let data = try? Data(contentsOf: root.appendingPathComponent("manifest.json")),
              let loaded = try? JSONDecoder().decode(AssetManifest.self, from: data),
              loaded.themeId == theme.id,
              (try? loaded.validate()) != nil,
              let anchorData = try? Data(contentsOf: root.appendingPathComponent("anchors.json")),
              let loadedAnchors = try? JSONDecoder().decode(AssetAnchors.self, from: anchorData) else {
            diagnosticMessage = "Unable to load the selected V3 mascot assets."
            return false
        }
        manifest = loaded
        activeTheme = theme
        anchors = loadedAnchors
        themeURL = root
        atlasesByID = Dictionary(uniqueKeysWithValues: loaded.atlases.map { ($0.id, $0) })
        accessoryImages.removeAll(keepingCapacity: true)
        singleBarImageCache.removeAll(keepingCapacity: true)
        countGlyphs.removeAll(keepingCapacity: true)
        purgeAtlasCache()
        diagnosticMessage = nil
        return true
    }

    func image(for frame: AssetFrame) -> NSImage? {
        let frameKey = "\(frame.atlas):\(frame.rect)"
        if frameKey == lastFrameKey, let lastFrameImage { return lastFrameImage }
        guard frame.rect.count == 4,
              let atlas = atlasImage(frame.atlas) else { return nil }
        let x = frame.rect[0], y = frame.rect[1]
        let width = frame.rect[2], height = frame.rect[3]
        guard x >= 0, y >= 0, width > 0, height > 0,
              x <= atlas.width, y <= atlas.height,
              width <= atlas.width - x, height <= atlas.height - y else { return nil }
        let rect = CGRect(x: x, y: y, width: width, height: height)
        guard let cropped = atlas.cropping(to: rect) else { return nil }
        let image = NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
        lastFrameKey = frameKey
        lastFrameImage = image
        return image
    }

    func hudImage(_ name: String) -> NSImage? {
        guard let manifest else { return nil }
        let path: String
        switch name {
        case "bars": path = manifest.hud.barsFile
        case "bubble": path = manifest.hud.bubbleFile
        default: return nil
        }
        return accessoryImage(path)
    }

    var bubblePixelSize: CGSize {
        hudImage("bubble")?.size ?? CGSize(width: 52, height: 46)
    }

    func singleBarImage(topSlot: Bool) -> NSImage? {
        if let cached = singleBarImageCache[topSlot] { return cached }
        guard let source = hudImage("bars"),
              let image = source.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let crop = image.cropping(to: CGRect(
                x: 0,
                y: topSlot ? 0 : image.height / 2,
                width: image.width,
                height: image.height / 2
              )) else { return nil }
        let result = NSImage(cgImage: crop, size: NSSize(width: crop.width, height: crop.height))
        singleBarImageCache[topSlot] = result
        return result
    }

    func countGlyph(for character: Character) -> NSImage? {
        if let glyph = countGlyphs[character] { return glyph }
        guard let index = Array("0123456789+").firstIndex(of: character),
              let sheet = accessoryImage("digits.png")?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let crop = sheet.cropping(to: CGRect(x: index * 8, y: 0, width: 6, height: 10)) else { return nil }
        let glyph = NSImage(cgImage: crop, size: NSSize(width: crop.width, height: crop.height))
        countGlyphs[character] = glyph
        return glyph
    }

    func effectImage(_ name: String, frame: Int) -> NSImage? {
        guard let effect = manifest?.effects[name], frame >= 0, frame < effect.frames else { return nil }
        return accessoryImage("\(effect.path)\(String(format: "%02d", frame)).png")
    }

    func purgeAtlasCache() {
        atlasImages.removeAll(keepingCapacity: true)
        leastRecentlyUsed.removeAll(keepingCapacity: true)
        lastFrameKey = nil
        lastFrameImage = nil
    }

    func recordDiagnostic(_ message: String) {
        diagnosticMessage = message
    }

    private func atlasImage(_ id: String) -> CGImage? {
        guard let metadata = atlasesByID[id] else { return nil }
        if let cached = atlasImages[id] {
            leastRecentlyUsed.removeAll { $0 == id }
            leastRecentlyUsed.append(id)
            return cached
        }
        guard let themeURL,
              let source = CGImageSourceCreateWithURL(themeURL.appendingPathComponent(metadata.file) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == metadata.width, image.height == metadata.height else {
            diagnosticMessage = "Unable to decode atlas page \(id)."
            return nil
        }
        atlasImages[id] = image
        leastRecentlyUsed.append(id)
        while leastRecentlyUsed.count > 8 {
            let victim = leastRecentlyUsed.removeFirst()
            atlasImages.removeValue(forKey: victim)
        }
        return image
    }

    private func accessoryImage(_ relativePath: String) -> NSImage? {
        if let cached = accessoryImages[relativePath] { return cached }
        guard let themeURL,
              let image = NSImage(contentsOf: themeURL.appendingPathComponent(relativePath)) else { return nil }
        accessoryImages[relativePath] = image
        return image
    }
}
