import AppKit
import SwiftUI

/// The settings window (spec 10). Every change is written straight through
/// `manager.config` to config.json.
struct SettingsView: View {
    let manager: SessionManager
    let secrets: any HotspotSecretStore
    let phoneSecrets: any PhoneSecretStore
    let locationPermission: LocationPermission
    /// Launch at login as macOS reports it, not as config.json remembers it.
    let loginItem: LoginItem
    /// The "Check for updates" button's one request and its report.
    let releases: ReleaseChecker

    @State private var newPreset = ""
    @State private var presetError: String?
    @State private var newFreezeBundle = ""
    @State private var newAgentBundle = ""
    @State private var newTmuxTarget = ""
    /// The password field, saving, what was saved, and the notice under
    /// the field.
    @State private var hotspot = HotspotPasswordField()
    @State private var phone = PhoneSettingsModel()
    /// Names of the apps the automatic lid-close scope would freeze right
    /// now (the freeze list excluded); refreshed on appear and toggle.
    @State private var wouldFreeze: [String] = []
    /// What the "Install `awake` command" button last reported.
    @State private var commandLinkNotice: String?
    @State private var commandLinkFailed = false

    var body: some View {
        Form {
            sessionSection
            lidSection
            agentSection
            powerSection
            networkSection
            phoneSection
            leaseSection
            appSection
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 560, idealHeight: 720)
        .onAppear {
            loadPassword()
            refreshWouldFreeze()
            // The user may have approved or removed the item in System
            // Settings since the launch-time check (LoginItem also re-reads
            // whenever the app becomes active, for a window left open).
            loginItem.refresh()
        }
        // The failover may find the saved password unreadable while the
        // window is open, and an SSID edit makes the notice about another
        // hotspot's item: the notice follows both.
        .onChange(of: manager.services?.status.hotspotPasswordReport) { recheckPassword() }
        .onChange(of: HotspotSSID.normalized(manager.config.hotspotSSID)) { recheckPassword() }
        // The preview depends on the toggle, both lists and what is running:
        // recompute on any config change and whenever an app launches or quits.
        .onChange(of: manager.config) { refreshWouldFreeze() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in refreshWouldFreeze() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in refreshWouldFreeze() }
    }

    // MARK: Bindings

    private func bind<T: Equatable>(_ keyPath: WritableKeyPath<Config, T>) -> Binding<T> {
        Binding(
            get: { manager.config[keyPath: keyPath] },
            set: { value in
                guard manager.config[keyPath: keyPath] != value else { return }
                manager.config[keyPath: keyPath] = value
                save()
            }
        )
    }

    private func save() {
        do {
            try manager.store.saveConfig(manager.config)
        } catch {
            Log.error("could not save config: \(error.localizedDescription)")
        }
    }

    private func update(_ change: (inout Config) -> Void) {
        var c = manager.config
        change(&c)
        guard c != manager.config else { return }
        manager.config = c
        save()
    }

    /// The floor steppers go through the Config setters, which move the
    /// other floor when the two would cross.
    private var lowPowerFloor: Binding<Int> {
        Binding(get: { manager.config.lowPowerFloor }, set: { v in update { $0.setLowPowerFloor(v) } })
    }

    private var endFloor: Binding<Int> {
        Binding(get: { manager.config.endFloor }, set: { v in update { $0.setEndFloor(v) } })
    }

    // MARK: Sections

