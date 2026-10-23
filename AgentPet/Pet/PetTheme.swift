import Foundation

private struct PetThemeHeader: Decodable {
    let schemaVersion: Int
    let themeId: String
    let displayName: String
}

struct PetTheme: Hashable, Identifiable {
    let id: String
    let title: String

    var resourceDirectory: String { "Themes/\(id)" }

    static let available: [PetTheme] = {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("Themes", isDirectory: true),
              let folders = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }
        return folders.compactMap { folder in
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
                  let manifest = try? JSONDecoder().decode(PetThemeHeader.self, from: data),
                  manifest.schemaVersion == 3,
                  manifest.themeId == folder.lastPathComponent,
                  !manifest.displayName.isEmpty else { return nil }
            return PetTheme(id: manifest.themeId, title: manifest.displayName)
        }.sorted { $0.id < $1.id }
    }()

    static let defaultTheme = available.first(where: { $0.id == "chick" })
        ?? available.first
        ?? PetTheme(id: "chick", title: "Chick")
}
