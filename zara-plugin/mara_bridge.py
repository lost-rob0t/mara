"""Mara-owned localhost bridge for Zara's public service-plugin API."""

from __future__ import annotations

import concurrent.futures
import dataclasses
import enum
import ipaddress
import json
import queue
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Mapping, Optional

from zara.plugins import PluginMetadata, ServicePlugin
from zara.runtime.commands import (
    CancelTurn,
    MuteSpeech,
    StartVoice,
    StopVoice,
    SubmitTurn,
)


MARA_ZARA_BRIDGE = True
BRIDGE_VERSION = "0.1.0"
DEFAULT_PORT = 7319
DEFAULT_EVENT_QUEUE_SIZE = 128
DEFAULT_REQUEST_SIZE_LIMIT = 64 * 1024
DEFAULT_EVENT_SIZE_LIMIT = 64 * 1024
DEFAULT_MAX_CONNECTIONS = 16
DEFAULT_MAX_SSE_CLIENTS = 4
DEFAULT_COMMAND_TIMEOUT = 5.0
UNSUPPORTED_ROUTES = {
    "/v1/speak",
    "/v1/notify",
    "/v1/pet/show",
    "/v1/pet/expression",
    "/v1/timer",
}


class _RequestError(Exception):
    def __init__(self, status: int, message: str) -> None:
        super().__init__(message)
        self.status = status


def _bounded_text(value: object, limit: int = 512) -> str:
    return " ".join(str(value).split())[:limit]


def _jsonable(value: Any) -> Any:
    if dataclasses.is_dataclass(value):
        return _jsonable(dataclasses.asdict(value))
    if isinstance(value, enum.Enum):
        return value.value
    if isinstance(value, Mapping):
        return {str(key): _jsonable(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_jsonable(item) for item in value]
    if value is None or isinstance(value, (bool, int, float, str)):
        return value
    return _bounded_text(value, 1024)


def _event_name(event: object) -> str:
    name = type(event).__name__
    snake = re.sub(r"(?<!^)(?=[A-Z])", "_", name).lower()
    families = {
        "runtime": "runtime",
        "turn": "turn",
        "agent": "assistant",
        "assistant": "assistant",
        "response": "assistant",
        "output": "assistant",
        "voice": "speech",
        "transcript": "speech",
        "intent": "intent",
        "prolog": "intent",
        "tool": "tool",
        "user": "user",
        "indexing": "indexing",
    }
    for prefix, family in families.items():
        if snake.startswith(prefix + "_"):
            return f"{family}.{snake[len(prefix) + 1:]}"
    return f"runtime.{snake}"


def _integer_setting(
    configuration: Mapping[str, Any],
    name: str,
    default: int,
    minimum: int,
    maximum: int,
) -> int:
    value = configuration.get(name, default)
    if not isinstance(value, int) or isinstance(value, bool):
        raise ValueError(f"{name} must be an integer")
    if not minimum <= value <= maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}")
    return value


def _number_setting(
    configuration: Mapping[str, Any],
    name: str,
    default: float,
    minimum: float,
    maximum: float,
) -> float:
    value = configuration.get(name, default)
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        raise ValueError(f"{name} must be a number")
    number = float(value)
    if not minimum <= number <= maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}")
    return number


class _BoundedHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    block_on_close = True

    def __init__(
        self,
        server_address: tuple[str, int],
        plugin: "MaraBridgePlugin",
        max_connections: int,
    ) -> None:
        self.plugin = plugin
        self._connection_slots = threading.BoundedSemaphore(max_connections)
        self.request_queue_size = max_connections
        super().__init__(server_address, _RequestHandler)

    def process_request(self, request, client_address) -> None:
        if not self._connection_slots.acquire(blocking=False):
            try:
                request.sendall(
                    b"HTTP/1.1 503 Service Unavailable\r\n"
                    b"Connection: close\r\nContent-Length: 0\r\n\r\n"
                )
            finally:
                self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self._connection_slots.release()
            raise

    def process_request_thread(self, request, client_address) -> None:
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._connection_slots.release()


