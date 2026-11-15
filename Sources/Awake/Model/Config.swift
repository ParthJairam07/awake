import Foundation

/// User settings, persisted as `config.json` (spec section 10).
/// Decoding tolerates missing keys so configs written by older builds load
/// with defaults filled in.
struct Config: Codable, Equatable, Sendable {
    // Session
    /// Preset durations in seconds, shown as chips.
    var presets: [TimeInterval] = Config.defaultPresets
    var defaultPreset: TimeInterval = 4 * 3600
    /// The pill that is focused when the pills open, for a start and for an
    /// extend.
    var defaultFocusField: DurationInput.Field = .hours
    /// Hard ceiling on a session, including extensions. 30 days.
    var maxDuration: TimeInterval = 30 * 24 * 3600

    // Lid-close actions
    /// Bundle ids to SIGSTOP while the lid is closed.
    var freezeList: [String] = Config.defaultFreezeList
    /// Also SIGSTOP every other Dock app that is not an agent app, an Apple
    /// app, Docker Desktop or built-in protected (`FreezePlanner.builtInProtected`).
    /// Off by default (and for a config.json without the key): a fresh
    /// install freezes only the freeze list until the user opts in. A
    /// config.json an earlier build saved with it on gets it turned off
    /// once (`applyLidCloseDefaults`).
    var freezeAllApps: Bool = false
    /// SIGSTOP Docker Desktop on lid close when `docker ps` finds no running
    /// container, checked once more right before the signal. Off by default
    /// (and for a config.json without the key): a container that starts
    /// between the last check and the signal is frozen with Desktop.
    var dockerRule: Bool = false
    /// Mute the output on lid close and restore the volume on open. On by
    /// default: with sleep disabled, sound otherwise keeps playing from the
    /// closed laptop. A config.json an earlier build saved with it off gets
    /// it turned on once (`applyLidCloseDefaults`).
    var muteOnLidClose: Bool = true
    /// Save the display brightness and keyboard backlight, set both to zero
    /// on lid close and restore them on lid open. With sleep disabled macOS
    /// no longer turns the panel off itself.
    var darkenDisplayOnLidClose: Bool = true
    /// Switch Low Power Mode on while the lid is closed (heat and battery:
    /// with sleep disabled the machine otherwise runs at full speed).
    var lowPowerOnLidClose: Bool = true
    /// Lock the login session on lid close. With sleep disabled the Mac
    /// never reaches the lock macOS would apply on wake, so an unattended
    /// laptop would otherwise stay open to its terminals and agents.
    var lockScreenOnLidClose: Bool = true
    /// A lid closed with an external display online is a desk, not a
    /// departure: skip the lid actions (and the lid's Low Power Mode) and
    /// run them only if that display goes away while the lid stays closed.
    var skipLidActionsOnExternalDisplay: Bool = true

    // Agent apps that must never be throttled or frozen.
    var agentList: [String] = Config.defaultAgentList
    /// Write `NSAppSleepDisabled = YES` into each agent app's preferences at
    /// session start so App Nap never throttles it, and put the previous
    /// value back at session end. Off: Awake never writes another app's
    /// preferences.
    var disableAppNapForAgents: Bool = false

    // Battery / thermal floors
    /// Battery percentage below which Low Power Mode is switched on.
    var lowPowerFloor: Int = 40
    /// Battery percentage below which the session is ended. 0 turns the
    /// battery end off. Otherwise kept below `lowPowerFloor`, which gives Low
    /// Power Mode a chance to come on before the session ends; a reading
    /// already below both floors still ends it. See `setEndFloor`,
    /// `setLowPowerFloor` and `normalizeFloors`.
    var endFloor: Int = 10
    var thermalRules: Bool = true
    /// CPU speed limit (`pmset -g therm`, percent of full speed) at or below
    /// which Low Power Mode goes on under `thermalRules`: macOS is already
    /// throttling this hard, so the Mac is hot whatever the thermal state
    /// says. 0 turns the rule off.
    var throttleLowPowerPercent: Int = 50
    /// Battery temperature (°C) at or above which Low Power Mode goes on,
    /// and at or above which the session ends, under `thermalRules`. Only
    /// where the battery driver reports a temperature. 0 turns each off.
    var batteryTempLowPowerC: Int = 45
    var batteryTempEndC: Int = 55

