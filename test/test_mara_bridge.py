"""Tests for Mara's externally installed Zara service plugin."""

from __future__ import annotations

import dataclasses
import importlib.util
import json
import queue
import sys
import threading
import time
import types
import unittest
import urllib.error
import urllib.request
from concurrent.futures import Future
from pathlib import Path


@dataclasses.dataclass(frozen=True)
class _PluginMetadata:
    name: str
    version: str = ""
    api_version: str = "1"
    plugin_type: str = "service"
    description: str = ""


class _ServicePlugin:
    pass


@dataclasses.dataclass(frozen=True, kw_only=True)
class _RuntimeCommand:
    request_id: str = "request-id"


@dataclasses.dataclass(frozen=True, kw_only=True)
class _SubmitTurn(_RuntimeCommand):
    text: str
    conversation_id: str | None = None
    context_ids: tuple[str, ...] = ()


@dataclasses.dataclass(frozen=True, kw_only=True)
class _CancelTurn(_RuntimeCommand):
    turn_id: str


@dataclasses.dataclass(frozen=True, kw_only=True)
class _StartVoice(_RuntimeCommand):
    pass


@dataclasses.dataclass(frozen=True, kw_only=True)
class _StopVoice(_RuntimeCommand):
    pass


@dataclasses.dataclass(frozen=True, kw_only=True)
class _MuteSpeech(_RuntimeCommand):
    enabled: bool


@dataclasses.dataclass(frozen=True)
class _RuntimeStatus:
    state: str = "running"
    alive: bool = True
    thread_id: int = 123


@dataclasses.dataclass(frozen=True)
class _Receipt:
    request_id: str
    turn_id: str | None = None
    detail: str = "accepted"


@dataclasses.dataclass(frozen=True)
class VoiceStateChanged:
    state: str
    detail: str = ""


@dataclasses.dataclass(frozen=True)
class _Envelope:
    sequence: int
    occurred_at: float
    event: object


class _Subscription:
    def __init__(self, maxsize: int) -> None:
        self.queue = queue.Queue(maxsize=maxsize)
        self.closed = False
        self.dropped_count = 0

    def get(self, timeout=None):
        return self.queue.get(timeout=timeout)

    def close(self) -> None:
        self.closed = True


class _Worker:
    def __init__(self, target) -> None:
        self.stop_event = threading.Event()
        self.thread = threading.Thread(
            target=target, args=(self.stop_event,), daemon=True
        )
        self.thread.start()

    def stop(self) -> None:
        self.stop_event.set()
        self.thread.join(timeout=2)


class _FakeRuntime:
    def __init__(self, configuration=None) -> None:
        self.configuration = configuration or {"port": 0}
        self.status = _RuntimeStatus()
        self.subscription = None
        self.workers = []
        self.commands = []

    def subscribe(self, *, maxsize: int):
        self.subscription = _Subscription(maxsize)
        return self.subscription

    def start_worker(self, name, target):
        worker = _Worker(target)
        self.workers.append((name, worker))
        return worker

    def dispatch(self, command):
        self.commands.append(command)
        future = Future()
        future.set_result(_Receipt(request_id=command.request_id))
        return future

    def close(self) -> None:
        for _, worker in self.workers:
            worker.stop()


def _load_bridge_module():
    zara = types.ModuleType("zara")
    plugins = types.ModuleType("zara.plugins")
    runtime = types.ModuleType("zara.runtime")
    commands = types.ModuleType("zara.runtime.commands")
    plugins.PluginMetadata = _PluginMetadata
    plugins.ServicePlugin = _ServicePlugin
    commands.RuntimeCommand = _RuntimeCommand
    commands.SubmitTurn = _SubmitTurn
    commands.CancelTurn = _CancelTurn
    commands.StartVoice = _StartVoice
    commands.StopVoice = _StopVoice
    commands.MuteSpeech = _MuteSpeech
    modules = {
        "zara": zara,
        "zara.plugins": plugins,
        "zara.runtime": runtime,
        "zara.runtime.commands": commands,
    }
    previous = {name: sys.modules.get(name) for name in modules}
    sys.modules.update(modules)
    try:
        path = Path(__file__).parents[1] / "zara-plugin" / "mara_bridge.py"
        spec = importlib.util.spec_from_file_location("mara_bridge_under_test", path)
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        return module
    finally:
        for name, value in previous.items():
            if value is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = value


BRIDGE = _load_bridge_module()


class MaraBridgeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.runtime = _FakeRuntime()
        self.plugin = BRIDGE.create_plugin()

    def tearDown(self) -> None:
        self.plugin.stop()
        self.runtime.close()

    def url(self, path: str) -> str:
        port = self.plugin.status_document()["server"]["port"]
        return f"http://127.0.0.1:{port}{path}"

    def request(self, path: str, payload: dict) -> tuple[int, dict]:
        body = json.dumps(payload).encode("utf-8")
        request = urllib.request.Request(
            self.url(path),
            data=body,
            method="POST",
            headers={"Content-Type": "application/json"},
        )
        try:
            response = urllib.request.urlopen(request, timeout=2)
        except urllib.error.HTTPError as error:
            try:
                return error.code, json.loads(error.read())
            finally:
                error.close()
        with response:
            return response.status, json.loads(response.read())

    def test_factory_has_no_import_or_construction_side_effects(self) -> None:
        plugin = BRIDGE.create_plugin()
        self.assertIsNone(plugin._server)
        self.assertIsNone(plugin._subscription)
        self.assertFalse(plugin._started)

    def test_status_and_command_routes_use_runtime_facade(self) -> None:
        self.plugin.start(self.runtime)
        with urllib.request.urlopen(self.url("/v1/status"), timeout=2) as response:
            status = json.loads(response.read())
        self.assertEqual("mara-bridge", status["name"])
        self.assertEqual("127.0.0.1", status["server"]["bindAddress"])
        self.assertTrue(status["runtime"]["alive"])
        self.assertFalse(status["capabilities"]["notify"])

        code, _ = self.request("/v1/listen", {})
        self.assertEqual(202, code)
        self.assertIsInstance(self.runtime.commands[-1], _StartVoice)

        code, _ = self.request(
            "/v1/turn",
            {"text": "hello", "conversationId": "mara", "contextIds": ["one"]},
        )
        self.assertEqual(202, code)
        command = self.runtime.commands[-1]
        self.assertIsInstance(command, _SubmitTurn)
        self.assertEqual(("one",), command.context_ids)

    def test_unavailable_zara_capability_is_explicit(self) -> None:
        self.plugin.start(self.runtime)
        code, document = self.request("/v1/notify", {"text": "hello"})
        self.assertEqual(501, code)
        self.assertIn("canonical runtime command", document["error"])
        self.assertEqual([], self.runtime.commands)

    def test_backend_rejection_is_reported_as_unsupported(self) -> None:
        class UnsupportedRuntimeCommand(RuntimeError):
            pass

        def reject(_command):
            future = Future()
            future.set_exception(UnsupportedRuntimeCommand("voice unavailable"))
            return future

        self.runtime.dispatch = reject
        self.plugin.start(self.runtime)
        code, document = self.request("/v1/listen", {})
        self.assertEqual(501, code)
        self.assertEqual("voice unavailable", document["error"])

    def test_request_and_event_clients_are_bounded(self) -> None:
        self.runtime.configuration = {
            "port": 0,
            "request_size_limit": 8,
            "event_queue_size": 1,
            "max_sse_clients": 1,
        }
        self.plugin.start(self.runtime)
        code, _ = self.request("/v1/turn", {"text": "too large"})
        self.assertEqual(413, code)

        client = self.plugin.add_event_client()
        self.assertIsNotNone(client)
        self.assertIsNone(self.plugin.add_event_client())
        self.plugin._broadcast((1, "runtime.started", "{}"))
        self.plugin._broadcast((2, "runtime.idle", "{}"))
        self.assertEqual(2, client.get_nowait()[0])
        self.plugin.remove_event_client(client)

    def test_invalid_configuration_cannot_open_remote_listener(self) -> None:
        self.runtime.configuration = {"bind_address": "0.0.0.0", "port": 0}
        with self.assertRaisesRegex(ValueError, "127.0.0.1"):
            self.plugin.start(self.runtime)
        self.assertIsNone(self.plugin._server)

    def test_sse_forwards_provider_neutral_runtime_event(self) -> None:
        self.plugin.start(self.runtime)
        response = urllib.request.urlopen(self.url("/v1/events"), timeout=2)
        try:
            deadline = time.monotonic() + 2
            while self.plugin.status_document()["eventClients"] != 1:
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.01)
            self.runtime.subscription.queue.put(
                _Envelope(7, 123.5, VoiceStateChanged(state="listening"))
            )
            lines = []
            while not any(line.startswith(b"data: ") for line in lines):
                lines.append(response.readline())
            event_line = next(line for line in lines if line.startswith(b"event: "))
            data_line = next(line for line in lines if line.startswith(b"data: "))
            self.assertEqual(b"event: speech.state_changed\n", event_line)
            document = json.loads(data_line.removeprefix(b"data: "))
            self.assertEqual(7, document["sequence"])
            self.assertEqual("listening", document["data"]["state"])
        finally:
            response.close()

    def test_stop_closes_subscription_and_managed_workers(self) -> None:
        self.plugin.start(self.runtime)
        self.assertEqual(
            ["mara-event-pump", "mara-http-server"],
            [name for name, _ in self.runtime.workers],
        )
        self.plugin.stop()
        self.runtime.close()
        self.assertTrue(self.runtime.subscription.closed)
        self.assertTrue(all(not worker.thread.is_alive() for _, worker in self.runtime.workers))


if __name__ == "__main__":
    unittest.main()