class _RequestHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "MaraZaraBridge/0.1"
    sys_version = ""

    @property
    def plugin(self) -> "MaraBridgePlugin":
        return self.server.plugin

    def log_message(self, format: str, *args: object) -> None:
        return None

    def do_GET(self) -> None:
        if not self._local_client():
            self._send_error(403, "local clients only")
            return
        path = self.path.partition("?")[0]
        if path == "/v1/status":
            self._send_json(200, self.plugin.status_document())
            return
        if path == "/v1/events":
            self._serve_events()
            return
        self._send_error(404, "route not found")

    def do_POST(self) -> None:
        if not self._local_client():
            self._send_error(403, "local clients only")
            return
        path = self.path.partition("?")[0]
        try:
            if path in UNSUPPORTED_ROUTES:
                raise _RequestError(
                    501,
                    "Zara does not expose a canonical runtime command for this capability",
                )
            payload = self._read_json()
            command = self.plugin.command_for(path, payload)
            receipt = self.plugin.dispatch(command)
            self._send_json(202, {"receipt": _jsonable(receipt)})
        except _RequestError as error:
            self._send_error(error.status, str(error))

    def do_DELETE(self) -> None:
        if not self._local_client():
            self._send_error(403, "local clients only")
            return
        path = self.path.partition("?")[0]
        if path.startswith("/v1/timer/"):
            self._send_error(
                501,
                "Zara does not expose a canonical runtime command for this capability",
            )
            return
        self._send_error(404, "route not found")

    def _local_client(self) -> bool:
        try:
            return ipaddress.ip_address(self.client_address[0]).is_loopback
        except ValueError:
            return False

    def _read_json(self) -> dict[str, Any]:
        content_type = self.headers.get_content_type()
        if content_type != "application/json":
            raise _RequestError(415, "content type must be application/json")
        raw_length = self.headers.get("Content-Length")
        if raw_length is None:
            raise _RequestError(411, "content length is required")
        try:
            length = int(raw_length)
        except ValueError as error:
            raise _RequestError(400, "invalid content length") from error
        if length < 0 or length > self.plugin.request_size_limit:
            raise _RequestError(413, "request body exceeds configured limit")
        try:
            payload = json.loads(self.rfile.read(length))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise _RequestError(400, "request body must be valid JSON") from error
        if not isinstance(payload, dict):
            raise _RequestError(400, "request body must be a JSON object")
        return payload

    def _serve_events(self) -> None:
        client = self.plugin.add_event_client()
        if client is None:
            self._send_error(503, "event client limit reached")
            return
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache, no-store")
            self.send_header("Connection", "close")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            self.wfile.write(b": connected\n\n")
            self.wfile.flush()
            last_write = time.monotonic()
            while not self.plugin.stopping:
                try:
                    sequence, event_name, payload = client.get(timeout=0.25)
                except queue.Empty:
                    if time.monotonic() - last_write >= 15.0:
                        self.wfile.write(b": keepalive\n\n")
                        self.wfile.flush()
                        last_write = time.monotonic()
                    continue
                frame = (
                    f"id: {sequence}\n"
                    f"event: {event_name}\n"
                    f"data: {payload}\n\n"
                ).encode("utf-8")
                self.wfile.write(frame)
                self.wfile.flush()
                last_write = time.monotonic()
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass
        finally:
            self.plugin.remove_event_client(client)

    def _send_error(self, status: int, message: str) -> None:
        self._send_json(status, {"error": _bounded_text(message)})

    def _send_json(self, status: int, document: Mapping[str, Any]) -> None:
        body = json.dumps(document, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)


