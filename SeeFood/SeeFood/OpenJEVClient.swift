import Foundation

// MARK: - Verdict

public enum ClassifyRoute: String, Codable {
    /// Photo sent directly to /v1/systemone with `images` (upstream OpenJEV contract).
    case direct
    /// Photo captioned by a vision model via /v1/chat/completions, caption judged by a
    /// text-only System One read (what mesh-llm's merged PoC supports today).
    case mesh
}

public struct Verdict: Equatable {
    public let isHotDog: Bool
    /// P(hot dog) from the noul read.
    public let probability: Double
    public let route: ClassifyRoute
    public let latencyMS: Int
    /// Caption (mesh route) or the served model name (direct route).
    public let detail: String

    public static func verdict(probability: Double, threshold: Double = 0.5) -> Bool {
        probability >= threshold
    }
}

// MARK: - Errors

public enum ClassifyError: LocalizedError, Equatable {
    case badURL(String)
    case http(status: Int, message: String)
    /// The endpoint answered that `images` are not supported (mesh-llm PoC today).
    case imagesUnsupported(message: String)
    case badResponse(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case let .badURL(text): return "Bad endpoint URL: \(text)"
        case let .http(status, message): return "HTTP \(status): \(message)"
        case let .imagesUnsupported(message): return message
        case let .badResponse(message): return "Unexpected response: \(message)"
        case let .network(message): return "Network error: \(message)"
        }
    }

    var isImagesUnsupported: Bool { if case .imagesUnsupported = self { return true }; return false }
}

// MARK: - Client

public enum ClassifyMode: String, CaseIterable, Codable {
    /// Try direct (images) first, fall back to mesh (caption) when rejected.
    case auto
    case direct
    case mesh
}

public final class OpenJEVClient {
    /// Base URL without path, e.g. "http://127.0.0.1:8080".
    public let baseURL: URL
    public let apiKey: String?
    public let mode: ClassifyMode
    public let systemOneModel: String
    public let visionModel: String
    public let session: URLSession