    // Resources
    /// Notify on critical memory pressure and on free disk under the floor.
    var resourceAlerts: Bool = true
    /// Free space on the home volume (GB) under which the disk alert posts.
    /// 0 turns it off.
    var freeDiskFloorGB: Int = 10

    // Network failover
    var hotspotSSID: String = ""
    /// Check that the internet answers (Apple's captive-portal page) rather
    /// than trusting "Wi-Fi connected": a portal or dead DNS then counts
    /// as an outage, and a recovery is only reported once the page loads.
    var internetProbe: Bool = true

    // Phone alerts (phase 1)
    /// ntfy server and topic; an empty topic turns ntfy off. The optional
    /// access token lives in the keychain (`PhoneSecrets`).
    var ntfyServer: String = PhonePush.defaultNtfyServer
    var ntfyTopic: String = ""
    /// Pushover; the app token and user key live in the keychain.
    var pushoverEnabled: Bool = false
    /// Post one summary notification when a session ends (duration,
    /// battery, lid closes, outages, what was restored).
    var sessionSummary: Bool = true
    /// Serve status.json on http://127.0.0.1:<port>/status.json for
    /// dashboards. 0 turns the endpoint off; the file is always written.
    var statusPort: Int = 0
    /// Seconds of outage after which tmux panes are nudged.
    var nudgeThreshold: TimeInterval = 90
    /// tmux targets as `session:window.pane`. Only a pane carrying the
    /// `@awake-nudge` pane option is nudged (TmuxNudge).
    var tmuxTargets: [String] = []
    /// Press Enter after typing `continue`. Off: the word is typed and left
    /// for the user or the program; on: Enter also submits anything already
    /// typed in that pane.
    var tmuxNudgePressesEnter: Bool = false

    // App
    var launchAtLogin: Bool = false
    /// The install (code directory hash, bundle path and the executable's
    /// file identity: `LoginItem.install`) whose login item macOS last
    /// had on file, written when a registration is accepted.
    /// At launch it tells a reinstall, which the app heals by registering
    /// again, from the user removing the item in System Settings, which
    /// the app respects. nil in a config written before this field; the
    /// first launch with the flag on registers once and records it.
    var launchAtLoginInstall: String?

    // One-time updates
    /// Whether this config has had the lid-close update
    /// (`applyLidCloseDefaults`). True for a config this build creates;
    /// false for a config.json without the key, which an earlier build
    /// saved. Once true it stays true, so a user who turns either setting
    /// back is never overridden again.
    var lidCloseDefaultsApplied: Bool = true
    /// What that update changed, shown in Settings until the user dismisses
    /// it. nil on a fresh install, when the update changed nothing, and
    /// after dismissal.
    var lidCloseDefaultsNotice: LidCloseDefaultsChange?

    // Phase 2
    /// Find running AI coding agents (processes, marked tmux panes, hook
    /// events) during a session and track what each is doing.
    var agentTracking: Bool = true
    /// One notification per transition: an agent asks for input, goes
    /// silent mid-work, or its process goes away.
    var agentWaitingAlerts: Bool = true
    var agentStalledAlerts: Bool = true
    var agentExitedAlerts: Bool = true
    /// "All agents finished" once every agent has been idle or gone for
    /// `allDoneMinutes`.
    var allDoneAlert: Bool = true
    /// Minutes without output or a hook heartbeat after which a working
    /// agent counts as stalled.
    var agentStallMinutes: Int = 10
    var allDoneMinutes: Int = 5
    /// One line per agent in the menu bar menu.
    var showAgentsInMenu: Bool = true
    /// Report dialogs and permission prompts that block an app, read
    /// through the Accessibility API. Does nothing until Awake is
    /// allowed under Privacy & Security > Accessibility.
    var dialogAlerts: Bool = true
    /// Before a battery, heat or planned end: journal the intent and post
    /// "Session ending". Off by default.
    var preEndHooks: Bool = false
    /// With `preEndHooks`: `git add -A`, commit and push in each agent
    /// repo before the end. Off by default.
    var wipCommitOnEnd: Bool = false
    /// Under the Low Power Mode floor, heat or critical memory pressure,
    /// pause the lowest-priority agents first. Off by default.
    var priorityPause: Bool = false
    /// Priority by agent kind or name (`claude`, `codex`, ...): below 0 is
    /// low, 0 normal (the default for anything not listed), above 0 high.
    var agentPriorities: [String: Int] = [:]

