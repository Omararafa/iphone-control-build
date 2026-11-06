// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct GlassesView: View {
    @ObservedObject private var bridge = GlassesBridge.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage("keepAliveAudio") private var keepAliveAudio = true
    var body: some View {
        NavigationStack {
            Form {
                Section("iPhone on your glasses") {
                    Text(bridge.status)
                    if bridge.live { Text("Frames: \(bridge.frames) · Controls: \(bridge.controls)").font(.caption).monospacedDigit() }
                    Text("View and control this iPhone from Glasscast. No AI account is needed.").font(.footnote).foregroundStyle(.secondary)
                }
                if let code = bridge.pairingCode {
                    Section("Compare with your glasses") {
                        Text(code).font(.largeTitle.monospacedDigit())
                        Text("Approve only if the same six digits appear on your glasses.")
                        Button("The codes match — pair glasses") { bridge.approvePair() }
                        Button("Reject", role: .destructive) { bridge.rejectPair() }
                    }
                }
                if bridge.needsShareApproval {
                    Section("Allow this session?") {
                        Text("Your paired glasses will see the screen and can tap, swipe and type. Keep your iPhone unlocked. Use Stop here to end access.")
                        Button("Share screen and allow control") { bridge.approveSharing() }
                        Button("Decline", role: .cancel) { bridge.declineSharing() }
                    }
                }
                if let code = bridge.registrationCode {
                    Section("Server registration") {
                        Text(code).font(.title.monospacedDigit())
                        Text("Approve iPhone Glasses in the Glasscast server pairing window.")
                    }
                }
                Section("Connection") {
                    TextField("https://your-glasscast-server", text: $bridge.relayURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).disabled(bridge.running)
                    Toggle("Keep running while using other apps", isOn: $keepAliveAudio).disabled(bridge.running)
                    Text("Uses silent audio during the session. LocalDevVPN must stay on.").font(.footnote).foregroundStyle(.secondary)
                    if bridge.running {
                        Button("Stop", role: .destructive) { bridge.stop() }
                    } else { Button("Start") { bridge.start() } }
                }
                if bridge.running && !bridge.live {
                    Section("If the glasses show a connect code") {
                        TextField("ABC-DEF", text: $bridge.claimCode).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        Button("Connect to these glasses") { bridge.claim() }
                    }
                }
                Section("Controls in this test build") {
                    Text("Taps, swipes, Home and English keyboard text. Back is an edge swipe; Apps uses a double Home press. Drag is sent on release. App switching, Send, Backspace and non-English typing are not supported yet.")
                        .font(.footnote)
                    Text("Build: iPhone Glasses 1").font(.caption).foregroundStyle(.secondary)
                    Button("Forget paired glasses", role: .destructive) { bridge.forgetGlasses() }
                }
            }
            .navigationTitle("Glasses")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
