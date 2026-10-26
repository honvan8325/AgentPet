import Foundation

private struct PetThemeMetadata: Decodable {
    let id: String
    let name: String
}

struct PetTheme: Hashable, Identifiable {
    let id: String
    let title: String

    var resourceDirectory: String {
        "Themes/\(id)"
    }

    static let available: [PetTheme] = {
        guard let root = Bundle.main.resourceURL?
            .appendingPathComponent("Themes", isDirectory: true),
            let folders = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        return folders.compactMap { folder -> PetTheme? in
            guard
                (try? folder.resourceValues(
                    forKeys: [.isDirectoryKey]
                ).isDirectory) == true,
                let data = try? Data(
                    contentsOf: folder.appendingPathComponent("theme.json")
                ),
                let metadata = try? JSONDecoder().decode(
                    PetThemeMetadata.self,
                    from: data
                ),
                metadata.id == folder.lastPathComponent,
                !metadata.name.isEmpty
            else {
                return nil
            }

            return PetTheme(
                id: metadata.id,
                title: metadata.name
            )
        }
        .sorted { $0.id < $1.id }
    }()

    static let defaultTheme =
        available.first { $0.id == "chick" }
        ?? available.first
        ?? PetTheme(id: "chick", title: "Chick")
}