class MaraBridgePlugin(ServicePlugin):
    metadata = PluginMetadata(
        name="mara-bridge",
        version=BRIDGE_VERSION,
        api_version="1",
        description="Mara-owned localhost HTTP and SSE bridge",
    )

    def __init__(self) -> None:
        self._runtime = None
        self._server: Optional[_BoundedHTTPServer] = None
        self._subscription = None
        self._event_clients: set[queue.Queue] = set()
        self._event_clients_lock = threading.RLock()
        self._stopping = threading.Event()
        self._started = False
        self._enabled = True
        self._event_queue_size = DEFAULT_EVENT_QUEUE_SIZE
        self._event_size_limit = DEFAULT_EVENT_SIZE_LIMIT
        self._request_size_limit = DEFAULT_REQUEST_SIZE_LIMIT
        self._max_sse_clients = DEFAULT_MAX_SSE_CLIENTS
        self._command_timeout = DEFAULT_COMMAND_TIMEOUT

    @property
    def request_size_limit(self) -> int:
        return self._request_size_limit

    @property
    def stopping(self) -> bool:
        return self._stopping.is_set()

    def start(self, runtime) -> None:
        if self._started:
            raise RuntimeError("Mara bridge already started")
        self._started = True
        self._runtime = runtime
        configuration = runtime.configuration
        self._enabled = configuration.get("enabled", True)
        if not isinstance(self._enabled, bool):
            raise ValueError("enabled must be a boolean")
        if not self._enabled:
            return

        bind_address = str(configuration.get("bind_address", "127.0.0.1"))
        if bind_address != "127.0.0.1":
            raise ValueError("bind_address must be 127.0.0.1")
        port = _integer_setting(configuration, "port", DEFAULT_PORT, 0, 65535)
        self._event_queue_size = _integer_setting(
            configuration, "event_queue_size", DEFAULT_EVENT_QUEUE_SIZE, 1, 4096
        )
        self._request_size_limit = _integer_setting(
            configuration,
            "request_size_limit",
            DEFAULT_REQUEST_SIZE_LIMIT,
            1,
            1024 * 1024,
        )
        self._event_size_limit = _integer_setting(
            configuration,
            "event_size_limit",
            DEFAULT_EVENT_SIZE_LIMIT,
            1024,
            1024 * 1024,
        )
        max_connections = _integer_setting(
            configuration,
            "max_connections",
            DEFAULT_MAX_CONNECTIONS,
            1,
            64,
        )
        self._max_sse_clients = _integer_setting(
            configuration,
            "max_sse_clients",
            DEFAULT_MAX_SSE_CLIENTS,
            1,
            16,
        )
        self._command_timeout = _number_setting(
            configuration,
            "command_timeout",
            DEFAULT_COMMAND_TIMEOUT,
            0.1,
            60.0,
        )

        try:
            self._server = _BoundedHTTPServer(
                (bind_address, port), self, max_connections
            )
            self._server.timeout = 0.25
            self._subscription = runtime.subscribe(maxsize=self._event_queue_size)
            runtime.start_worker("mara-event-pump", self._pump_events)
            runtime.start_worker("mara-http-server", self._serve)
        except Exception:
            self._stopping.set()
            if self._subscription is not None:
                self._subscription.close()
            if self._server is not None:
                self._server.server_close()
            raise

    def stop(self) -> None:
        if self._stopping.is_set():
            return
        self._stopping.set()
        if self._subscription is not None:
            self._subscription.close()

    def status_document(self) -> dict[str, Any]:
        runtime_status = self._runtime.status if self._runtime is not None else None
        address = self._server.server_address if self._server is not None else (None, None)
        with self._event_clients_lock:
            event_clients = len(self._event_clients)
        return {
            "name": self.metadata.name,
            "version": self.metadata.version,
            "apiVersion": self.metadata.api_version,
            "state": "stopping" if self.stopping else "running",
            "runtime": _jsonable(runtime_status),
            "server": {"bindAddress": address[0], "port": address[1]},
            "eventClients": event_clients,
            "eventDrops": (
                self._subscription.dropped_count if self._subscription is not None else 0
            ),
            "capabilities": {
                "events": True,
                "turn": True,
                "turnCancel": True,
                "listen": True,
                "listenCancel": True,
                "speechMute": True,
                "speak": False,
                "notify": False,
                "pet": False,
                "timer": False,
            },
        }

    def command_for(self, path: str, payload: Mapping[str, Any]):
        if path == "/v1/listen":
            self._require_empty_payload(payload)
            return StartVoice()
        if path == "/v1/listen/cancel":
            self._require_empty_payload(payload)
            return StopVoice()
        if path == "/v1/speech/mute":
            enabled = payload.get("enabled")
            if not isinstance(enabled, bool):
                raise _RequestError(400, "enabled must be a boolean")
            if set(payload) != {"enabled"}:
                raise _RequestError(400, "unexpected request fields")
            return MuteSpeech(enabled=enabled)
        if path == "/v1/turn":
            text = payload.get("text")
            if not isinstance(text, str) or not text.strip():
                raise _RequestError(400, "text must be a non-empty string")
            conversation_id = payload.get("conversationId")
            if conversation_id is not None and not isinstance(conversation_id, str):
                raise _RequestError(400, "conversationId must be a string")
            context_ids = payload.get("contextIds", [])
            if not isinstance(context_ids, list) or any(
                not isinstance(item, str) for item in context_ids
            ):
                raise _RequestError(400, "contextIds must be a list of strings")
            if set(payload) - {"text", "conversationId", "contextIds"}:
                raise _RequestError(400, "unexpected request fields")
            return SubmitTurn(
                text=text,
                conversation_id=conversation_id,
                context_ids=tuple(context_ids),
            )
        if path == "/v1/turn/cancel":
            turn_id = payload.get("turnId")
            if not isinstance(turn_id, str) or not turn_id:
                raise _RequestError(400, "turnId must be a non-empty string")
            if set(payload) != {"turnId"}:
                raise _RequestError(400, "unexpected request fields")
            return CancelTurn(turn_id=turn_id)
        raise _RequestError(404, "route not found")

    def dispatch(self, command):
        if self._runtime is None:
            raise _RequestError(503, "bridge is not running")
        future = self._runtime.dispatch(command)
        try:
            return future.result(timeout=self._command_timeout)
        except concurrent.futures.TimeoutError as error:
            raise _RequestError(504, "runtime command timed out") from error
        except Exception as error:
            if type(error).__name__ == "UnsupportedRuntimeCommand":
                raise _RequestError(501, _bounded_text(error)) from error
            raise _RequestError(500, _bounded_text(error)) from error

    def add_event_client(self) -> Optional[queue.Queue]:
        with self._event_clients_lock:
            if self.stopping or len(self._event_clients) >= self._max_sse_clients:
                return None
            client: queue.Queue = queue.Queue(maxsize=self._event_queue_size)
            self._event_clients.add(client)
            return client

    def remove_event_client(self, client: queue.Queue) -> None:
        with self._event_clients_lock:
            self._event_clients.discard(client)

    def _require_empty_payload(self, payload: Mapping[str, Any]) -> None:
        if payload:
            raise _RequestError(400, "request body must be empty")

    def _serve(self, worker_stop: threading.Event) -> None:
        if self._server is None:
            raise RuntimeError("HTTP server is not initialized")
        try:
            while not worker_stop.is_set() and not self.stopping:
                self._server.handle_request()
        finally:
            self._server.server_close()

    def _pump_events(self, worker_stop: threading.Event) -> None:
        if self._subscription is None:
            raise RuntimeError("event subscription is not initialized")
        while not worker_stop.is_set() and not self.stopping:
            try:
                envelope = self._subscription.get(timeout=0.25)
            except queue.Empty:
                continue
            event_name = _event_name(envelope.event)
            document = {
                "sequence": envelope.sequence,
                "occurredAt": envelope.occurred_at,
                "type": event_name,
                "data": _jsonable(envelope.event),
            }
            payload = json.dumps(document, separators=(",", ":"))
            if len(payload.encode("utf-8")) > self._event_size_limit:
                event_name = "bridge.event_omitted"
                payload = json.dumps(
                    {
                        "sequence": envelope.sequence,
                        "occurredAt": envelope.occurred_at,
                        "type": event_name,
                        "data": {"reason": "event exceeds configured limit"},
                    },
                    separators=(",", ":"),
                )
            self._broadcast((envelope.sequence, event_name, payload))

    def _broadcast(self, item: tuple[int, str, str]) -> None:
        with self._event_clients_lock:
            clients = tuple(self._event_clients)
        for client in clients:
            try:
                client.put_nowait(item)
                continue
            except queue.Full:
                pass
            try:
                client.get_nowait()
            except queue.Empty:
                pass
            try:
                client.put_nowait(item)
            except queue.Full:
                pass


def create_plugin() -> MaraBridgePlugin:
    return MaraBridgePlugin()


__all__ = ["BRIDGE_VERSION", "MARA_ZARA_BRIDGE", "MaraBridgePlugin", "create_plugin"]
