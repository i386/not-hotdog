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
