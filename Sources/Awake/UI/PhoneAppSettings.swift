import AppKit
import SwiftUI

/// The live part of Settings' "Phone app" section: where the server is
/// reachable, pairing, the paired phones, the Screen Recording grant and
/// the audit log. Reads `PhoneAppController`, which is observable, so
/// the lines follow the server without a refresh button.
struct PhoneAppSettings: View {
    let phone: PhoneAppController
    let auth: PhoneAuth
    let enabled: Bool

    @State private var notice: String?

    var body: some View {
        Group {
            status
            if enabled {
                pairing
                devices
            }
            screenRecording
            LabeledContent("Audit log") {
                Button("Reveal in Finder") { phone.revealAuditLog() }
            }
            Text("Every action a phone takes is written to Application Support/Awake/audit.log: when, which phone, what, and the result. The Mac cannot be unlocked from the phone.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let problem = notice ?? auth.storeProblem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
        }
        .task(id: enabled) { await phone.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await phone.refresh() }
        }
    }

    // MARK: Where it is reachable

    @ViewBuilder
    private var status: some View {
        LabeledContent("Status") {
            Text(phone.statusLine)
                .foregroundStyle(enabled && (!phone.tailscale.found || phone.listening.isEmpty) ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        if enabled {
            if phone.tailscale.found {
                LabeledContent("Tailscale address") {
                    Text(phone.tailscale.ipv4 ?? "").textSelection(.enabled)
                }
                LabeledContent("Open on the phone") {
                    Text(phone.primaryURL).textSelection(.enabled)
                }
                if phone.serve.httpsURL == nil {
                    Text("For HTTPS, which the phone needs for notifications and a full home-screen app, run this once in Terminal, then reopen this window:\n\(TailscaleCLI.serveCommand(port: phone.port))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    Text("tailscale serve is on: the phone uses the https address.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Install Tailscale on this Mac and on the phone and sign both in to the same tailnet. Until then the phone app answers only on this Mac, at \(phone.loopbackURL).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: Pairing

    @ViewBuilder
    private var pairing: some View {
        if let window = auth.pairingWindow {
            let url = phone.pairingURL(code: window.code)
            HStack(alignment: .top, spacing: 16) {
                if let qr = PhoneQR.image(for: url, side: 150) {
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 150, height: 150)
                        .accessibilityLabel("QR code for \(phone.primaryURL)")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Pairing code").font(.caption).foregroundStyle(.secondary)
                    Text(Self.spaced(window.code))
                        .font(.system(size: 34, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Self.expiry(window, now: context.date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .onChange(of: context.date) { auth.refreshPairing() }
                    }
                    Text("Scan the code with the phone's camera, or open \(phone.primaryURL) and type the code.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Cancel pairing") { auth.cancelPairing() }
                }
            }
        } else {
            LabeledContent("Pair a phone") {
                Button(StatusMenu.pairPhoneTitle) {
                    notice = nil
                    auth.beginPairing()
                }
            }
        }
    }

    static func spaced(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return code.prefix(3) + " " + code.suffix(3)
    }

    static func expiry(_ window: PhonePairing.Window, now: Date) -> String {
        let left = max(0, Int(window.expiresAt.timeIntervalSince(now).rounded(.up)))
        let tries = window.attemptsLeft == 1 ? "1 try" : "\(window.attemptsLeft) tries"
        return "Expires in \(left / 60):\(left % 60 < 10 ? "0" : "")\(left % 60). \(tries) left."
    }

    // MARK: Paired phones

    @ViewBuilder
    private var devices: some View {
        if auth.devices.isEmpty {
            LabeledContent("Paired phones", value: "none")
        } else {
            ForEach(auth.devices) { device in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                        Text(Self.deviceLine(device, now: Date()))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Forget") {
                        Task { notice = await auth.forget(id: device.id) }
                    }
                }
            }
            LabeledContent("\(auth.devices.count == 1 ? "1 phone" : "\(auth.devices.count) phones") paired") {
                Button("Forget all phones", role: .destructive) {
                    Task { notice = await auth.forgetAll() }
                }
            }
        }
    }

    static func deviceLine(_ device: PhoneDevice, now: Date) -> String {
        let paired = "paired \(device.createdAt.formatted(date: .abbreviated, time: .omitted))"
        guard let seen = device.lastSeenAt else { return paired }
        let ago = now.timeIntervalSince(seen)
        if ago < 90 { return "\(paired), connected now" }
        return "\(paired), last seen \(seen.formatted(.relative(presentation: .named)))"
    }

    // MARK: Screen Recording

    @ViewBuilder
    private var screenRecording: some View {
        LabeledContent("Screen Recording") {
            HStack {
                Text(phone.screenRecordingGranted ? "allowed" : "not allowed")
                    .foregroundStyle(phone.screenRecordingGranted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                if !phone.screenRecordingGranted {
                    Button("Ask") { phone.requestScreenRecording() }
                }
                Button("Open Privacy settings") { phone.openScreenRecordingPane() }
            }
        }
        if !phone.screenRecordingGranted {
            Text("The phone's screenshot needs Screen & System Audio Recording for Awake. macOS asks again after each reinstall, and Awake has to be reopened after you allow it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
