import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.baseURLKey) private var baseURL = AppSettings.defaultBaseURL
    @AppStorage(AppSettings.apiKeyKey) private var apiKey = ""
    @AppStorage(AppSettings.modeKey) private var mode = ClassifyMode.auto.rawValue
    @AppStorage(AppSettings.systemOneModelKey) private var systemOneModel = AppSettings.defaultSystemOneModel
    @AppStorage(AppSettings.visionModelKey) private var visionModel = AppSettings.defaultVisionModel
    @AppStorage(AppSettings.timeoutKey) private var timeout = AppSettings.defaultTimeout
    @Environment(\.dismiss) private var dismiss

    @State private var systemOneCandidates: [ModelCardDTO] = []
    @State private var visionCandidates: [ModelCardDTO] = []
    @State private var discoverError: String?
    @State private var isDiscovering = false

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
                    if systemOneCandidates.contains(where: { $0.id == systemOneModel }) {
                        Picker("Serves /systemone", selection: $systemOneModel) {
                            ForEach(systemOneCandidates, id: \.id) { card in
                                Text(card.label).tag(card.id)
                            }
                        }
                    } else if !systemOneCandidates.isEmpty {
                        // A free-typed id the endpoint does not advertise: show the
                        // candidates instead of a Picker bound to an unknown tag.
                        Text("This endpoint does not advertise “\(systemOneModel)”. Candidates: "
                             + systemOneCandidates.map(\.id).joined(separator: ", "))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    TextField("Vision model (mesh mode)", text: $visionModel)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if visionCandidates.contains(where: { $0.id == visionModel }) {
                        Picker("Accepts images", selection: $visionModel) {
                            ForEach(visionCandidates, id: \.id) { card in
                                Text(card.label).tag(card.id)
                            }
                        }
                    }
                    Button {
                        Task { await discover() }
                    } label: {
                        HStack {
                            Image(systemName: "magnifyingglass")
                            Text(isDiscovering ? "Discovering…" : "Discover models")
                        }
                    }
                    .disabled(isDiscovering)
                    if let discoverError {
                        Text(discoverError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    Text(
                        "Discover reads /v1/models and lists the models that advertise the " +
                        "system_one capability (a node can serve more than one, e.g. Laya and " +
                        "DiffusionGemma). Upstream OpenJEV has no /v1/models — enter its model id by hand. "
                            + "Direct sends the photo to /v1/systemone with `images` (upstream OpenJEV). "
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

    /// GET /v1/models against the endpoint as currently configured. The
    /// capability filter is the server's own claim, not our guess: mesh-llm
    /// advertises "system_one" only when the loaded runtime can execute the
    /// endpoint (PR #2093), which is how Laya and DiffusionGemma both show up.
    private func discover() async {
        isDiscovering = true
        discoverError = nil
        defer { isDiscovering = false }
        do {
            let client = try OpenJEVClient(
                baseURL: baseURL,
                apiKey: apiKey,
                mode: ClassifyMode(rawValue: mode) ?? .auto,
                systemOneModel: systemOneModel,
                visionModel: visionModel,
                timeout: timeout
            )
            let all = try await client.models()
            systemOneCandidates = all.filter(\.supportsSystemOne)
            visionCandidates = all.filter(\.supportsVision)

            if all.isEmpty {
                discoverError = "This endpoint advertises no models (upstream OpenJEV has no /v1/models)."
                return
            }
            if systemOneCandidates.isEmpty {
                discoverError = "No model here advertises POST /systemone support."
            }
            if !systemOneCandidates.contains(where: { $0.id == systemOneModel }),
               let first = systemOneCandidates.first {
                systemOneModel = first.id
            }
            if !visionCandidates.contains(where: { $0.id == visionModel }),
               let first = visionCandidates.first {
                visionModel = first.id
            }
        } catch {
            discoverError = error.localizedDescription
        }
    }
}
