import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var ble: BLEManager
    @State private var keyInput = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Enabled", isOn: Binding(get: { ble.isEnabled },
                                                    set: { ble.setEnabled($0) }))
                    LabeledContent("Status", value: ble.status)
                    LabeledContent("Signal", value: ble.rssi.map { "\($0) dBm" } ?? "—")
                }

                Section {
                    SecureField("Paste Base64 key", text: $keyInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save key") {
                        if ble.setKey(base64: keyInput) { keyInput = "" }
                    }
                    .disabled(keyInput.isEmpty)
                } header: {
                    Text("Shared key")
                } footer: {
                    Text(ble.hasKey ? "Key saved."
                                    : "Paste the SecretBase64 value from the PC's config.json.")
                }

                Section {
                    Text("Leave the app in the background. If you swipe it away in the app switcher, it stops and the PC locks.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Proximity Lock")
        }
    }
}