    // Phase 4: leases
    /// Honour lease files in Application Support/Awake/leases. Off: the
    /// files are left alone and hold nothing.
    var leasesEnabled: Bool = true
    /// Longest leases can keep the Mac awake: counted from a lease's own
    /// creation, and from the first lease of a session for all of them
    /// together. `maxDuration` still applies on top.
    var leaseCapHours: Int = 8
    /// How long a session that only leases are holding runs on after the
    /// last one is released or expires.
    var leaseGraceMinutes: Int = 5
    /// A lease may start a session when none is running. Off: leases only
    /// stretch a session you started.
    var leasesMayStartSession: Bool = true
    /// Post "Lease granted" and "Last lease released".
    var leaseNotifications: Bool = true

    static let defaultPresets: [TimeInterval] = [
        30 * 60,
        1 * 3600,
        2 * 3600,
        4 * 3600,
        8 * 3600,
        12 * 3600,
        24 * 3600,
        3 * 24 * 3600,
    ]

    /// Default freeze list: chat apps that burn battery in the background.
    static let defaultFreezeList: [String] = [
        "com.tinyspeck.slackmacgap",      // Slack
        "net.whatsapp.WhatsApp",          // WhatsApp
        "com.hnc.Discord",                // Discord
    ]

    /// Default agent list (spec section 5). Bundle ids confirmed against
    /// installed apps where possible; see README for how to edit.
    static let defaultAgentList: [String] = [
        "com.t3tools.t3code",             // T3 Code (Nightly)
        "com.t3tools.t3code.reasoning",   // T3 Code (Reasoning)
        "com.conductor.app",              // Conductor
        "com.apple.Terminal",             // Terminal
        "com.googlecode.iterm2",          // iTerm2
        "com.mitchellh.ghostty",          // Ghostty
        "dev.warp.Warp-Stable",           // Warp
        "com.google.Chrome",              // Google Chrome
        "org.chromium.Chromium",          // Chromium
        "company.thebrowser.Browser",     // Arc
        "com.docker.docker",              // Docker Desktop
        "com.microsoft.VSCode",           // Visual Studio Code
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "dev.zed.Zed",                    // Zed
        "com.google.antigravity",         // Antigravity
        "com.anthropic.claudefordesktop", // Claude
        "com.openai.codex",               // ChatGPT (hosts Codex and computer use)
        "io.tailscale.ipn.macsys",        // Tailscale
        "ai.elementlabs.lmstudio",        // LM Studio
        "com.electron.ollama",            // Ollama
    ]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        presets = try c.decodeIfPresent([TimeInterval].self, forKey: .presets) ?? d.presets
        defaultPreset = try c.decodeIfPresent(TimeInterval.self, forKey: .defaultPreset) ?? d.defaultPreset
        // A value this build does not know falls back to hours; it must not
        // cost the user the rest of the config.
        defaultFocusField = (try? c.decodeIfPresent(DurationInput.Field.self, forKey: .defaultFocusField)) ?? d.defaultFocusField
        maxDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .maxDuration) ?? d.maxDuration
        freezeList = try c.decodeIfPresent([String].self, forKey: .freezeList) ?? d.freezeList
        freezeAllApps = try c.decodeIfPresent(Bool.self, forKey: .freezeAllApps) ?? d.freezeAllApps
        dockerRule = try c.decodeIfPresent(Bool.self, forKey: .dockerRule) ?? d.dockerRule
        lidCloseDefaultsApplied = try c.decodeIfPresent(Bool.self, forKey: .lidCloseDefaultsApplied) ?? false
        lidCloseDefaultsNotice = try c.decodeIfPresent(LidCloseDefaultsChange.self, forKey: .lidCloseDefaultsNotice)
        // Earlier builds read a missing key as off, so the update below
        // sees what such a config.json actually did.
        muteOnLidClose = try c.decodeIfPresent(Bool.self, forKey: .muteOnLidClose) ?? (lidCloseDefaultsApplied && d.muteOnLidClose)
        darkenDisplayOnLidClose = try c.decodeIfPresent(Bool.self, forKey: .darkenDisplayOnLidClose) ?? d.darkenDisplayOnLidClose
        lowPowerOnLidClose = try c.decodeIfPresent(Bool.self, forKey: .lowPowerOnLidClose) ?? d.lowPowerOnLidClose
        lockScreenOnLidClose = try c.decodeIfPresent(Bool.self, forKey: .lockScreenOnLidClose) ?? d.lockScreenOnLidClose
        skipLidActionsOnExternalDisplay = try c.decodeIfPresent(Bool.self, forKey: .skipLidActionsOnExternalDisplay) ?? d.skipLidActionsOnExternalDisplay
        agentList = try c.decodeIfPresent([String].self, forKey: .agentList) ?? d.agentList
        disableAppNapForAgents = try c.decodeIfPresent(Bool.self, forKey: .disableAppNapForAgents) ?? d.disableAppNapForAgents
        lowPowerFloor = try c.decodeIfPresent(Int.self, forKey: .lowPowerFloor) ?? d.lowPowerFloor
        endFloor = try c.decodeIfPresent(Int.self, forKey: .endFloor) ?? d.endFloor
        thermalRules = try c.decodeIfPresent(Bool.self, forKey: .thermalRules) ?? d.thermalRules
        throttleLowPowerPercent = try c.decodeIfPresent(Int.self, forKey: .throttleLowPowerPercent) ?? d.throttleLowPowerPercent
        batteryTempLowPowerC = try c.decodeIfPresent(Int.self, forKey: .batteryTempLowPowerC) ?? d.batteryTempLowPowerC
        batteryTempEndC = try c.decodeIfPresent(Int.self, forKey: .batteryTempEndC) ?? d.batteryTempEndC
        resourceAlerts = try c.decodeIfPresent(Bool.self, forKey: .resourceAlerts) ?? d.resourceAlerts
        freeDiskFloorGB = try c.decodeIfPresent(Int.self, forKey: .freeDiskFloorGB) ?? d.freeDiskFloorGB
        internetProbe = try c.decodeIfPresent(Bool.self, forKey: .internetProbe) ?? d.internetProbe
        ntfyServer = try c.decodeIfPresent(String.self, forKey: .ntfyServer) ?? d.ntfyServer
        ntfyTopic = try c.decodeIfPresent(String.self, forKey: .ntfyTopic) ?? d.ntfyTopic
        pushoverEnabled = try c.decodeIfPresent(Bool.self, forKey: .pushoverEnabled) ?? d.pushoverEnabled
        sessionSummary = try c.decodeIfPresent(Bool.self, forKey: .sessionSummary) ?? d.sessionSummary
        statusPort = try c.decodeIfPresent(Int.self, forKey: .statusPort) ?? d.statusPort
        hotspotSSID = try c.decodeIfPresent(String.self, forKey: .hotspotSSID) ?? d.hotspotSSID
        nudgeThreshold = try c.decodeIfPresent(TimeInterval.self, forKey: .nudgeThreshold) ?? d.nudgeThreshold
        tmuxTargets = try c.decodeIfPresent([String].self, forKey: .tmuxTargets) ?? d.tmuxTargets
        tmuxNudgePressesEnter = try c.decodeIfPresent(Bool.self, forKey: .tmuxNudgePressesEnter) ?? d.tmuxNudgePressesEnter
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        launchAtLoginInstall = try c.decodeIfPresent(String.self, forKey: .launchAtLoginInstall)
        // Phase 2
        agentTracking = try c.decodeIfPresent(Bool.self, forKey: .agentTracking) ?? d.agentTracking
        agentWaitingAlerts = try c.decodeIfPresent(Bool.self, forKey: .agentWaitingAlerts) ?? d.agentWaitingAlerts
        agentStalledAlerts = try c.decodeIfPresent(Bool.self, forKey: .agentStalledAlerts) ?? d.agentStalledAlerts
        agentExitedAlerts = try c.decodeIfPresent(Bool.self, forKey: .agentExitedAlerts) ?? d.agentExitedAlerts
        allDoneAlert = try c.decodeIfPresent(Bool.self, forKey: .allDoneAlert) ?? d.allDoneAlert
        agentStallMinutes = max(1, try c.decodeIfPresent(Int.self, forKey: .agentStallMinutes) ?? d.agentStallMinutes)
        allDoneMinutes = max(1, try c.decodeIfPresent(Int.self, forKey: .allDoneMinutes) ?? d.allDoneMinutes)
        showAgentsInMenu = try c.decodeIfPresent(Bool.self, forKey: .showAgentsInMenu) ?? d.showAgentsInMenu
        dialogAlerts = try c.decodeIfPresent(Bool.self, forKey: .dialogAlerts) ?? d.dialogAlerts
        preEndHooks = try c.decodeIfPresent(Bool.self, forKey: .preEndHooks) ?? d.preEndHooks
        wipCommitOnEnd = try c.decodeIfPresent(Bool.self, forKey: .wipCommitOnEnd) ?? d.wipCommitOnEnd
        priorityPause = try c.decodeIfPresent(Bool.self, forKey: .priorityPause) ?? d.priorityPause
        agentPriorities = try c.decodeIfPresent([String: Int].self, forKey: .agentPriorities) ?? d.agentPriorities
        // Phase 4
        leasesEnabled = try c.decodeIfPresent(Bool.self, forKey: .leasesEnabled) ?? d.leasesEnabled
        leaseCapHours = try c.decodeIfPresent(Int.self, forKey: .leaseCapHours) ?? d.leaseCapHours
        leaseGraceMinutes = try c.decodeIfPresent(Int.self, forKey: .leaseGraceMinutes) ?? d.leaseGraceMinutes
        leasesMayStartSession = try c.decodeIfPresent(Bool.self, forKey: .leasesMayStartSession) ?? d.leasesMayStartSession
        leaseNotifications = try c.decodeIfPresent(Bool.self, forKey: .leaseNotifications) ?? d.leaseNotifications
    }
}

