import Foundation

struct PetTheme: Hashable, Identifiable {
    private struct Manifest: Decodable {
        let name: String
    }

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
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return nil }
            return PetTheme(id: folder.lastPathComponent, title: manifest.name)
        }
        .sorted { $0.id < $1.id }
    }()

    static let defaultTheme = available.first(where: { $0.id == "chick" }) ?? available[0]
}
