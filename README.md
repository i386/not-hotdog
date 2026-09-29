# SeeFood — hotdog / not hotdog (OpenJEV × mesh-llm)

Jian Yang's app from *Silicon Valley*: point your phone at food, get **HOTDOG** or
**NOT HOTDOG**. SwiftUI iOS app speaking the OpenJEV "System One" wire API, with a
deployment story for both upstream OpenJEV and the mesh-llm port.

```
                     ┌────────────────────────────────────────────────┐
        photo (JPEG) │                    SeeFood.app                 │
        ┌────────────┴───────────────┐                                │
        ▼                            ▼                                │
  DIRECT route                MESH route (auto-fallback)               │
  POST /v1/systemone          POST /v1/chat/completions  ← vision cap  │
    { images: [data:...] }      { image_url part }                     │
  question: hotdog = noul           │ caption                          │
    "The photo shows a hot dog"   POST /v1/systemone (→ /systemone)    │
        │                         text-only noul read                  │
        ▼                            ▼                                │
  answers.hotdog.noul ≥ 0.5 → HOTDOG, else NOT HOTDOG                  │
  (route + probability + latency shown in the UI)                      │
```

## Why two routes

- **Upstream OpenJEV** (`razorback16/openjev`, Jev-compatible) accepts `images` on
  `POST /v1/systemone` — the photo goes in the read directly.
- **mesh-llm's merged OpenJEV PoC** (PR #1939, `c70a1341e` on main) is deliberately
  **text-only**: `crates/skippy-server/src/frontend/system_one.rs` rejects non-empty
  `images` with `501 unsupported_model_feature`, and the route is
  `/systemone` (no `/v1` prefix; `crates/openai-frontend/src/router.rs`). It does serve
  `image_url` chat parts on `/v1/chat/completions` (`crates/openai-frontend/src/hooks.rs`).

So **Auto mode** (default) tries direct first and falls back to caption-then-read when
the endpoint is a mesh-llm PoC. Both routes are also selectable manually.

### More than one System One model

mesh-llm main now serves System One from more than one backend, chosen from the
loaded model's GGUF architecture
(`crates/mesh-llm-host-runtime/src/runtime/local.rs`):

| backend | family | notes |
|---|---|---|
| `openjev` | DiffusionGemma | the 26B-A4B diffusion read; complete model on one lane |
| `laya` | Laya | decision-only native runtime (322M), no KV cache, CPU by default; serves `POST /systemone` and refuses every other OpenAI surface |