// MARK: Lid-close update

extension Config {
    /// The one-time lid-close update for a config.json an earlier build
    /// saved: freeze-all off and mute on lid close on, the defaults since
    /// freeze-all stopped a meeting notetaker and sound kept playing with
    /// the lid closed. Marks the config either way, so it runs once.
    /// Returns what it changed and records that for Settings; nil when the
    /// config already had the update or both settings already matched.
    mutating func applyLidCloseDefaults() -> LidCloseDefaultsChange? {
        guard !lidCloseDefaultsApplied else { return nil }
        lidCloseDefaultsApplied = true
        let change = LidCloseDefaultsChange(turnedOffFreezeAll: freezeAllApps, turnedOnMute: !muteOnLidClose)
        freezeAllApps = false
        muteOnLidClose = true
        guard change.turnedOffFreezeAll || change.turnedOnMute else { return nil }
        lidCloseDefaultsNotice = change
        return change
    }
}

/// What `Config.applyLidCloseDefaults` changed. The notification and the
/// line in Settings name each change and where to change it back.
struct LidCloseDefaultsChange: Codable, Equatable, Sendable {
    var turnedOffFreezeAll: Bool
    var turnedOnMute: Bool

    static let title = "Lid-close settings changed"

    /// The changes as one clause, for example: "Mute audio on lid close"
    /// is now on.
    var changes: String {
        var parts: [String] = []
        if turnedOffFreezeAll { parts.append("\"Freeze every other app while the lid is closed\" is now off") }
        if turnedOnMute { parts.append("\"Mute audio on lid close\" is now on") }
        return parts.joined(separator: " and ")
    }

