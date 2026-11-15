import Foundation

/// Settings' "Install `awake` command": a symlink named `awake` that
/// points at the command inside the app bundle
/// (`Awake.app/Contents/Helpers/awake`), in `/usr/local/bin` when that
/// directory can be written without a password and in `~/.local/bin`
/// otherwise. Never sudo. scripts/link-cli.sh does the same from a shell.
enum CommandLink {
    /// Where build-app.sh puts the command. Not Contents/MacOS: on a
    /// volume that ignores case, `awake` there would be the app's own
    /// `Awake`.
    static func command(inBundle bundle: URL) -> URL {
        bundle.appendingPathComponent("Contents/Helpers/awake")
    }

    struct Installed: Equatable {
        var link: URL
        /// True when the link went to ~/.local/bin, which a shell only
        /// searches if the user's PATH names it.
        var needsPath: Bool

        var message: String {
            needsPath
                ? "Installed at \(link.path). If your shell does not find awake, add \(link.deletingLastPathComponent().path) to your PATH."
                : "Installed at \(link.path)."
        }
    }

    enum Failure: Error, LocalizedError, Equatable {
        case noCommand(String)
        case occupied(String)
        case failed(String, String)

        var errorDescription: String? {
            switch self {
            case let .noCommand(path): "This build has no awake command at \(path). Install Awake with scripts/install.sh or from a release, then try again."
            case let .occupied(path): "\(path) already exists and is not a link, so it was left alone. Remove it and try again."
            case let .failed(path, why): "Could not create \(path): \(why)"
            }
        }
    }

    static func install(
        bundle: URL = Bundle.main.bundleURL,
        systemBin: URL = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Result<Installed, Failure> {
        let fm = FileManager.default
        let source = command(inBundle: bundle)
        guard fm.isExecutableFile(atPath: source.path) else { return .failure(.noCommand(source.path)) }

        var isDirectory: ObjCBool = false
        let useSystem = fm.fileExists(atPath: systemBin.path, isDirectory: &isDirectory) && isDirectory.boolValue && fm.isWritableFile(atPath: systemBin.path)
        let directory = useSystem ? systemBin : home.appendingPathComponent(".local/bin", isDirectory: true)
        let link = directory.appendingPathComponent("awake")
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            // attributesOfItem does not follow a link, so a dangling one
            // (the app was moved) is seen and replaced.
            if let attributes = try? fm.attributesOfItem(atPath: link.path) {
                guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else { return .failure(.occupied(link.path)) }
                try fm.removeItem(at: link)
            }
            try fm.createSymbolicLink(at: link, withDestinationURL: source)
        } catch {
            return .failure(.failed(link.path, error.localizedDescription))
        }
        Log.info("awake command linked at \(link.path) -> \(source.path)")
        return .success(Installed(link: link, needsPath: !useSystem))
    }
}
