# Mara's 3D avatar plugin (mara-avatar)

Mara owns `zara-plugin/mara_avatar.py` and `renderer/`. Zara owns only the
generic service-plugin API. The avatar is an **optional presentation plugin**:
Zara works without Mara, Mara works without the avatar plugin, and Mara's
brain never touches renderer internals.

## Architecture

```text
Zara runtime (generic ServicePlugin API v1)
        |
        +-- MaraBridgePlugin (existing; turn/listen/speech routes)
        |
        +-- MaraAvatarPlugin  <- this document
              |
              +-- HTTP + SSE server (127.0.0.1:7321)
              |     routes: /v1/avatar/...  (deterministic ops only)
              |
              +-- runtime event subscription (presence inference)
              |
              +-- AvatarActor (single serialized authority)
                    |
                    +-- AvatarState (typed, frozen snapshot)
                    +-- ExpressionPolicy (emotion -> expression fallback)
                    +-- AnimationController (semantic clips, idle shuffle)
                    +-- VisemeAnalyzer (PCM -> A/I/U/E/O)
                    +-- RendererHost (child process, stdio NDJSON)
                          |
                          +-- renderer/main.mjs (Electron + Three.js + @pixiv/three-vrm)
```

Every mutation of avatar state flows through `AvatarActor`. HTTP handlers,
the runtime-event pump, and animation timers only enqueue work. The actor is
a managed Zara worker (`runtime.start_worker("avatar-actor", ...)`), so Zara
owns its lifecycle bound.

## Protocol

Deterministic operations only. The LLM never emits animation filenames, bone
names, morph targets, or renderer details; Mara semantic events carry
vocabularies (`presence`, `emotion`, `gesture`), and the plugin maps them onto
presentation.

| Route | Op |
| --- | --- |
| `GET /v1/avatar/status` | full status document |
| `GET /v1/avatar/list` | imported avatars |
| `POST /v1/avatar/import` | validate + store a `.vrm` |
| `POST /v1/avatar/delete` | remove an avatar |
| `POST /v1/avatar/load` | load into renderer |
| `POST /v1/avatar/select` | load + remember preferred avatar |
| `POST /v1/avatar/unload` | unload |
| `POST /v1/avatar/show` / `hide` | window visibility |
| `POST /v1/avatar/presence` | `idle/listening/thinking/speaking` |
| `POST /v1/avatar/emotion` | `neutral/happy/sad/annoyed/excited/embarrassed` |
| `POST /v1/avatar/expression` | semantic expression override |
| `POST /v1/avatar/gesture` | `wave/nod/shrug/point` |
| `POST /v1/avatar/animation/play` / `stop` | semantic clip, loop, speed, duration |
| `POST /v1/avatar/gaze` | `user/auto/center` or point |
| `POST /v1/avatar/speech/begin` / `audio` / `end` / `cancel` | speech lifecycle |
| `POST /v1/avatar/transform` / `GET` | position/rotation/scale |
| `POST /v1/avatar/framing` / `GET` | `half/full` |
| `GET /v1/avatar/events` | SSE state stream |

Validation mirrors the Mara bridge: strict field checks, bounded payloads,
local-only binding.

## Presence and semantic events

- Explicit operations (`avatar.presence.set`) are authoritative. Setting
  `idle` returns presence ownership to runtime inference.
- Zara runtime events infer presence when nothing explicit is set:
  `turn.started` -> thinking, `assistant.completed`/`runtime.idle` -> idle,
  voice listening state -> listening.
- Emotion events drive expressions through
  `EMOTION_EXPRESSIONS` -> `resolve_expression` fallback chains
  (requested -> native -> compatible -> happy -> neutral). Missing morphs
  never crash; unknown capabilities present the requested expression
  optimistically and the renderer degrades per model.

## Speech and lip sync

`speech.begin` -> speaking presence, fresh analyzer. `speech.audio` chunks
(PCM16 LE mono, per-chunk sample rate) are analyzed into amplitude + dominant
frequency, mapped to A/I/U/E/O weights with EMA smoothing, mouth gain, volume
influence, and `analyzed`/`direct`/`hybrid` modes. `speech.end`/`cancel`
always zero all visemes, clear the analyzer, and restore the pre-speech
presence. The mouth can never freeze open. The analyzer is provider-neutral
(no Fish Audio coupling).

## Renderer boundary

`RendererHost` owns one child process speaking newline-delimited JSON over
stdio. Commands: LoadAvatar, UnloadAvatar, SetExpression, SetTransform,
SetCamera, SetGaze, SetVisemes, SetLighting, PlayAnimation, StopAnimation,
ShowWindow, HideWindow, Shutdown. Crashes raise `rendererExited`; the actor
restarts with bounded attempts and backoff, then re-syncs state (load,
expression, transform, camera). Startup failures degrade presentation while
Mara semantics stay fully alive.

## Failure isolation and shutdown

- Renderer spawn/startup failure: `renderer.state = unavailable`; the plugin
  and Mara keep working.
- Plugin `stop()` closes the subscription, stops the actor worker, and shuts
  the renderer down (graceful, then terminate, then kill). Zara joins all
  managed workers. No orphan processes or threads.
- Corrupt VRMs are rejected at import (glTF magic, chunk layout, VRM
  extension) with bounded diagnostics and no side effects.

## Configuration

```toml
[plugins.mara-avatar]
enabled = true
bind_address = "127.0.0.1"
port = 7321
avatar_directory = "~/.local/share/mara/avatars"
# renderer_command = ["<path>/renderer/node_modules/.bin/electron", "<path>/renderer/main.mjs"]
renderer_startup_timeout = 10.0
renderer_request_timeout = 5.0
max_renderer_restarts = 3
restart_backoff = 1.0
request_size_limit = 1048576
max_sse_clients = 4
command_timeout = 5.0
lipsync_mode = "analyzed"
lipsync_smoothing = 0.35
lipsync_gain = 1.0
lipsync_volume_influence = 1.0
idle_seed = 7
```

The renderer command resolves in order: config, `MARA_AVATAR_RENDERER` env,
repo `renderer/` install, `~/.local/share/mara/renderer/` install. Renderer
dependencies are installed once with `cd renderer && npm install`; after that
everything works offline.

## Zara core changes

None. The existing generic plugin API (configuration, subscribe,
start_worker, dispatch) covers everything. No Mara-specific code exists in
Zarathushtra, and Pets is untouched.