    private var both: Bool { turnedOffFreezeAll && turnedOnMute }

    var notificationBody: String {
        "This update changed \(both ? "two lid-close settings" : "a lid-close setting"): \(changes). "
            + "To change \(both ? "them" : "it") back, choose Settings\u{2026} from the Awake menu bar icon and look under Lid-close actions."
    }

    var settingsLine: String {
        "This update changed \(both ? "two lid-close settings" : "a lid-close setting"): \(changes). "
            + "\(both ? "Both toggles are" : "The toggle is") below."
    }
}

// MARK: Battery floors

extension Config {
    /// Settings step for both floors; the floors are kept at least one step
    /// apart.
    static let floorStep = 5
    /// Highest end floor Settings offers: one step below a 100% Low Power
    /// Mode floor.
    static let maxEndFloor = 100 - floorStep

    /// A non-zero end floor sits below the Low Power Mode floor, so the mode
    /// gets its chance before the end.
    var floorsAreOrdered: Bool { endFloor == 0 || endFloor < lowPowerFloor }

    /// Sets the end floor (0...`maxEndFloor`) and raises the Low Power Mode
    /// floor one step above it when it would otherwise not be above it.
    mutating func setEndFloor(_ value: Int) {
        endFloor = min(max(value, 0), Config.maxEndFloor)
        if endFloor > 0, lowPowerFloor <= endFloor {
            lowPowerFloor = min(endFloor + Config.floorStep, 100)
        }
    }

