import Foundation

/// Smoke driver for the OpenJEV wire client. macOS-runnable (Foundation only).
///
/// Usage: smoke_test <base-url> <direct|mesh|error-images> [label]
/// Exits 0 when every assertion holds; non-zero with a diagnostic otherwise.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("SMOKE FAIL: \(message)\n").data(using: .utf8)!)
    exit(1)
}

func jpegPayload() -> Data {
    // Minimal deterministic 1x1 JPEG: the stub validates the data-URL shape, not pixels.
    let b64 = ("/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0a"
        + "HBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAA"
        + "AAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AVN//2Q==")
    guard let data = Data(base64Encoded: b64) else { fail("fixture b64 broken") }
    return data
}

func run(baseURL: String, expectation: String, label: String) async {
    let client: OpenJEVClient
    do {
        // auto everywhere: the fallback chain is the thing under test; the
        // error-images scenario pins .direct on its own client below.
        client = try OpenJEVClient(
            baseURL: baseURL,
            apiKey: nil,
            mode: .auto,
            systemOneModel: "openjev-latest",
            visionModel: "vision-family-stub",
            timeout: 10
        )
    } catch {
        fail("\(label): client init failed: \(error)")
    }
    let jpeg = jpegPayload()

    switch expectation {
    case "direct":
        // auto mode against an upstream personality: direct image read must win.
        do {
            let verdict = try await client.classify(jpegData: jpeg)
            guard verdict.route == .direct else { fail("\(label): route \(verdict.route) != direct") }
            guard abs(verdict.probability - 0.97) < 1e-9 else {
                fail("\(label): probability \(verdict.probability) != 0.97")
            }
            guard verdict.isHotDog else { fail("\(label): 0.97 must classify HOTDOG") }
            guard verdict.latencyMS >= 0 else { fail("\(label): latency negative") }
            print("PASS \(label): route=direct p=0.97 hotdog=true detail=\(verdict.detail) (\(verdict.latencyMS) ms)")
        } catch {
            fail("\(label): classify threw: \(error)")
        }
    case "mesh":
        // auto mode against the mesh personality: 501 images -> caption fallback -> text-only read.
        do {
            let verdict = try await client.classify(jpegData: jpeg)
            guard verdict.route == .mesh else { fail("\(label): route \(verdict.route) != mesh") }
            guard abs(verdict.probability - 0.93) < 1e-9 else {
                fail("\(label): probability \(verdict.probability) != 0.93")
            }
            guard verdict.isHotDog else { fail("\(label): 0.93 must classify HOTDOG") }
            guard !verdict.detail.isEmpty else { fail("\(label): caption detail empty") }
            print("PASS \(label): route=mesh p=0.93 hotdog=true caption=\(verdict.detail)")
        } catch {
            fail("\(label): classify threw: \(error)")
        }
    case "mesh-salad":
        // Negative case through the mesh path: stub answers 0.02 for a salad caption.
        do {
            _ = try await client.caption(jpegData: jpeg) // proves caption leg works
            let response = try await client.systemOne(state: "A bowl of salad.", images: [])
            let probability = try response.noul(forKey: OpenJEVClient.questionKey)
            guard Verdict.verdict(probability: probability) == false else {
                fail("\(label): 0.02 must classify NOT HOTDOG")
            }
            print("PASS \(label): mesh-salad p=\(probability) notHotdog=true")
        } catch {
            fail("\(label): mesh-salad threw: \(error)")
        }
    case "error-images":
        // Direct mode pinned against the text-only PoC: rejection must surface cleanly.
        do {
            let pinned = try OpenJEVClient(
                baseURL: baseURL, apiKey: nil, mode: .direct,
                systemOneModel: "openjev-latest", visionModel: "vision-family-stub", timeout: 10
            )
            _ = try await pinned.classify(jpegData: jpeg)
            fail("\(label): expected imagesUnsupported, got a verdict")
        } catch let error as ClassifyError {
            guard error.isImagesUnsupported else { fail("\(label): wrong error kind: \(error)") }
            print("PASS \(label): imagesUnsupported surfaced: \(error.localizedDescription)")
        } catch {
            fail("\(label): wrong error type: \(type(of: error)) \(error)")
        }
    case "discover":
        // GET /v1/models on a mesh node: the System One capability must be how the
        // client finds candidates (mesh-llm #2093), not a hardcoded id.
        do {
            let all = try await client.models()
            guard all.count == 3 else {
                fail("\(label): expected 3 advertised models, got \(all.map(\.id))")
            }
            let systemOne = try await client.systemOneModels().map(\.id)
            guard systemOne == ["diffusiongemma-26B-A4B-it-Q4_K_M"] else {
                fail("\(label): system-one models \(systemOne) != [diffusiongemma-26B-A4B-it-Q4_K_M]")
            }
            let vision = try await client.visionModels().map(\.id)
            guard vision == ["qwen3-vl-8b-instruct"] else {
                fail("\(label): vision models \(vision) != [qwen3-vl-8b-instruct]")
            }
            guard !systemOne.contains("qwen3-dense-0.6b"),
                  !vision.contains("qwen3-dense-0.6b") else {
                fail("\(label): a text-only model leaked into a capability filter")
            }
            guard let card = all.first(where: { $0.id == systemOne[0] }) else {
                fail("\(label): system-one model missing from the full list")
            }
            guard card.supportsSystemOne, !card.supportsVision else {
                fail("\(label): capability flags disagree for \(card.id)")
            }
            print("PASS \(label): system_one=[\(systemOne[0])] vision=[\(vision[0])] of \(all.count) models")
        } catch {
            fail("\(label): discovery threw: \(error)")
        }
    case "discover-absent":
        // Upstream OpenJEV has no /v1/models: a 404 must read as "nothing
        // advertised", not as a failed classification.
        do {
            let all = try await client.models()
            guard all.isEmpty else { fail("\(label): expected no advertised models, got \(all.map(\.id))") }
            let verdict = try await client.classify(jpegData: jpeg)
            guard verdict.route == .direct else { fail("\(label): route \(verdict.route) != direct") }
            print("PASS \(label): no /v1/models, direct read still works (p=\(verdict.probability))")
        } catch {
            fail("\(label): discovery-absent threw: \(error)")
        }
    case "laya-read":
        // A decision-only node: discover the loaded model, then run a text-only read
        // under the discovered id (the stub rejects ids it does not serve).
        do {
            let cards = try await client.systemOneModels()
            guard cards.count == 1, let card = cards.first else {
                fail("\(label): expected one System One model, got \(cards.map(\.id))")
            }
            let pinned = try OpenJEVClient(
                baseURL: baseURL, apiKey: nil, mode: .direct,
                systemOneModel: card.id, visionModel: "vision-family-stub", timeout: 10
            )
            let response = try await pinned.systemOne(state: "A hot dog with mustard.", images: [])
            let probability = try response.noul(forKey: OpenJEVClient.questionKey)
            guard abs(probability - 0.93) < 1e-9 else {
                fail("\(label): probability \(probability) != 0.93")
            }
            guard response.model == card.id else {
                fail("\(label): served model \(response.model ?? "nil") != discovered \(card.id)")
            }
            guard Verdict.verdict(probability: probability) else {
                fail("\(label): 0.93 must classify HOTDOG")
            }
            print("PASS \(label): discovered \(card.id) -> p=0.93 HOTDOG")
        } catch {
            fail("\(label): laya-read threw: \(error)")
        }
    case "laya-caption":
        // Mesh mode needs a caption model; a Laya-only node refuses chat completions.
        // The failure must name that, not surface a bare 501.
        do {
            let meshOnly = try OpenJEVClient(
                baseURL: baseURL, apiKey: nil, mode: .mesh,
                systemOneModel: "openjev-latest", visionModel: "mesh-llm-laya-322m", timeout: 10
            )
            _ = try await meshOnly.classify(jpegData: jpeg)
            fail("\(label): expected the caption leg to be refused")
        } catch let error as ClassifyError {
            guard error.isVisionUnavailable else {
                fail("\(label): wrong error kind: \(error) (\(error.isImagesUnsupported ? "imagesUnsupported" : "-"))")
            }
            guard error.localizedDescription.contains("/systemone") else {
                fail("\(label): message lost the culprit route: \(error.localizedDescription)")
            }
            print("PASS \(label): visionUnavailable surfaced: \(error.localizedDescription)")
        } catch {
            fail("\(label): wrong error type: \(type(of: error)) \(error)")
        }
    case "laya-auto":
        // The whole chain on a Laya-only node: direct -> 501 images -> caption -> refused.
        do {
            let direct = try OpenJEVClient(
                baseURL: baseURL, apiKey: nil, mode: .direct,
                systemOneModel: "openjev-latest", visionModel: "vision-family-stub", timeout: 10
            )
            do {
                _ = try await direct.classify(jpegData: jpeg)
                fail("\(label): direct mode should report images unsupported")
            } catch let error as ClassifyError where error.isImagesUnsupported {
                // expected: the decision backend is text-only, images are not involved
            }
            do {
                _ = try await client.classify(jpegData: jpeg)
                fail("\(label): auto mode should end in a caption refusal")
            } catch let error as ClassifyError where error.isVisionUnavailable {
                print("PASS \(label): direct=imagesUnsupported, auto=\(error.localizedDescription)")
            }
        } catch {
            fail("\(label): laya-auto threw: \(error)")
        }
    default:
        fail("unknown expectation \(expectation)")
    }

    // Threshold mapping sanity shared by every scenario.
    guard Verdict.verdict(probability: 0.5) == true, Verdict.verdict(probability: 0.4999) == false else {
        fail("\(label): threshold mapping wrong at 0.5")
    }
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    fail("usage: smoke_test <base-url> <direct|mesh|mesh-salad|error-images|discover|discover-absent|laya-read|laya-caption|laya-auto> [label]")
}
let label = args.count > 3 ? args[3] : args[2]

let semaphore = DispatchSemaphore(value: 0)
Task {
    await run(baseURL: args[1], expectation: args[2], label: label)
    semaphore.signal()
}
let outcome = semaphore.wait(timeout: .now() + 30)
guard outcome == .success else { fail("\(label): timed out after 30 s") }
print("SMOKE OK \(label)")
exit(0)
