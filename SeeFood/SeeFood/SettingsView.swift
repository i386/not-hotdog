import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.baseURLKey) private var baseURL = AppSettings.defaultBaseURL
    @AppStorage(AppSettings.apiKeyKey) private var apiKey = ""
    @AppStorage(AppSettings.modeKey) private var mode = ClassifyMode.auto.rawValue
    @AppStorage(AppSettings.systemOneModelKey) private var systemOneModel = AppSettings.defaultSystemOneModel
    @AppStorage(AppSettings.visionModelKey) private var visionModel = AppSettings.defaultVisionModel
    @AppStorage(AppSettings.timeoutKey) private var timeout = AppSettings.defaultTimeout
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Base URL", text: $baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API key (optional)", text: $apiKey)
                    Picker("Mode", selection: $mode) {
                        Text("Auto").tag(ClassifyMode.auto.rawValue)
                        Text("Direct (images)").tag(ClassifyMode.direct.rawValue)
                        Text("Mesh (caption)").tag(ClassifyMode.mesh.rawValue)
                    }
                    Stepper("Timeout: \(Int(timeout)) s", value: $timeout, in: 5...120, step: 5)
                }
                Section("Models") {
                    TextField("System One model", text: $systemOneModel)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Vision model (mesh mode)", text: $visionModel)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section {
                    Text(
                        "Direct sends the photo to /v1/systemone with `images` (upstream OpenJEV). "
                            + "Mesh captions the photo via /v1/chat/completions, then runs a text-only "
                            + "System One read — the path mesh-llm's PoC supports today. "
                            + "Auto tries direct first and falls back to mesh."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } header: {
                    Text("How it classifies")
                }
            }
            .navigationTitle("SeeFood Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