`GET /v1/models` advertises the capability per model — `capabilities` contains
`"system_one"` and `system_one_status` is `supported`/`likely`/`none`, claimed
only when the loaded runtime can actually execute the endpoint (mesh-llm #2093).
That is what **Discover models** reads.

A Laya-only node has no caption model: mesh mode will report
*"Vision caption unavailable: this Laya decision model only serves POST
/systemone"* rather than a bare 501 — point the vision model at a real vision
family, or use direct mode against upstream OpenJEV. Both were once one
hand-typed model id; the app no longer assumes that.

## Quick start

1. Open `SeeFood/SeeFood.xcodeproj` in **Xcode 16+** (project uses synchronized groups,
   deployment target iOS 17).
2. Run on a device for the camera, or the simulator and use the photo picker.
   Camera usage is described in `SeeFood/Info.plist` + target settings.
3. In the app: gear → set **Base URL** to your OpenJEV/mesh-llm endpoint, optional API
   key, pick mode. Defaults to `http://127.0.0.1:8080` (upstream OpenJEV's MLX default
   port; loopback HTTP is ATS-exempt — the Info.plist allows arbitrary loads so
   tailnet/LAN IPs work too).
4. On a mesh-llm endpoint, tap **Discover models**: the app reads `GET /v1/models`
   and lists the models that advertise the `system_one` capability, so whichever
   System One backend the node has loaded (DiffusionGemma, Laya, or both) becomes a
   picker selection instead of a hand-typed id. Upstream OpenJEV has no
   `/v1/models` — enter its model id by hand, as before.

## Backends

### Upstream OpenJEV (direct mode, real image reads)

- Apple silicon: clone [razorback16/openjev](https://github.com/razorback16/openjev),
  `OPENJEV_BACKEND=mlx` (4-bit DiffusionGemma, ~16 GB weights, no Docker/vLLM).
- Or the free hosted endpoint `https://api.codiv.ai/v1/systemone` with a Codiv key.
- Model id: `openjev-latest` (default).

### mesh-llm (mesh mode, works with the PoC today)

Needs one deployment serving:

1. a vision family on `/v1/chat/completions` that accepts `image_url` content parts
   (caption step), and
2. `family-diffusion-gemma` (`registry.json`: `diffusiongemma-26B-A4B-it-Q4_K_M`,
   16.8 GB, system-one capability tag) on a single Skippy worker for `/systemone`
   (the PoC refuses split/downstream deployments).

Tap **Discover models** and the app fills both: **System One model** from the
models advertising `system_one` (a Laya node advertises its own id; mesh-llm also
accepts `openjev-latest` as an alias) and **Vision model** from the models
advertising `vision`. The app follows the PoC's `/systemone` route automatically.

Known gap (candidate mesh-llm issue): System One image support in the native op, and
aligning the route to `/v1/systemone`. Until then the mesh path classifies from a
vision caption — see the trade-off note in
`RESEARCH/OPENJEV_NOT_HOTDOG_FEASIBILITY_2026_09_24.md` in the agent workspace.

### Contract stub (no model needed)

`backend/stub_server.py` emulates three personalities — `upstream`, `mesh`
(DiffusionGemma), `laya` (decision-only) — and **validates request shapes**
(data-URL images, `noul` question shape, `image_url` chat parts, route presence,
`/v1/models` cards, and that the requested model id is one the deployment serves):

```bash
backend/run_smoke.sh          # builds the client with swiftc, runs 9 scenarios
```

## Wire contract

| Piece | Upstream OpenJEV | mesh-llm PoC (origin/main) |
|---|---|---|
| System One route | `POST /v1/systemone` | `POST /systemone` (`/v1/systemone` → 404) |
| Request | `{model, state, questions, images?}` | same struct (`system_one.rs` in `crates/openai-frontend`), `images` rejected |
| Images | ≤ 8 × `data:image/*;base64`, 5 MB, ≈280 tok each | — (501 `unsupported_model_feature`) |
| Answer envelope | `{model, answers, usage}` | identical |
| noul answer | `answers.hotdog.noul = P(yes)` | `{type:"noul", noul}` (type tag tolerated by the client) |
| Errors | 400/422 FastAPI-ish | `{"error":{message,type,code}}` (`errors.rs`) |
| Chat | OpenAI-style, model `diffusiongemma-26b` | OpenAI-style, `image_url` parts handled (`hooks.rs`); a decision-only model (Laya) refuses it with 501 |
| Model list | absent (`/v1/models` → 404) | `GET /v1/models`, `capabilities` + `system_one_status` per model (#2093) |

The client decodes both answer styles and both error envelopes, and treats
`404` as "try the other route" and `images`-mentioning unsupported errors as "fall
back to mesh mode".

## Verification status (2026-09-29)

- `backend/run_smoke.sh`: **all 9 scenarios green** on this machine
  (Apple Swift 6.4, arm64, macOS 27) against the contract stubs:
  1. auto vs upstream → direct image read, `p=0.97` → HOTDOG
  2. auto vs mesh PoC → `/v1/systemone` 404 → `/systemone` 501 images → caption →
     `/systemone` 200 `p=0.93` → HOTDOG (full fallback chain in the request log)
  3. mesh salad caption → `p=0.02` → NOT HOTDOG
  4. direct pinned vs mesh PoC → clean `imagesUnsupported` surfacing
  5. `/v1/models` discovery → exactly one System One model, one vision model, and
     the text-only third entry excluded from both filters
  6. endpoint without `/v1/models` (upstream) → empty list, classification unaffected
  7. decision-only node (Laya) → the discovered id drives a text-only read on
     `/systemone`, `p=0.93`
  8. decision-only node → the caption leg is refused by name (`visionUnavailable`,
     message names `POST /systemone`)
  9. auto chain on that node → `imagesUnsupported` from direct, caption refusal from
     the fallback
- The discovery scenario is **falsified, not just green**: with the stub's
  `system_one` capability removed, scenario 5 fails
  (`system-one models [] != [diffusiongemma-26B-A4B-it-Q4_K_M]`), so it is testing
  the capability claim rather than a hardcoded list.
- The mesh/laya stubs reject model ids they do not serve (plus mesh-llm's alias
  list), so a client that ignores discovery fails the run.
- `project.pbxproj` and `Info.plist`: `plutil -lint` OK; every Swift source
  `swiftc -parse` clean.
- **Not compiled:** the SwiftUI layer (`SeeFoodApp`, `ContentView`, `Camera`,
  `SettingsView`) — the build machine has no Xcode and no iOS SDK, only
  CommandLineTools, so the UI can only be syntax-checked here. Expect first-compile
  nits there; the wire layer it calls is the tested part.

## Repo layout

```
SeeFood/
  SeeFood.xcodeproj/         hand-written project (synchronized groups)
  SeeFood/
    SeeFoodApp.swift         entry
    ContentView.swift        camera / picker / verdict UI
    Camera.swift             AVFoundation capture + preview
    SettingsView.swift       endpoint, key, mode, models
    OpenJEVClient.swift      wire client (Foundation-only, shared with tests)
    WireModels.swift         tolerant decoders (Foundation-only)
    AppSettings.swift        keys + defaults
    Info.plist, Assets.xcassets
backend/
  stub_server.py             upstream / mesh contract stub
  main.swift + run_smoke.sh  smoke driver
```