    private var sessionSection: some View {
        Section("Session") {
            ForEach(manager.config.presets, id: \.self) { p in
                HStack {
                    Text(chipLabel(for: p))
                        .monospacedDigit()
                    Spacer()
                    if p == manager.config.defaultPreset {
                        Text("default").font(.caption).foregroundStyle(.secondary)
                    }
                    removeButton {
                        update { $0.presets.removeAll { $0 == p } }
                    }
                }
            }
            HStack {
                TextField("Add preset (30m, 2h, 1h30m, 3d)", text: $newPreset)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addPreset)
                Button("Add", action: addPreset)
                    .disabled(DurationParser.seconds(from: newPreset) == nil)
            }
            if let presetError {
                Text(presetError).font(.caption).foregroundStyle(.red)
            }
            Picker("Default preset", selection: bind(\.defaultPreset)) {
                ForEach(manager.config.presets, id: \.self) { p in
                    Text(chipLabel(for: p)).tag(p)
                }
                if !manager.config.presets.contains(manager.config.defaultPreset) {
                    Text(chipLabel(for: manager.config.defaultPreset)).tag(manager.config.defaultPreset)
                }
            }
            Picker("Default field", selection: bind(\.defaultFocusField)) {
                ForEach(DurationInput.Field.allCases, id: \.self) { field in
                    Text(field.placeholder).tag(field)
                }
            }
            .help("The pill that is focused when the pills open")
            LabeledContent("Maximum session") {
                Text(chipLabel(for: manager.config.maxDuration)).foregroundStyle(.secondary)
            }
        }
    }

    private func addPreset() {
        guard let s = DurationParser.seconds(from: newPreset) else { return }
        guard s <= manager.config.maxDuration else {
            presetError = "Presets cannot exceed \(chipLabel(for: manager.config.maxDuration))."
            return
        }
        presetError = nil
        update {
            if !$0.presets.contains(s) {
                $0.presets.append(s)
                $0.presets.sort()
            }
        }
        newPreset = ""
    }

    /// Under the mute toggle and in the README. Apple Platform Security,
    /// "Hardware microphone disconnect".
    static let microphoneNote = "On Mac laptops with Apple silicon or a T2 chip, closing the lid disconnects the built-in microphone in hardware. Recording a meeting with the lid closed needs AirPods or an external mic."

    private var lidSection: some View {
        Section {
            // The one-time lid-close update, for a user who has
            // notifications turned off. Stays until dismissed.
            if let notice = manager.config.lidCloseDefaultsNotice {
                HStack(alignment: .firstTextBaseline) {
                    Text(notice.settingsLine)
                        .font(.callout)
                    Spacer()
                    Button("Dismiss") { manager.dismissLidCloseNotice() }
                }
            }
            Toggle("Lock the screen on lid close", isOn: bind(\.lockScreenOnLidClose))
            Text("With sleep disabled the Mac never reaches the lock macOS applies on wake, so an unattended laptop would stay open to its terminals and agents.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Toggle("Leave everything alone when an external display is connected", isOn: bind(\.skipLidActionsOnExternalDisplay))
            Text("A lid closed with a monitor attached is a desk, not a departure: no lock, darken, mute, freeze or Low Power Mode. If the monitor is unplugged while the lid stays closed, the actions run then.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Toggle("Turn off the display and keyboard backlight", isOn: bind(\.darkenDisplayOnLidClose))
            ForEach(manager.darkenRefusals, id: \.self) { reason in
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            bundleList(
                title: "Freeze while the lid is closed",
                items: manager.config.freezeList,
                newValue: $newFreezeBundle,
                add: { id in update { if !$0.freezeList.contains(id) { $0.freezeList.append(id) } } },
                remove: { id in update { $0.freezeList.removeAll { $0 == id } } }
            )
            Toggle("Freeze every other app while the lid is closed", isOn: bind(\.freezeAllApps))
            Text(wouldFreezeText)
                .font(.callout)
                .foregroundStyle(.secondary)
            Toggle("Pause Docker Desktop when no containers are running", isOn: bind(\.dockerRule))
            Text("Off by default. When on, Docker Desktop is paused only if a second check right before the pause still finds no running container; a container that starts in that last moment is paused with it.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Toggle("Mute audio on lid close", isOn: bind(\.muteOnLidClose))
            Text(Self.microphoneNote)
                .font(.callout)
                .foregroundStyle(.secondary)
            Toggle("Low Power Mode while the lid is closed", isOn: bind(\.lowPowerOnLidClose))
                // A floor input: apply it now if the lid is already closed.
                .onChange(of: manager.config.lowPowerOnLidClose) { manager.services?.reevaluateFloors() }
        } header: {
            Text("Lid-close actions")
        } footer: {
            Text("Apps on the list above are stopped with SIGSTOP while the lid is closed and resumed when it opens. With \"Freeze every other app\" on (off by default), every other Dock app is stopped too, except agent apps, Apple apps, Docker Desktop and built-in protected apps (editors, terminals, browsers, AI apps, password managers, local databases, Tailscale, local model servers, and meeting, recording and dictation apps such as Zoom, Teams, Webex, Wispr Flow, Granola, Otter, OBS and Loom). Agent apps are never frozen. The display brightness and keyboard backlight are saved, set to zero and restored when the lid opens. If Awake is not running when you open the lid, press the brightness-up key.")
        }
    }

    private var agentSection: some View {
        Section {
            bundleList(
                title: "Never throttle or freeze",
                items: manager.config.agentList,
                newValue: $newAgentBundle,
                add: { id in update { if !$0.agentList.contains(id) { $0.agentList.append(id) } } },
                remove: { id in update { $0.agentList.removeAll { $0 == id } } }
            )
            Toggle("Turn App Nap off for these apps during a session", isOn: bind(\.disableAppNapForAgents))
            Text("Writes NSAppSleepDisabled = YES into each listed app's preferences when a session starts and puts the previous value back when it ends.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } header: {
            Text("Agent apps")
        } footer: {
            Text("Agent apps are never frozen or throttled. Editors, AI apps, terminals, browsers, password managers, local databases, Tailscale, local model servers, and meeting, recording and dictation apps are also protected from the automatic lid-close scope even when they are not listed here; adding one to the freeze list above overrides that.")
        }
    }

    private var wouldFreezeText: String {
        guard manager.config.freezeAllApps else { return "Would freeze now: the list above only" }
        return wouldFreeze.isEmpty ? "Would freeze now: nothing else" : "Would freeze now: \(wouldFreeze.joined(separator: ", "))"
    }

    /// Same planner as the lid-close action, over the apps running now.
    private func refreshWouldFreeze() {
        let selfId = Bundle.main.bundleIdentifier ?? Paths.bundleIdentifier
        wouldFreeze = FreezePlanner.automaticCandidates(config: manager.config, apps: Freezer.runningApps(), selfBundleId: selfId).map(\.name)
    }

    private var powerSection: some View {
        Section("Battery and thermal") {
            Stepper(value: lowPowerFloor, in: 0...100, step: Config.floorStep) {
                LabeledContent("Low Power Mode below", value: "\(manager.config.lowPowerFloor)%")
            }
            Stepper(value: endFloor, in: 0...Config.maxEndFloor, step: Config.floorStep) {
                LabeledContent("End session below", value: "\(manager.config.endFloor)%")
            }
            Text("0 turns the battery end off. The end floor stays below the Low Power Mode floor. Moving one onto the other moves it along.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Thermal rules (Low Power Mode when hot, end when critical)", isOn: bind(\.thermalRules))
            Text("Hot means the thermal state is serious, or macOS has limited the CPU to \(manager.config.throttleLowPowerPercent)% or less, or the battery reports \(manager.config.batteryTempLowPowerC) °C or more; the session ends at \(manager.config.batteryTempEndC) °C. A charger that cannot keep up with the load counts as no charger: the battery floors apply while it drains.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Alert on critical memory pressure and low disk", isOn: bind(\.resourceAlerts))
            Stepper(value: freeDiskFloor, in: 0...200, step: 5) {
                LabeledContent("Disk alert below", value: "\(manager.config.freeDiskFloorGB) GB free")
            }
        }
    }

    private var statusPort: Binding<Int> {
        Binding(get: { manager.config.statusPort }, set: { v in update { $0.statusPort = min(max(0, v), 65535) } })
    }

    private var freeDiskFloor: Binding<Int> {
        Binding(get: { manager.config.freeDiskFloorGB }, set: { v in update { $0.freeDiskFloorGB = max(0, v) } })
    }

    private var networkSection: some View {
        Section {
            TextField("Hotspot SSID", text: bind(\.hotspotSSID))
            Toggle("Check that the internet answers, not just that Wi-Fi is connected", isOn: bind(\.internetProbe))
            Text("A captive portal or dead DNS then counts as an outage, and a recovery is reported only once Apple's connectivity page loads.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                SecureField("Hotspot password", text: Binding(get: { hotspot.password }, set: { hotspot.edit($0) }))
                    .onSubmit(savePassword)
                Button(hotspot.buttonTitle(ssid: manager.config.hotspotSSID), action: savePassword)
                    .disabled(hotspot.password.isEmpty || hotspot.saving)
            }
            if let notice = hotspot.notice {
                Text(notice).font(.caption).foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Location: \(locationPermission.statusDescription)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if locationPermission.isDenied {
                        Button("Open Location Services") {
                            locationPermission.openLocationServicesSettings()
                        }
                    }
                }
                // macOS has no when-in-use grant for Mac apps: the grant is
                // recorded as Location Services access for Awake.
                Text("macOS records this grant as Location Services access for Awake. Awake uses it only to read Wi-Fi network names and never requests your location.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Stepper(value: nudgeSeconds, in: 10...900, step: 10) {
                LabeledContent("Nudge tmux after", value: "\(Int(manager.config.nudgeThreshold)) s offline")
            }
            Text("After that long offline, Awake types \"continue\" into each pane listed below. Only a pane you have marked with this tmux command is nudged. Mark a dedicated pane, not one you type in.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(TmuxNudge.markCommand())
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Toggle("Press Enter after continue", isOn: bind(\.tmuxNudgePressesEnter))
            Text("Enter submits whatever is already typed in that pane, including a line that was never finished. When off, \"continue\" is typed and nothing submits it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(manager.config.tmuxTargets, id: \.self) { t in
                HStack {
                    Text(t).font(.system(.body, design: .monospaced))
                    Spacer()
                    removeButton {
                        update { $0.tmuxTargets.removeAll { $0 == t } }
                    }
                }
            }
            HStack {
                TextField("tmux target (session:window.pane)", text: $newTmuxTarget)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTmuxTarget)
                Button("Add", action: addTmuxTarget)
                    .disabled(newTmuxTarget.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Network failover")
        } footer: {
            Text("The password is kept in the login keychain, readable without a prompt only by the build of Awake that saved it; after a reinstall, enter it again. Location permission lets macOS reveal Wi-Fi network names and find the configured hotspot.")
        }
    }

    private var nudgeSeconds: Binding<Int> {
        Binding(
            get: { Int(manager.config.nudgeThreshold) },
            set: { seconds in update { $0.nudgeThreshold = TimeInterval(seconds) } }
        )
    }

    /// Fills the field when the window appears (`loadForField`).
    private func loadPassword() {
        let request = hotspot.startLoad(ssid: manager.config.hotspotSSID)
        Task {
            await Self.loadForField(request, secrets: secrets) {
                hotspot.finishRead($0, ssid: manager.config.hotspotSSID, password: $1.password, notice: $1.notice)
            }
        }
    }

    /// Reads the notice again for the hotspot configured now, without a
    /// prompt and without touching the field.
    private func recheckPassword() {
        recheckPassword(hotspot.startRead(ssid: manager.config.hotspotSSID))
    }

    private func recheckPassword(_ request: HotspotPasswordField.Read) {
        Task {
            await Self.readForField(
                request,
                first: { await recheckedNotice() },
                again: { await recheckedNotice() },
                finish: { hotspot.finishRead($0, ssid: manager.config.hotspotSSID, password: $1.password, notice: $1.notice) }
            )
        }
    }

    private func recheckedNotice() async -> (password: String, notice: String?) {
        let notice = await Self.hotspotNotice(
            reported: manager.services?.status.hotspotPasswordReport,
            ssid: manager.config.hotspotSSID,
            reread: secrets.peek
        )
        return ("", notice)
    }

    /// Loads the saved password into the field, without a keychain prompt.
    /// An item this build may not read leaves the field empty and says
    /// why, so the user re-enters it; saving then replaces the item (see
    /// `KeychainStore`). The read can wait behind a save, so a field
    /// edited meanwhile is kept, even one typed in and emptied again, and
    /// a password read for an SSID edited away meanwhile is not shown: the
    /// SSID configured now is read instead. That read is a peek: the
    /// account a later save moves the password from stays the one the
    /// window loaded, as it does for any SSID edit, so the old SSID's item
    /// is still removed.
    static func loadForField(
        _ request: HotspotPasswordField.Read,
        secrets: any HotspotSecretStore,
        finish: @MainActor (HotspotPasswordField.Read, (password: String, notice: String?)) -> HotspotPasswordField.ReadAnswer
    ) async {
        await readForField(
            request,
            first: { await loadedPassword(secrets.load) },
            again: { await loadedPassword(secrets.peek) },
            finish: finish
        )
    }

    /// Runs a load or recheck for the field: `first` reads, and `finish`
    /// takes the answer. While the SSID was edited during the read,
    /// `finish` drops the answer, and `again` reads the SSID configured
    /// now, until an answer is used or dropped.
    static func readForField(
        _ request: HotspotPasswordField.Read,
        first: @MainActor () async -> (password: String, notice: String?),
        again: @MainActor () async -> (password: String, notice: String?),
        finish: @MainActor (HotspotPasswordField.Read, (password: String, notice: String?)) -> HotspotPasswordField.ReadAnswer
    ) async {
        var answer = await first()
        var request = request
        while case let .readAgain(next) = finish(request, answer) {
            request = next
            answer = await again()
        }
    }

    /// A prompt-free load: the password for the field, or an empty field
    /// and a notice saying why it cannot be shown.
    static func loadedPassword(_ load: () async throws -> String?) async -> (password: String, notice: String?) {
        do {
            return (try await load() ?? "", nil)
        } catch let error as KeychainError {
            return ("", error.problem.settingsNotice)
        } catch {
            return ("", HotspotPasswordProblem.error(error.localizedDescription).settingsNotice)
        }
    }

    /// The notice under the password field for the hotspot `ssid`
    /// configured now. A problem the failover reports about that hotspot
    /// shows as it is. A report about another SSID, one edited away since,
    /// does not apply, and a cleared report is not taken as "readable": it
    /// also clears when the session ends. Then the keychain is read again,
    /// without a prompt, and the notice says what that read finds. The
    /// field is left as the user has it, and the reread is a peek: a load
    /// would make an SSID typed since then the account a save moves the
    /// password from, and the old SSID's item would stay behind.
    static func hotspotNotice(reported: HotspotPasswordReport?, ssid: String, reread: () async throws -> String?) async -> String? {
        if let problem = reported?.problem(for: ssid) { return problem.settingsNotice }
        return await loadedPassword(reread).notice
    }

    /// Saves, or clears for an empty field. The button shows "Saving..."
    /// until the keychain answers; one save at a time.
    private func savePassword() {
        guard hotspot.startSave() else { return }
        if !HotspotSSID.normalized(manager.config.hotspotSSID).isEmpty {
            locationPermission.requestWhenInUse()
        }
        let password = hotspot.password
        Task {
            let outcome = await Self.storePassword(password, in: secrets)
            let recheck = hotspot.finishSave(outcome, ssid: manager.config.hotspotSSID)
            // The failover's report first, so the recheck reads it as the
            // save left it.
            Self.passwordStored(outcome, configuredSSID: manager.config.hotspotSSID, services: manager.services)
            if let recheck { recheckPassword(recheck) }
        }
    }

    /// A save or clear answered. The failover's report goes, and the next
    /// outage notifies afresh, unless the report is about the hotspot
    /// configured now and the save neither stored for it nor removed its
    /// item (`HotspotPasswordReport.stands`).
    static func passwordStored(_ outcome: HotspotStoreOutcome, configuredSSID: String, services: AppServices?) {
        guard case let .stored(stored) = outcome else { return }
        services?.hotspotPasswordChanged(stored.change, configuredSSID: configuredSSID)
    }

    /// Saves `password`, or clears the saved one when it is empty, and
    /// returns what was stored under which SSID and which loaded account
    /// it removed, or the notice for a failure. The store does the keychain work on `KeychainQueue`, so a
    /// save waiting on a keychain dialog waits there while the main actor
    /// (the battery floor, the deadline timer, End) carries on.
    static func storePassword(_ password: String, in secrets: any HotspotSecretStore) async -> HotspotStoreOutcome {
        do {
            let change = if password.isEmpty {
                try await secrets.delete()
            } else {
                try await secrets.save(password)
            }
            return .stored(.init(ssid: change.ssid, password: password, removed: change.removed))
        } catch {
            Log.error("could not save hotspot password: \(error.localizedDescription)")
            return .failed(notice: "Could not save the hotspot password: \(error.localizedDescription)")
        }
    }

    private func addTmuxTarget() {
        let t = newTmuxTarget.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        update { if !$0.tmuxTargets.contains(t) { $0.tmuxTargets.append(t) } }
        newTmuxTarget = ""
    }

    private var phoneSection: some View {
        Section {
            Text("Every notification Awake posts on the Mac is also sent to your phone through these services. Install the ntfy or Pushover app on the phone and subscribe; nothing passes through a server of Awake's own.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("ntfy topic (empty = off)", text: bind(\.ntfyTopic))
            TextField("ntfy server", text: bind(\.ntfyServer))
            HStack {
                SecureField("ntfy access token (\(PhoneSettingsModel.onFileLabel(phone.onFile.ntfyToken)))", text: $phone.ntfyToken)
            }
            Toggle("Pushover", isOn: bind(\.pushoverEnabled))
            SecureField("Pushover app token (\(PhoneSettingsModel.onFileLabel(phone.onFile.pushoverAppToken)))", text: $phone.pushoverAppToken)
            SecureField("Pushover user key (\(PhoneSettingsModel.onFileLabel(phone.onFile.pushoverUserKey)))", text: $phone.pushoverUserKey)
            HStack {
                Button("Save tokens to keychain") { Task { await phone.save(to: phoneSecrets) } }
                    .disabled(phone.busy || (phone.ntfyToken.isEmpty && phone.pushoverAppToken.isEmpty && phone.pushoverUserKey.isEmpty))
                Button("Remove tokens") { Task { await phone.clear(in: phoneSecrets) } }
                    .disabled(phone.busy || phone.onFile == .none)
                Spacer()
                Button("Send test alert") { Task { await phone.test(with: manager.phoneAlerts) } }
                    .disabled(phone.busy || (manager.config.ntfyTopic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !manager.config.pushoverEnabled))
            }
            if let notice = phone.notice {
                Text(notice).font(.caption).foregroundStyle(.orange)
            }
            Toggle("Post a summary when a session ends", isOn: bind(\.sessionSummary))
            Stepper(value: statusPort, in: 0...65535, step: 1) {
                LabeledContent("Local status endpoint port", value: manager.config.statusPort == 0 ? "off" : "\(manager.config.statusPort)")
            }
            Text("The menu's status is always written to Application Support/Awake/status.json. With a port set it is also served on http://127.0.0.1:<port>/status.json (this Mac only) for Raycast or SketchyBar; takes effect at the next session start.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Tokens are kept in the login keychain, never in config.json. A topic on ntfy.sh is public to anyone who guesses its name: use a long random one, or a reserved topic with an access token.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Phone alerts")
        }
        .task { await phone.load(from: phoneSecrets) }
    }

    // MARK: Leases (phase 4)

    private var leaseCap: Binding<Int> {
        Binding(get: { manager.config.leaseCapHours }, set: { v in update { $0.leaseCapHours = min(max(v, Config.leaseCapRange.lowerBound), Config.leaseCapRange.upperBound) } })
    }

    private var leaseGrace: Binding<Int> {
        Binding(get: { manager.config.leaseGraceMinutes }, set: { v in update { $0.leaseGraceMinutes = min(max(v, Config.leaseGraceRange.lowerBound), Config.leaseGraceRange.upperBound) } })
    }

    private var leaseSection: some View {
        Section {
            Text("Agents and scripts can ask for awake time themselves: `awake lease --for 2h --reason \"refactor billing\"`, or the same as an MCP tool (`awake mcp`). The Mac stays awake while any lease is held. The battery and heat rules above still end a session whatever leases say.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Toggle("Honour leases", isOn: bind(\.leasesEnabled))
            Toggle("A lease may start a session", isOn: bind(\.leasesMayStartSession))
                .disabled(!manager.config.leasesEnabled)
            Stepper(value: leaseCap, in: Config.leaseCapRange) {
                LabeledContent("Leases hold the Mac for at most", value: "\(manager.config.leaseCapHours) h")
            }
            .disabled(!manager.config.leasesEnabled)
            Stepper(value: leaseGrace, in: Config.leaseGraceRange) {
                LabeledContent("End after the last lease", value: manager.config.leaseGraceMinutes == 0 ? "at once" : "\(manager.config.leaseGraceMinutes) min later")
            }
            .disabled(!manager.config.leasesEnabled)
            Toggle("Notify when a lease is granted and when the last one is released", isOn: bind(\.leaseNotifications))
                .disabled(!manager.config.leasesEnabled)
            Text("The cap counts from when a lease was made, and from the first lease of a session for all of them together. A session you started is never cut short by leases; one that only leases were holding ends that long after the last is released or expires. Ending a session by hand revokes its leases.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let leases = manager.leases, !leases.held.isEmpty {
                ForEach(leases.menuLines(now: Date()), id: \.self) { line in
                    Text(line.trimmingCharacters(in: .whitespaces))
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }
            HStack {
                Button("Install `awake` command") {
                    switch CommandLink.install() {
                    case let .success(installed):
                        commandLinkNotice = installed.message
                        commandLinkFailed = false
                    case let .failure(failure):
                        commandLinkNotice = failure.localizedDescription
                        commandLinkFailed = true
                    }
                }
                Spacer()
            }
            if let commandLinkNotice {
                Text(commandLinkNotice)
                    .font(.caption)
                    .foregroundStyle(commandLinkFailed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .textSelection(.enabled)
            } else {
                Text("Links the command inside Awake.app into /usr/local/bin, or ~/.local/bin when that needs a password. Leases are files in \(manager.paths.leasesDirectory.path).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Leases")
        }
    }

    private var appSection: some View {
        Section("App") {
            Toggle("Launch at login", isOn: launchAtLogin)
            loginItemNote
            LabeledContent("Config") {
                Text(manager.paths.configFile.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            LabeledContent("Version") {
                Text(AppBuild.current.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            releaseCheck
            if LidSimulationBuild.isCompiledIn {
                Text(LidSimulationBuild.marker)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// The update check: one request to GitHub's releases list per click,
    /// and the report under the buttons. It opens the releases page and
    /// installs nothing; the installer run again is the upgrade.
    @ViewBuilder
    private var releaseCheck: some View {
        HStack {
            Button(releases.state == .checking ? "Checking" : "Check for updates") { releases.check() }
                .disabled(releases.state == .checking)
            Button("Open releases page") { NSWorkspace.shared.open(GitHubReleaseFetcher.releasesPage) }
        }
        switch releases.state {
        case .idle:
            Text("Asks GitHub when you click, and installs nothing. To upgrade, run the installer again.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .checking:
            EmptyView()
        case let .checked(report):
            Text(report.summary)
                .font(.caption)
                .foregroundStyle(report.standing == .newerStableAvailable ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .textSelection(.enabled)
        case let .failed(reason):
            Text("Could not check: \(reason)")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    /// The switch shows what macOS has on file (`LoginItem.isRegistered`:
    /// enabled or waiting for approval), so a registration that an upgrade
    /// dropped reads as off even while config.json still says on, and a
    /// pending one can be withdrawn by turning the switch off; the note
    /// below explains the state.
    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { loginItem.isRegistered },
            set: { on in
                // Persist only what macOS accepted; a refused change leaves
                // the flag as it was and its error on screen.
                update { config in _ = loginItem.set(on, config: &config) }
            }
        )
    }

    /// One line under the switch: the last error, a pending approval with
    /// the button that opens Login Items, or a flag macOS no longer honours.
    @ViewBuilder
    private var loginItemNote: some View {
        if let error = loginItem.error {
            Text("Login item: \(error)").font(.caption).foregroundStyle(.red)
        } else if loginItem.needsApproval {
            HStack {
                Text("Waiting for approval in System Settings > General > Login Items. Turn the switch off to withdraw it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open Login Items") { loginItem.openLoginItems() }
            }
        } else if manager.config.launchAtLogin, !loginItem.isRegistered {
            Text("Login item: macOS reports it \(loginItem.status.description). Turn the switch on to register it again.")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    // MARK: Bundle id lists

    private func bundleList(
        title: String,
        items: [String],
        newValue: Binding<String>,
        add: @escaping (String) -> Void,
        remove: @escaping (String) -> Void
    ) -> some View {
        Group {
            Text(title).font(.headline)
            ForEach(items, id: \.self) { id in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(RunningApps.displayName(for: id))
                        Text(id).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    removeButton { remove(id) }
                }
            }
            HStack {
                TextField("Bundle identifier", text: newValue)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        let v = newValue.wrappedValue.trimmingCharacters(in: .whitespaces)
                        guard !v.isEmpty else { return }
                        add(v)
                        newValue.wrappedValue = ""
                    }
                Button("Add") {
                    let v = newValue.wrappedValue.trimmingCharacters(in: .whitespaces)
                    guard !v.isEmpty else { return }
                    add(v)
                    newValue.wrappedValue = ""
                }
                .disabled(newValue.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
                Menu("Add running app…") {
                    let apps = RunningApps.candidates(excluding: items)
                    if apps.isEmpty {
                        Text("No other apps running")
                    }
                    ForEach(apps, id: \.bundleID) { app in
                        Button(app.name) { add(app.bundleID) }
                    }
                }
                .fixedSize()
            }
        }
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Remove")
    }
}

/// Running apps offered by "Add running app…": everything with a bundle id
/// that is not Apple's own.
@MainActor
enum RunningApps {
    struct Entry: Hashable {
        let bundleID: String
        let name: String
    }

    static func candidates(excluding: [String]) -> [Entry] {
        let me = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        var out: [Entry] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, !id.hasPrefix("com.apple."), id != me,
                  app.activationPolicy != .prohibited,
                  !excluding.contains(id), !seen.contains(id) else { continue }
            seen.insert(id)
            out.append(Entry(bundleID: id, name: app.localizedName ?? id))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Name of a running app for a bundle id, or the last path component.
    static func displayName(for bundleID: String) -> String {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }),
           let name = app.localizedName {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }
}
