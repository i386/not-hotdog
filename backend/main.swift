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
    default:
        fail("unknown expectation \(expectation)")
    }

    // Threshold mapping sanity shared by every scenario.
    guard Verdict.verdict(probability: 0.5) == true, Verdict.verdict(probability: 0.4999) == false else {
        fail("\(label): threshold mapping wrong at 0.5")
    }
}

let args = CommandLine.arguments
guard args.count >= 3 else { fail("usage: smoke_test <base-url> <direct|mesh|mesh-salad|error-images> [label]") }
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
