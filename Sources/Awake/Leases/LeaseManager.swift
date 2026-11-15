import AwakeLeaseKit
import Foundation
import Observation

/// Phase 4: agents ask for awake time.
///
/// A lease is a file in Application Support/Awake/leases (`Lease`). While
/// any valid lease is there, a session runs: one is started if none is
/// (`Config.leasesMayStartSession`), and its end is the later of the end
/// it would have anyway and the last lease's expiry plus the grace, capped
/// by `Config.leaseCapHours` and `Config.maxDuration`. When the last lease
/// is released or expires, a session that only leases were holding ends
/// after `Config.leaseGraceMinutes` with `EndReason.leasesReleased`; a
/// session the user started goes back to the end the user chose, never
/// before it.
///
/// The manager decides and the session carries it out: every change is a
/// new end time written to session.json through `SessionManager.moveEnd`,
/// the same journal the timer and the recovery agent read. So a crash
/// after a release still ends the session on time, and the battery and
/// heat floors, which end the session themselves, need no lease rule of
/// their own: they win because nothing here can stop an end.
///
/// A session that ends for any reason but the leases themselves or a quit
/// takes its leases with it: the files are deleted. Otherwise the lease of
/// an agent that is still running would start the next session the moment
/// the user, the cap or the battery floor ended this one.
@MainActor
@Observable
final class LeaseManager {
    /// The valid leases as of the last pass, oldest first.
    private(set) var held: [Lease] = []

    static let grantedTitle = "Lease granted"
    static let lastReleasedTitle = "Last lease released"
    static let revokedTitle = "Leases revoked"
    /// The backstop for a directory event that never came, and how often
    /// `until` conditions are looked at.
    static let pollInterval: TimeInterval = 30
    /// A file that is not a lease is deleted once it is this old. Younger,
    /// it may still be being written by a program that does not rename
    /// into place.
    static let rejectedFileAge: TimeInterval = 10

    @ObservationIgnored private weak var manager: SessionManager?
    @ObservationIgnored private let store: LeaseStore
    @ObservationIgnored private let stateFile: URL
    @ObservationIgnored private let notifier: any Notifying
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private let processLookup: @Sendable (Int32) -> LeaseProcessLookup
    @ObservationIgnored private let tmux: LeaseTmux.Runner
    @ObservationIgnored private let watcher: (any LeaseDirectoryWatching)?

    @ObservationIgnored private(set) var state = LeaseState()
    @ObservationIgnored private var savedState: LeaseState?
    /// When each lease's `until` condition was first seen finished.
    @ObservationIgnored private var finishedSince: [UUID: Date] = [:]
    /// Leases a start was already tried for, or that outlived a session's
    /// end. Only a lease not in here starts a session, so a start that
    /// fails is not tried again every 30 s.
    @ObservationIgnored private var startTried: Set<UUID> = []
    /// Conditions already reported as unreadable, and files already
    /// reported as too many, so each is logged once.
    @ObservationIgnored private var reportedUnknown: Set<UUID> = []
    @ObservationIgnored private var reportedOverflow = false
    @ObservationIgnored private var lastWrittenStatus: [String] = []

    @ObservationIgnored private var syncTail: Task<Void, Never>?
    @ObservationIgnored private var syncQueued = false
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var wakeTimer: Timer?
    @ObservationIgnored private(set) var running = false

    init(
        manager: SessionManager,
        store: LeaseStore? = nil,
        notifier: any Notifying,
        clock: @escaping @Sendable () -> Date = { Date() },
        processLookup: @escaping @Sendable (Int32) -> LeaseProcessLookup = { LeaseProcessProbe.lookup(pid: $0) },
        tmux: @escaping LeaseTmux.Runner = LeaseTmux.liveRunner,
        watcher: (any LeaseDirectoryWatching)? = nil
    ) {
        self.manager = manager
        self.store = store ?? LeaseStore(directory: manager.paths.leasesDirectory)
        self.stateFile = manager.paths.leaseStateFile
        self.notifier = notifier
        self.clock = clock
        self.processLookup = processLookup
        self.tmux = tmux
        self.watcher = watcher
        loadState()
    }

    // MARK: Lifecycle

