# Homebrew cask for Awake.
#
# This file is the template. The Release workflow (.github/workflows/release.yml,
# job "cask") rewrites `version` and `sha256` for each stable release and
# commits the result to the `homebrew` branch of this repository, and to the
# tap repository ParthJairam07/homebrew-awake when HOMEBREW_TAP_TOKEN is set.
# docs/releasing.md, "Homebrew cask", has the steps. Install with:
#
#   brew tap ParthJairam07/awake && brew install --cask awake
cask "awake" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/ParthJairam07/awake/releases/download/v#{version}/Awake-#{version}.zip"
  name "Awake"
  desc "Keeps the computer awake for timed sessions while coding agents run unattended"
  homepage "https://github.com/ParthJairam07/awake"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :tahoe

  # ~/Applications, where scripts/install.sh puts the app and where
  # scripts/uninstall.sh and the recovery docs expect it.
  app "Awake.app", target: "#{Dir.home}/Applications/Awake.app"

  # Homebrew unloads the recovery agent, then asks the app to quit; quitting
  # ends a running session and undoes its changes before the app is removed.
  # This also runs on `brew upgrade`; the app loads its agent again at the
  # next session start.
  uninstall launchctl: "com.awake.backstop",
            quit:      "com.parthjairam.awake"

  zap delete: "/etc/sudoers.d/awake",
      trash:  [
        "~/Library/Application Support/Awake",
        "~/Library/LaunchAgents/com.awake.backstop.plist",
        "~/Library/Logs/Awake",
        "~/Library/Preferences/com.parthjairam.awake.plist",
      ]

  caveats <<~EOS
    Awake is in ~/Applications. Open it once: the Setup window asks for the
    permissions it needs and shows the one command that needs your password,
    a sudoers rule for four pmset commands. No session can start without it.

    If macOS says the app cannot be opened, this release is an unsigned
    build: right-click Awake in ~/Applications and choose Open, or allow it
    in System Settings > Privacy & Security.

    End a running session before `brew upgrade` or `brew uninstall`.
    `brew uninstall --cask awake` keeps the sudoers rule, your settings and
    the logs; add --zap to remove them too.
  EOS
end
