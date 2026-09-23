import Foundation

/// Settings keys and defaults, Foundation-only so the wire-layer tests can share them.
enum AppSettings {
    static let baseURLKey = "seefood.baseURL"
    static let apiKeyKey = "seefood.apiKey"
    static let modeKey = "seefood.mode"
    static let systemOneModelKey = "seefood.systemOneModel"
    static let visionModelKey = "seefood.visionModel"
    static let timeoutKey = "seefood.timeout"

    /// Loopback upstream OpenJEV (`OPENJEV_BACKEND=mlx` defaults to :8080).
    static let defaultBaseURL = "http://127.0.0.1:8080"
    static let defaultSystemOneModel = "openjev-latest"
    /// mesh-llm serves the DiffusionGemma PoC under this id; captions come from the
    /// configured vision family instead.
    static let defaultVisionModel = "diffusiongemma-26b"
    static let defaultTimeout: Double = 30
}
