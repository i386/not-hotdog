import Foundation

// MARK: - System One wire types
//
// Envelope per upstream OpenJEV README ("POST /v1/systemone: {state, model, questions} →
// {model, answers, usage}") and mesh-llm origin/main
// crates/openai-frontend/src/system_one.rs (SystemOneResponse { model, answers, usage }).
//
// Answer items are internally tagged with "type" on mesh-llm
// ({"type":"noul","noul":0.87}); upstream documents noul as returning {noul: P(yes)}.
// Decode tolerantly: "type" optional, unknown fields ignored.

public struct SystemOneUsageDTO: Decodable, Equatable {
    public let inputTokens: Int?
    public let outputTokens: Int?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens)
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens)
    }

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

public struct SystemOneAnswerDTO: Decodable, Equatable {
    public let type: String?
    /// P(yes) for noul answers.
    public let noul: Double?
    /// Selected label for choice answers.
    public let choice: String?
    public let confidence: Double?
}

public struct SystemOneResponseDTO: Decodable, Equatable {
    public let model: String?
    public let answers: [String: SystemOneAnswerDTO]
    public let usage: SystemOneUsageDTO?

    public func noul(forKey key: String) throws -> Double {
        guard let answer = answers[key] else {
            throw ClassifyError.badResponse("no answer for question key \(key) in \(answers.keys.sorted())")
        }
        guard let noul = answer.noul else {
            throw ClassifyError.badResponse("answer for \(key) has no noul value (type: \(answer.type ?? "?"))")
        }
        return noul
    }
}

// MARK: - Chat completions (caption) wire types

public struct ChatCompletionResponseDTO: Decodable {
    public struct Choice: Decodable {
        public struct Message: Decodable {
            public let role: String?
            public let content: String?
        }

        public let message: Message?
        public let finishReason: String?

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            message = try c.decodeIfPresent(Message.self, forKey: .message)
            finishReason = try c.decodeIfPresent(String.self, forKey: .finishReason)
        }

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    public let choices: [Choice]?

    public var content: String? { choices?.first?.message?.content }
}

// MARK: - Model list (/v1/models)
//
// mesh-llm origin/main advertises System One support on the model card
// (PR #2093, crates/mesh-llm-host-runtime/src/network/openai/response/models.rs):
//
//   {"id": "...", "display_name": "...", "object": "model", "owned_by": "mesh-llm",
//    "capabilities": ["text", "vision", "system_one"],
//    "system_one_status": "supported" | "likely" | "none", ...}
//
// The capability is claimed only when the loaded runtime can actually execute
// POST /systemone, so it is the honest discovery signal: on a node serving Laya
// (PR #2083) and on one serving DiffusionGemma alike.
//
// Upstream OpenJEV does not implement /v1/models; the client treats a 404 there
// as "this endpoint advertises nothing" rather than an error.

public struct ModelCardDTO: Decodable, Equatable {
    public let id: String
    public let displayName: String?
    public let ownedBy: String?
    public let capabilities: [String]?
    public let systemOneStatus: String?
    public let visionStatus: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        ownedBy = try c.decodeIfPresent(String.self, forKey: .ownedBy)
        capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities)
        systemOneStatus = try c.decodeIfPresent(String.self, forKey: .systemOneStatus)
        visionStatus = try c.decodeIfPresent(String.self, forKey: .visionStatus)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case ownedBy = "owned_by"
        case capabilities
        case systemOneStatus = "system_one_status"
        case visionStatus = "vision_status"
    }

    /// A model that serves `POST /systemone` on this deployment.
    public var supportsSystemOne: Bool {
        (capabilities?.contains("system_one") ?? false) || systemOneStatus == "supported"
    }

    /// A model that accepts `image_url` chat parts (the caption leg of mesh mode).
    public var supportsVision: Bool {
        (capabilities?.contains("vision") ?? false) || visionStatus == "supported"
    }

    /// "id — display name (system_one: supported)" for menus and logs.
    public var label: String {
        let name = (displayName?.isEmpty == false && displayName != id) ? " — \(displayName!)" : ""
        let status = systemOneStatus.map { " (system_one: \($0))" } ?? ""
        return id + name + status
    }
}

public struct ModelListDTO: Decodable {
    public let data: [ModelCardDTO]?
}

// MARK: - Error envelope (mesh-llm crates/openai-frontend/src/errors.rs ErrorBody)

public struct APIErrorEnvelope: Decodable {
    public struct Detail: Decodable {
        public let message: String?
        public let type: String?
        public let code: String?
    }

    public let error: Detail?

    public var message: String? { error?.message }
    public var code: String? { error?.code }
}
