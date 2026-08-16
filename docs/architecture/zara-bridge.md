# Mara's Zara bridge

Mara owns `zara-plugin/mara_bridge.py`. Zara owns only the generic service
plugin API and `RuntimeHost` boundary. `M-x mara-zara-install` copies Mara's
source to `~/.zarathushtra/plugins/mara_bridge.py`; neither repository downloads
or embeds the other.

## Lifecycle and threading

The module exports `create_plugin()`. Construction and import acquire no
resources. Zara calls `start(runtime)` once and `stop()` once through service
plugin API version 1.

At startup the bridge:

1. validates the Mara-owned `[plugins.mara-bridge]` configuration;
2. binds a bounded HTTP server to `127.0.0.1`;
3. creates one bounded canonical runtime-event subscription;
4. starts the HTTP loop and event pump with `runtime.start_worker()`.

HTTP handler threads dispatch only `RuntimeCommand` values through
`runtime.dispatch()`. They never receive Zara internals or manipulate Qt. Stop
closes the subscription, signals every handler, and lets Zara join both managed
workers within its lifecycle deadline.

## Configuration

Defaults are deliberately local and bounded:

```toml
[plugins.mara-bridge]
enabled = true
bind_address = "127.0.0.1"
port = 7319
event_queue_size = 128
request_size_limit = 65536
event_size_limit = 65536
max_connections = 16
max_sse_clients = 4
command_timeout = 5.0
```

`bind_address` accepts only `127.0.0.1`. Port `0` is accepted for tests and
selects an ephemeral local port. Request and event limits may not exceed 1 MiB;
connections, event clients, event queues, command waits, workers, and Zara
subscriptions are all bounded.

There is intentionally no authentication in this local-only version. Do not
forward or proxy this listener onto another interface.

## HTTP API

Successful command requests return HTTP 202 with Zara's `CommandReceipt`:

| Method | Route | Zara contract |
| --- | --- | --- |
| `GET` | `/v1/status` | Bridge and `RuntimeStatus` snapshot |
| `GET` | `/v1/events` | Canonical runtime events over SSE |
| `POST` | `/v1/turn` | `SubmitTurn` |
| `POST` | `/v1/turn/cancel` | `CancelTurn` |
| `POST` | `/v1/listen` | `StartVoice` |
| `POST` | `/v1/listen/cancel` | `StopVoice` |
| `POST` | `/v1/speech/mute` | `MuteSpeech` |

POST bodies must be bounded JSON objects with `Content-Type: application/json`.
Examples:

```json
{"text":"hello","conversationId":"mara","contextIds":[]}
```

```json
{"turnId":"the-runtime-turn-id"}
```

```json
{"enabled":true}
```

Backends may reject optional commands. The bridge reports Zara's
`UnsupportedRuntimeCommand` as HTTP 501 and never creates a parallel
implementation.

The intended `/v1/speak`, `/v1/notify`, `/v1/pet/*`, and `/v1/timer` routes also
return HTTP 501 today because Zara does not yet expose canonical commands for
those capabilities. Implementing them by calling speech providers, Qt, Pets, or
timer internals from Mara would violate the runtime boundary.

## SSE events

`GET /v1/events` produces one bounded stream per client:

```text
id: 42
event: speech.state_changed
data: {"sequence":42,"occurredAt":...,"type":"speech.state_changed","data":{...}}
```

The event pump serializes existing provider-neutral Zara `EventEnvelope`
objects. Each client has a bounded queue that drops its oldest event under
load, allowing the stream to converge on current runtime state. Oversized
events are replaced with `bridge.event_omitted`; slow or disconnected clients
cannot block runtime publishers.

## Installation ownership

The Emacs installer performs an atomic same-directory replacement and writes
mode 0644. Updates are permitted only when the installed file contains Mara's
ownership marker. Status is based on SHA-256 comparison with the repository
source; it does not claim that a running Zara process has reloaded the file.