    public init(
        baseURL: String,
        apiKey: String? = nil,
        mode: ClassifyMode = .auto,
        systemOneModel: String = "openjev-latest",
        visionModel: String = "diffusiongemma-26b",
        timeout: TimeInterval = 30
    ) throws {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), let scheme = url.scheme,
              (scheme == "http" || scheme == "https"), let host = url.host(), !host.isEmpty
        else {
            throw ClassifyError.badURL(baseURL)
        }
        self.baseURL = url
        self.apiKey = (apiKey?.isEmpty == false) ? apiKey : nil
        self.mode = mode
        self.systemOneModel = systemOneModel
        self.visionModel = visionModel
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        session = URLSession(configuration: config)
    }

    // MARK: Public entry point

    public func classify(jpegData: Data) async throws -> Verdict {
        let started = Date()
        switch mode {
        case .direct:
            return try await directClassify(jpegData: jpegData, started: started)
        case .mesh:
            return try await meshClassify(jpegData: jpegData, started: started)
        case .auto:
            do {
                return try await directClassify(jpegData: jpegData, started: started)
            } catch let error as ClassifyError where error.isImagesUnsupported {
                return try await meshClassify(jpegData: jpegData, started: started)
            }
        }
    }

    // MARK: Direct route — upstream OpenJEV contract
    // curl ... -d '{"model":"openjev-latest", "state":"Look at the photo.",
    //        "images":["data:image/jpeg;base64,..."],
    //        "questions":{"hotdog":{"type":"noul","instructions":"The photo shows a hot dog"}}}'

    func directClassify(jpegData: Data, started: Date) async throws -> Verdict {
        let dataURL = Self.dataURL(jpegData: jpegData)
        let response = try await systemOne(
            state: "Look at the photo.",
            images: [dataURL]
        )
        let probability = try response.noul(forKey: Self.questionKey)
        return verdict(
            probability: probability, route: .direct,
            detail: response.model ?? systemOneModel, started: started
        )
    }

    // MARK: Mesh route — caption, then text-only System One read

    func meshClassify(jpegData: Data, started: Date) async throws -> Verdict {
        let caption = try await caption(jpegData: jpegData).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !caption.isEmpty else { throw ClassifyError.badResponse("vision model returned an empty caption") }
        let response = try await systemOne(
            state: caption,
            images: []
        )
        let probability = try response.noul(forKey: Self.questionKey)
        return verdict(probability: probability, route: .mesh, detail: caption, started: started)
    }

    func verdict(probability: Double, route: ClassifyRoute, detail: String, started: Date) -> Verdict {
        Verdict(
            isHotDog: Verdict.verdict(probability: probability),
            probability: probability,
            route: route,
            latencyMS: Int(Date().timeIntervalSince(started) * 1000),
            detail: detail
        )
    }

    // MARK: POST /v1/systemone (falls back to mesh-llm's /systemone on 404)

    public static let questionKey = "hotdog"

    func systemOne(state: String, images: [String]) async throws -> SystemOneResponseDTO {
        // Keep the request minimal for the mesh route: no images key at all when text-only.
        var body: [String: Any] = [
            "model": systemOneModel,
            "state": state,
            "questions": [
                Self.questionKey: [
                    "type": "noul",
                    "instructions": "The photo shows a hot dog",
                ]
            ],
        ]
        if !images.isEmpty { body["images"] = images }

        var lastError: ClassifyError?
        for path in ["/v1/systemone", "/systemone"] {
            do {
                return try await postSystemOne(path: path, body: body)
            } catch let error as ClassifyError {
                if case .http(let status, _) = error, status == 404 {
                    lastError = error
                    continue // try the mesh-llm route
                }
                throw error
            }
        }
        throw lastError ?? ClassifyError.badResponse("no systemone route answered")
    }

    private func postSystemOne(path: String, body: [String: Any]) async throws -> SystemOneResponseDTO {
        var request = URLRequest(url: try endpointURL(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            let details = Self.errorDetails(from: data, status: status)
            // mesh-llm origin/main system_one.rs rejects images with 501 and
            // code "unsupported_model_feature"; upstream returns 400 text.
            let mentionsImages = details.message.lowercased().contains("image")
            let unsupportedCode = details.code == "unsupported_model_feature"
            let lower = details.message.lowercased()
            let unsupportedText = lower.contains("not yet supported") || lower.contains("not supported")
            if mentionsImages, unsupportedCode || unsupportedText {
                throw ClassifyError.imagesUnsupported(message: details.message)
            }
            throw ClassifyError.http(status: status, message: details.message)
        }
        do {
            return try JSONDecoder().decode(SystemOneResponseDTO.self, from: data)
        } catch {
            throw ClassifyError.badResponse("undecodable systemone body: \(error)")
        }
    }

    // MARK: POST /v1/chat/completions — vision caption (mesh route)

    func caption(jpegData: Data) async throws -> String {
        let dataURL = Self.dataURL(jpegData: jpegData)
        let body: [String: Any] = [
            "model": visionModel,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": Self.captionPrompt],
                        ["type": "image_url", "image_url": ["url": dataURL]],
                    ],
                ]
            ],
            "max_tokens": 120,
        ]

        var request = URLRequest(url: try endpointURL(path: "/v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else { throw ClassifyError.http(status: status, message: Self.errorMessage(from: data, status: status)) }
        do {
            let decoded = try JSONDecoder().decode(ChatCompletionResponseDTO.self, from: data)
            guard let content = decoded.content, !content.isEmpty else {
                throw ClassifyError.badResponse("chat completion had no content")
            }
            return content
        } catch let error as ClassifyError {
            throw error
        } catch {
            throw ClassifyError.badResponse("undecodable chat completion body: \(error)")
        }
    }

    public static let captionPrompt = "Describe the food in this photo in one short sentence. Name the food."

    // MARK: Helpers

    func endpointURL(path: String) throws -> URL {
        guard let url = URL(string: baseURL.absoluteString + path) else {
            throw ClassifyError.badURL(baseURL.absoluteString + path)
        }
        return url
    }

    static func dataURL(jpegData: Data) -> String {
        "data:image/jpeg;base64,\(jpegData.base64EncodedString())"
    }

    /// Best-effort human message from OpenAI-style {"error":{...}}, FastAPI {"detail":...}
    /// or a plain-text 400 body.
    static func errorMessage(from data: Data, status: Int) -> String {
        errorDetails(from: data, status: status).message
    }

    static func errorDetails(from data: Data, status: Int) -> (message: String, code: String?) {
        if let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data),
           let message = envelope.message { return (message, envelope.code) }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let detail = object["detail"] {
                if let text = detail as? String { return (text, nil) }
                if let text = try? String(data: JSONSerialization.data(withJSONObject: detail), encoding: .utf8) { return (text, nil) }
            }
            if let text = object["message"] as? String { return (text, object["code"] as? String) }
        }
        return (String(data: data.prefix(300), encoding: .utf8) ?? "HTTP \(status)", nil)
    }
}
