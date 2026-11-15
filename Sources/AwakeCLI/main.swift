import Darwin

// The `awake` command: leases from a shell, and `awake mcp` for agents.
// Everything it does is read or write a file under Application
// Support/Awake; it never talks to the app, so it works when the app is
// not running.
exit(CLI.run(Array(CommandLine.arguments.dropFirst()), in: .live()))