    /// Sets the Low Power Mode floor (0...100) and lowers the end floor one
    /// step below it when it would otherwise not be below it. An end floor
    /// pushed to 0 is off.
    mutating func setLowPowerFloor(_ value: Int) {
        lowPowerFloor = min(max(value, 0), 100)
        if endFloor > 0, endFloor >= lowPowerFloor {
            endFloor = max(lowPowerFloor - Config.floorStep, 0)
        }
    }

    /// Clamps both floors to their ranges and restores the order by raising
    /// the Low Power Mode floor, never by lowering the end the user asked
    /// for. Returns a description of the change for the log, or nil when
    /// nothing changed. Run on a config.json that Settings did not write.
    mutating func normalizeFloors() -> String? {
        let before = (lowPowerFloor, endFloor)
        lowPowerFloor = min(max(lowPowerFloor, 0), 100)
        endFloor = min(max(endFloor, 0), Config.maxEndFloor)
        if !floorsAreOrdered {
            lowPowerFloor = min(endFloor + Config.floorStep, 100)
        }
        guard (lowPowerFloor, endFloor) != before else { return nil }
        return "battery floors corrected: lowPowerFloor \(before.0) -> \(lowPowerFloor), endFloor \(before.1) -> \(endFloor)"
    }
}

// MARK: Leases (phase 4)

extension Config {
    static let leaseCapRange = 1...72
    static let leaseGraceRange = 0...60

    /// The cap in seconds, clamped to what Settings offers: a hand-edited
    /// 0 or a negative number must not turn the cap off.
    var leaseCapSeconds: TimeInterval {
        TimeInterval(min(max(leaseCapHours, Config.leaseCapRange.lowerBound), Config.leaseCapRange.upperBound)) * 3600
    }

    var leaseGraceSeconds: TimeInterval {
        TimeInterval(min(max(leaseGraceMinutes, Config.leaseGraceRange.lowerBound), Config.leaseGraceRange.upperBound)) * 60
    }
}
