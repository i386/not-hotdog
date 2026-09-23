import SwiftUI
import PhotosUI
import UIKit

struct ContentView: View {
    private enum Phase: Equatable {
        case idle
        case analyzing
        case verdict(Verdict)
        case failed(String)
    }

    @StateObject private var camera = CameraController()
    @State private var phase: Phase = .idle
    @State private var showSettings = false
    @State private var pickedItem: PhotosPickerItem?
    @State private var cameraError: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch phase {
            case .idle, .analyzing:
                cameraLayer
            case .verdict, .failed:
                resultLayer
            }
        }
        .animation(.easeInOut(duration: 0.2), value: phase)
        .onAppear {
            camera.requestAccessAndStart()
            NotificationCenter.default.addObserver(forName: .cameraError, object: nil, queue: .main) { note in
                cameraError = (note.object as? LocalizedError)?.errorDescription ?? "Camera unavailable."
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { camera.requestAccessAndStart() }
            if newPhase == .background { camera.stop() }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: { Image(systemName: "gearshape.fill") }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .alert("Camera", isPresented: .init(get: { cameraError != nil }, set: { if !$0 { cameraError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(cameraError ?? "") }
    }

    // MARK: Camera + controls

    private var cameraLayer: some View {
        ZStack {
            if camera.isRunning {
                CameraPreview(session: camera.session)
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "camera.metering.unknown")
                        .font(.system(size: 44))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("Camera starting…")
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            VStack {
                Spacer()
                controlBar
            }
            if phase == .analyzing { analyzingOverlay }
        }
    }

    private var controlBar: some View {
        HStack {
            PhotosPicker(selection: $pickedItem, matching: .images) {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 26))
                    .foregroundStyle(.white)
                    .padding(18)
                    .background(.white.opacity(0.15), in: Circle())
            }
            .onChange(of: pickedItem) { _, item in
                guard let item else { return }
                Task { await classify(item: item) }
            }

            Button {
                camera.capturePhoto { data in Task { await classify(jpeg: data) } }
            } label: {
                Circle()
                    .strokeBorder(.white, lineWidth: 5)
                    .frame(width: 82, height: 82)
                    .overlay(Circle().fill(.white).frame(width: 66, height: 66))
            }
            .disabled(!camera.isRunning || phase == .analyzing)
        }
        .padding(.bottom, 42)
    }

    private var analyzingOverlay: some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            Text("Analyzing…")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(34)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 22))
    }

    // MARK: Result

    private var resultLayer: some View {
        VStack(spacing: 26) {
            switch phase {
            case .verdict(let verdict):
                Text(verdict.isHotDog ? "HOTDOG" : "NOT HOTDOG")
                    .font(.system(size: 52, weight: .heavy, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(verdict.isHotDog ? Color(red: 0.95, green: 0.26, blue: 0.22) : .white)
                    .padding(.horizontal, 24)

                VStack(spacing: 6) {
                    Text(String(format: "P(hot dog) = %.2f", verdict.probability))
                        .monospacedDigit()
                    Text(verdict.route == .direct
                        ? "direct image read · \(verdict.detail)"
                        : "vision caption → system one · \(verdict.detail)")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.65))
                    Text("\(verdict.latencyMS) ms")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.65))
                }
                .foregroundStyle(.white)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.yellow)
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
            default:
                EmptyView()
            }

            Button {
                phase = .idle
                camera.requestAccessAndStart()
            } label: {
                Text("Try again")
                    .font(.headline)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 34)
                    .padding(.vertical, 14)
                    .background(.white, in: Capsule())
            }
        }
    }

    // MARK: Classification

    private func classify(item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data),
              let jpeg = image.jpegData(compressionQuality: 0.85)
        else {
            phase = .failed("Could not read that photo.")
            return
        }
        await classify(jpeg: jpeg)
    }

    private func classify(jpeg: Data) async {
        phase = .analyzing
        do {
            let client = try Self.client()
            let verdict = try await client.classify(jpegData: jpeg)
            phase = .verdict(verdict)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    static func client() throws -> OpenJEVClient {
        let defaults = UserDefaults.standard
        return try OpenJEVClient(
            baseURL: defaults.string(forKey: AppSettings.baseURLKey) ?? AppSettings.defaultBaseURL,
            apiKey: defaults.string(forKey: AppSettings.apiKeyKey),
            mode: ClassifyMode(rawValue: defaults.string(forKey: AppSettings.modeKey) ?? "") ?? .auto,
            systemOneModel: defaults.string(forKey: AppSettings.systemOneModelKey) ?? AppSettings.defaultSystemOneModel,
            visionModel: defaults.string(forKey: AppSettings.visionModelKey) ?? AppSettings.defaultVisionModel,
            timeout: defaults.object(forKey: AppSettings.timeoutKey) as? Double ?? AppSettings.defaultTimeout
        )
    }
}
