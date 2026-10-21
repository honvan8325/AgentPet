import Foundation

struct PetTheme: Hashable, Identifiable {
    let id: String
    let title: String

    var resourceDirectory: String { "Themes/\(id)" }

    static let available: [PetTheme] = {
        guard let resourceURL = Bundle.main.resourceURL else { return [] }
        let themesURL = resourceURL.appendingPathComponent("Themes", isDirectory: true)
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: themesURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return folders.compactMap { folder in
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
                  let manifest = try? JSONDecoder().decode(SpriteManifest.self, from: data),
                  EnergyTier.allCases.allSatisfy({ tier in
                      guard let file = manifest.tiers[tier.rawValue]?.file else { return false }
                      return FileManager.default.fileExists(
                          atPath: folder.appendingPathComponent(file).path
                      )
                  }) else { return nil }
            return PetTheme(id: folder.lastPathComponent, title: manifest.name)
        }
        .sorted { $0.id < $1.id }
    }()

    static let defaultTheme: PetTheme =
        available.first(where: { $0.id == "chick" })
        ?? available.first
        ?? PetTheme(id: "chick", title: "Chick")
}