    /// Begin watching the directory. Called once, after the launch
    /// reconcile, so a session found on disk is known before the first
    /// pass decides whether a lease has to start one.
    func start() {
        guard !running else { return }
        running = true
        do {
            try store.ensureDirectory()
        } catch {
            Log.error("leases: \(error.localizedDescription)")
        }
        watcher?.onChange = { [weak self] in self?.requestSync() }
        watcher?.watch(store.directory)
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.running else { return }
                self.watcher?.watch(self.store.directory)
                self.requestSync()
            }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        observeSession()
        requestSync()
    }

    func stop() {
        running = false
        watcher?.stop()
        watcher?.onChange = nil
        pollTimer?.invalidate()
        pollTimer = nil
        wakeTimer?.invalidate()
        wakeTimer = nil
    }

    /// A session the user starts or extends changes what the leases have
    /// to do; follow it without waiting for the poll.
    private func observeSession() {
        withObservationTracking {
            _ = manager?.session
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.running else { return }
                self.requestSync()
                self.observeSession()
            }
        }
    }

    /// Queue one pass behind the pass in flight. Requests that arrive
    /// while one is already waiting fold into it.
    func requestSync() {
        guard !syncQueued else { return }
        syncQueued = true
        let previous = syncTail
        syncTail = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            self.syncQueued = false
            await self.performSync()
        }
    }

    /// One pass, after any already queued. What tests call.
    func sync() async {
        requestSync()
        await syncTail?.value
    }

    // MARK: What the rest of the app reads

    func statuses(now: Date) -> [LeaseStatus] {
        let cap = manager?.config.leaseCapSeconds
        return held.map { LeaseStatus(lease: $0, now: now, capSeconds: cap) }
    }

    /// The menu's lease lines; empty with no leases.
    func menuLines(now: Date) -> [String] {
        LeaseStatus.menuLines(statuses(now: now), waiting: manager?.session == nil)
    }

    /// Why the session's own timer is ending it: because the leases that
    /// were all that held it are gone, or because its time is up.
    var timerEndReason: EndReason {
        guard let manager, let session = manager.session, LeaseState.same(state.sessionStartedAt, session.startedAt) else { return .timer }
        let now = clock()
        let cap = manager.config.leaseCapSeconds
        // Read live: the timer can fire before the pass that would have
        // dropped a lease that expired this second.
        let anyLive = manager.config.leasesEnabled && held.contains { LeaseRules.effectiveExpiry(of: $0, capSeconds: cap) > now }
        guard !anyLive, heldByLeasesOnly(session, now: now) else { return .timer }
        return .leasesReleased
    }

    /// The session exists, or is still running, only because of leases:
    /// they started it, or they stretched it past the end the user chose
    /// and that end has passed.
    private func heldByLeasesOnly(_ session: Session, now: Date) -> Bool {
        if state.startedByLeases { return true }
        guard let planned = state.plannedEnd else { return false }
        return session.endsAt.timeIntervalSince(planned) > 1 && now >= planned
    }

    // MARK: Session end

    /// Called by the session manager, inside its end, for the session that
    /// just ended. Nothing here may wait for the session manager.
    func sessionEnded(_ ended: Session?, reason: EndReason) {
        defer {
            state.clearSession()
            saveState()
            // Whatever is still on disk did not keep this session, and
            // must not be what starts the next one.
            startTried.formUnion(held.map(\.id))
            if running { requestSync() }
        }
        guard let ended, LeaseState.same(state.sessionStartedAt, ended.startedAt) else { return }
        guard reason != .quit, reason != .leasesReleased else { return }
        let honoured = Set(state.sessionLeaseIDs)
        let revoked = held.filter { honoured.contains(Lease.idText($0.id)) }
        guard !revoked.isEmpty else { return }
        for lease in revoked {
            do {
                try store.remove(id: lease.id)
                Log.info("lease \(Lease.idText(lease.id)) (\(LeaseRules.cleanOwner(lease.owner))) revoked: the session ended (\(reason.rawValue))")
            } catch {
                Log.error("lease \(Lease.idText(lease.id)) could not be revoked: \(error.localizedDescription)")
            }
        }
        held.removeAll { honoured.contains(Lease.idText($0.id)) }
        if manager?.config.leaseNotifications ?? true {
            notifier.post(title: Self.revokedTitle, body: Self.revokedBody(revoked, reason: SessionManager.reasonText(reason.rawValue)))
        }
    }

    static func revokedBody(_ leases: [Lease], reason: String) -> String {
        let owners = Array(Set(leases.map { LeaseRules.cleanOwner($0.owner) })).sorted().joined(separator: ", ")
        let count = leases.count == 1 ? "its lease was" : "its \(leases.count) leases were"
        return "The session ended (\(reason)), so \(count) revoked: \(owners). A new lease starts a new session."
    }

    // MARK: One pass

    private func performSync() async {
        guard let manager else { return }
        let config = manager.config
        let now = clock()
        var valid: [Lease] = []
        var recheckSoon = false

        if config.leasesEnabled {
            let scan = store.scan()
            for rejected in scan.rejected {
                if let modified = rejected.modifiedAt, now.timeIntervalSince(modified) < Self.rejectedFileAge, modified.timeIntervalSince(now) < Self.rejectedFileAge {
                    recheckSoon = true
                    continue
                }
                do {
                    try store.removeFile(rejected.url)
                    Log.error("leases: removed \(rejected.url.lastPathComponent): \(rejected.why)")
                } catch {
                    Log.error("leases: \(rejected.url.lastPathComponent) is \(rejected.why) and could not be removed: \(error.localizedDescription)")
                }
            }
            for lease in scan.leases {
                let name = "lease \(Lease.idText(lease.id)) (\(LeaseRules.cleanOwner(lease.owner)))"
                if let problem = LeaseRules.problem(with: lease, now: now) {
                    remove(lease, because: "\(name) removed: \(problem.text)", isError: problem != .expired)
                    continue
                }
                if LeaseRules.effectiveExpiry(of: lease, capSeconds: config.leaseCapSeconds) <= now {
                    remove(lease, because: "\(name) removed: it reached the \(config.leaseCapHours) h cap on a lease")
                    continue
                }
                if let until = lease.until {
                    switch await conditionState(until) {
                    case .busy:
                        finishedSince[lease.id] = nil
                        reportedUnknown.remove(lease.id)
                    case .finished:
                        let since = finishedSince[lease.id] ?? now
                        finishedSince[lease.id] = since
                        if now.timeIntervalSince(since) >= TimeInterval(max(lease.graceSeconds, 0)) {
                            remove(lease, because: "\(name) released: \(until.summary) has finished")
                            continue
                        }
                    case let .unknown(why):
                        // Unknown is not finished: the lease stays until
                        // its expiry, which is what bounds it.
                        if reportedUnknown.insert(lease.id).inserted {
                            Log.error("\(name): \(until.summary) could not be checked (\(why)); the lease is kept until it expires")
                        }
                    }
                }
                valid.append(lease)
            }
            if valid.count > LeaseRules.maximumHeld {
                if !reportedOverflow {
                    reportedOverflow = true
                    Log.error("leases: \(valid.count) lease files; only the oldest \(LeaseRules.maximumHeld) are honoured")
                }
                valid = Array(valid.prefix(LeaseRules.maximumHeld))
            } else {
                reportedOverflow = false
            }
        }

        let ids = Set(valid.map(\.id))
        finishedSince = finishedSince.filter { ids.contains($0.key) }
        reportedUnknown.formIntersection(ids)
        startTried.formIntersection(ids)
        held = valid

        announce(valid, config: config, now: now)
        await apply(now: now)
        saveState()
        writeStatusIfChanged(now: now)
        scheduleWake(now: now, soon: recheckSoon)
    }

    /// Deletes the lease's file unless it has been rewritten since it was
    /// read: an extend that lands between the read and the delete must not
    /// lose the lease it just extended.
    private func remove(_ lease: Lease, because line: String, isError: Bool = false) {
        if let current = store.load(id: lease.id), current != lease {
            Log.info("lease \(Lease.idText(lease.id)) changed while it was being read; left for the next pass")
            requestSync()
            return
        }
        do {
            try store.remove(id: lease.id)
            if isError { Log.error(line) } else { Log.info(line) }
        } catch {
            Log.error("\(line), but the file could not be deleted: \(error.localizedDescription)")
        }
    }

    private enum ConditionState {
        case busy
        case finished
        case unknown(String)
    }

    private func conditionState(_ until: LeaseUntil) async -> ConditionState {
        switch until {
        case let .pid(process), let .command(process, _):
            switch LeaseProcessProbe.isRunning(process, lookup: processLookup) {
            case true?: return .busy
            case false?: return .finished
            case nil: return .unknown("the process table could not be read")
            }
        case let .tmux(pane):
            let runner = tmux
            let lookup = processLookup
            // tmux is a child process; its answer is waited for off the
            // main actor.
            let state = await Task.detached { LeaseTmux.state(of: pane, runner: runner, processLookup: lookup) }.value
            switch state {
            case .busy: return .busy
            case .finished: return .finished
            case let .unknown(why): return .unknown(why)
            }
        }
    }

    // MARK: Notifications

    private func announce(_ leases: [Lease], config: Config, now: Date) {
        let known = Set(state.announced)
        let current = Set(leases.map { Lease.idText($0.id) })
        for lease in leases where !known.contains(Lease.idText(lease.id)) {
            state.announced.append(Lease.idText(lease.id))
            Log.info("lease \(Lease.idText(lease.id)) granted to \(LeaseRules.cleanOwner(lease.owner)) (\(lease.source.rawValue)) until \(lease.expiresAt.formatted(.iso8601))\(lease.until.map { ", or until \($0.summary) finishes" } ?? "")")
            guard config.leaseNotifications else { continue }
            let holdsNothing = manager?.session == nil && !config.leasesMayStartSession
            notifier.post(title: Self.grantedTitle, body: Self.grantedBody(lease, now: now, capSeconds: config.leaseCapSeconds, holdsNothing: holdsNothing))
        }
        // An id whose file is gone will not come back: ids are random.
        state.announced.removeAll { !current.contains($0) }
    }

    /// "claude: refactor billing. Expires at 14:32 (1h 12m), or when pid
    /// 4242 finishes."
    static func grantedBody(_ lease: Lease, now: Date, capSeconds: TimeInterval?, holdsNothing: Bool = false) -> String {
        let status = LeaseStatus(lease: lease, now: now, capSeconds: capSeconds)
        let who = status.reason.isEmpty ? status.owner : "\(status.owner): \(status.reason)"
        let at = status.expiresAt.formatted(date: .omitted, time: .shortened)
        let until = status.until.map { ", or when \($0) finishes" } ?? ""
        let waiting = holdsNothing ? " It holds nothing until you start a session." : ""
        return "\(who). Expires at \(at) (\(LeaseDuration.format(TimeInterval(status.remainingSeconds))))\(until).\(waiting)"
    }

    static func lastReleasedBody(graceSeconds: TimeInterval) -> String {
        graceSeconds < 60
            ? "The session only leases were holding ends now."
            : "Ending in \(Int(graceSeconds / 60)) min unless a new lease arrives."
    }

    // MARK: Applying the leases to the session

    private func apply(now: Date) async {
        guard let manager else { return }
        let config = manager.config

        if manager.session == nil {
            if state.sessionStartedAt != nil { state.clearSession() }
            guard !held.isEmpty, config.leasesMayStartSession, !manager.quitRequested, manager.pendingEnd == nil else { return }
            guard held.contains(where: { !startTried.contains($0.id) }) else { return }
            startTried.formUnion(held.map(\.id))
            // The first horizon is the owner's default duration, cut to
            // the cap; the leases stretch it from there.
            let duration = min(config.defaultPreset, config.leaseCapSeconds)
            state.startIntentAt = now
            saveState()
            Log.info("leases: starting a session for \(held.count) lease\(held.count == 1 ? "" : "s")")
            await manager.start(duration: duration)
            guard let started = manager.session else {
                state.startIntentAt = nil
                Log.error("leases: the session could not be started; the leases hold nothing until a new one arrives or you start a session")
                return
            }
            state.clearSession()
            state.sessionStartedAt = started.startedAt
            state.startedByLeases = true
            state.plannedEnd = started.endsAt
            state.appliedEnd = started.endsAt
            state.leaseEpoch = started.startedAt
            saveState()
        }

        guard let session = manager.session else { return }
        if !LeaseState.same(state.sessionStartedAt, session.startedAt) {
            // A session this manager has no record of. Leases started it
            // if the record of that start is all a crash left behind.
            let byLeases = state.startIntentAt.map { abs($0.timeIntervalSince(session.startedAt)) < 60 } ?? false
            state.clearSession()
            state.sessionStartedAt = session.startedAt
            state.startedByLeases = byLeases
            state.plannedEnd = session.endsAt
            state.appliedEnd = session.endsAt
            state.leaseEpoch = byLeases ? session.startedAt : nil
        } else if !LeaseState.same(state.appliedEnd, session.endsAt) {
            // Somebody else moved the end: the user added time. That end
            // is now the one they chose, and the session is theirs.
            state.plannedEnd = session.endsAt
            state.appliedEnd = session.endsAt
            if state.startedByLeases {
                state.startedByLeases = false
                Log.info("leases: time was added by hand; the session is now yours and ends no earlier than you chose")
            }
        }
        state.startIntentAt = nil
        guard let planned = state.plannedEnd else { return }

        let grace = config.leaseGraceSeconds
        let cap = config.leaseCapSeconds
        var target: Date
        if !held.isEmpty {
            let epoch = state.leaseEpoch ?? now
            state.leaseEpoch = epoch
            state.lastReleaseAt = nil
            let latest = held.map { LeaseRules.effectiveExpiry(of: $0, capSeconds: cap) }.max() ?? now
            let leaseEnd = min(latest.addingTimeInterval(grace), epoch.addingTimeInterval(cap))
            target = max(planned, leaseEnd)
            noteHeld()
        } else if heldByLeasesOnly(session, now: now) {
            if state.lastReleaseAt == nil {
                state.lastReleaseAt = now
                Log.info("leases: the last lease is gone; the session ends in \(Int(grace)) s unless a new one arrives")
                if config.leaseNotifications {
                    notifier.post(title: Self.lastReleasedTitle, body: Self.lastReleasedBody(graceSeconds: grace))
                }
            }
            target = min(session.endsAt, (state.lastReleaseAt ?? now).addingTimeInterval(grace))
        } else {
            // The user's session, with its own time still to run.
            target = planned
        }
        target = max(target, now)

        guard abs(target.timeIntervalSince(session.endsAt)) >= 1 else { return }
        if let end = await manager.moveEnd(to: target, from: session.endsAt) {
            state.appliedEnd = end
        }
    }

    /// The session's tally of leases, in lease-state.json and in the
    /// session report.
    private func noteHeld() {
        let before = (state.sessionLeaseIDs.count, state.maxHeld)
        var known = Set(state.sessionLeaseIDs)
        for lease in held where known.insert(Lease.idText(lease.id)).inserted {
            state.sessionLeaseIDs.append(Lease.idText(lease.id))
        }
        state.maxHeld = max(state.maxHeld, held.count)
        guard before != (state.sessionLeaseIDs.count, state.maxHeld) else { return }
        let granted = state.sessionLeaseIDs.count
        let most = state.maxHeld
        manager?.noteReport {
            $0.leasesGranted = granted
            $0.maxLeasesHeld = most
        }
    }

    // MARK: Persistence and timers

    private func loadState() {
        guard let manager else { return }
        do {
            state = try manager.store.read(LeaseState.self, from: stateFile) ?? LeaseState()
        } catch {
            Log.error("lease-state.json could not be read (\(error.localizedDescription)); starting without it")
            state = LeaseState()
        }
        savedState = state
    }

    private func saveState() {
        guard let manager, state != savedState else { return }
        do {
            try manager.store.write(state, to: stateFile)
            savedState = state
        } catch {
            Log.error("lease-state.json could not be written: \(error.localizedDescription)")
        }
    }

    private func writeStatusIfChanged(now: Date) {
        let signature = statuses(now: now).map { "\($0.id) \($0.expiresAt.timeIntervalSince1970)" }
        guard signature != lastWrittenStatus else { return }
        lastWrittenStatus = signature
        manager?.services?.writeStatus()
    }

    /// One timer for the next moment a lease can change by itself: an
    /// expiry, or the end of a grace. The poll would get there within 30 s
    /// anyway; this makes the notice and the new end prompt.
    private func scheduleWake(now: Date, soon: Bool) {
        wakeTimer?.invalidate()
        wakeTimer = nil
        guard running else { return }
        let cap = manager?.config.leaseCapSeconds
        var moments = held.map { LeaseRules.effectiveExpiry(of: $0, capSeconds: cap) }
        for lease in held {
            if let since = finishedSince[lease.id] {
                moments.append(since.addingTimeInterval(TimeInterval(max(lease.graceSeconds, 0))))
            }
        }
        if soon { moments.append(now.addingTimeInterval(Self.rejectedFileAge)) }
        guard let next = moments.min() else { return }
        let delay = max(next.timeIntervalSince(now), 0) + 0.5
        guard delay < Self.pollInterval else { return }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.requestSync() }
        }
        RunLoop.main.add(timer, forMode: .common)
        wakeTimer = timer
    }
}
