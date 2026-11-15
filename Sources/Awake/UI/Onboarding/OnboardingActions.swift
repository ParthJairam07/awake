import AppKit

/// Step E: what the Setup window's buttons do outside the app. Nothing here
/// runs sudo: "Run in Terminal" hands Terminal a script, and Terminal asks
/// for the password where the user can see what is asking.
enum OnboardingActions {
    static let commandFileName = "setup-sudoers.command"

    /// The text of the file Terminal is given: the command and nothing else.
    static func commandFileText(command: String) -> String {
        "#!/bin/bash\n# Written by Awake's Setup window. Installs /etc/sudoers.d/awake; asks for your password.\nexec \(command)\n"
    }

    /// Write the `.command` file into `directory` (Awake's Application
    /// Support folder), readable and runnable by the owner only, replacing
    /// an older one atomically.
    static func writeCommandFile(command: String, directory: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent(commandFileName)
        try Data(commandFileText(command: command).utf8).write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }

    /// Open Terminal on the sudoers command. Returns what went wrong, or nil.
    @MainActor
    static func runInTerminal(command: String, directory: URL) -> String? {
        do {
            let file = try writeCommandFile(command: command, directory: directory)
            let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { Log.error("setup: could not open Terminal: \(error.localizedDescription)") }
            }
            Log.info("setup: opened Terminal with the sudoers command")
            return nil
        } catch {
            Log.error("setup: could not write the Terminal command: \(error.localizedDescription)")
            return "Could not prepare the command (\(error.localizedDescription)). Copy it and paste it into Terminal instead."
        }
    }

    @MainActor
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
