#!/usr/bin/env python3
"""Поддельный сервер ИИ для автотестов GX Files.

Проверяет, что клиент присылает корректные запросы в форматах OpenAI (chat/completions)
и Anthropic (messages), и отвечает так же, как настоящие сервисы: сначала вызов
инструмента list_dir, после результата инструмента — обычный текст.
Нарушение формата → HTTP 400 с описанием, тест это увидит как ошибку.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

TOOLS = {"list_dir", "read_file", "write_file", "edit_file", "make_dir", "move", "copy", "delete", "search", "file_info"}


class Bad(Exception):
    pass


def need(cond, msg):
    if not cond:
        raise Bad(msg)


def check_openai(h, body):
    need(h.get("Authorization") == "Bearer testkey", "Authorization header missing/wrong: %r" % h.get("Authorization"))
    need(body.get("model") == "mock-model", "model")
    msgs = body.get("messages")
    need(isinstance(msgs, list) and msgs and msgs[0].get("role") == "system", "first message must be system")
    tools = body.get("tools")
    need(isinstance(tools, list) and {t["function"]["name"] for t in tools} == TOOLS, "tools list")
    for t in tools:
        need(t.get("type") == "function", "tool type")
        need(t["function"]["parameters"].get("type") == "object", "parameters schema")
    tool_msgs = [m for m in msgs if m.get("role") == "tool"]
    if not tool_msgs:
        need(msgs[-1].get("role") == "user", "last message must be user")
        return {"choices": [{"message": {"role": "assistant", "content": None, "tool_calls": [
            {"id": "call_1", "type": "function", "function": {"name": "list_dir", "arguments": json.dumps({"path": "."})}}]}}]}
    # проверить, что ход ассистента с tool_calls передан обратно и результат привязан к id
    asst = [m for m in msgs if m.get("role") == "assistant" and m.get("tool_calls")]
    need(asst, "assistant tool_calls turn not sent back")
    need(isinstance(asst[0]["tool_calls"][0]["function"]["arguments"], str), "arguments must be a JSON string")
    need(tool_msgs[-1].get("tool_call_id") == "call_1", "tool_call_id")
    need("hello.txt" in tool_msgs[-1].get("content", ""), "tool result content: %r" % tool_msgs[-1].get("content"))
    return {"choices": [{"message": {"role": "assistant", "content": "done-openai"}}]}


def check_anthropic(h, body):
    need(h.get("x-api-key") == "testkey", "x-api-key")
    need(h.get("anthropic-version") == "2023-06-01", "anthropic-version")
    need(body.get("model") == "mock-model" and isinstance(body.get("max_tokens"), int), "model/max_tokens")
    need(isinstance(body.get("system"), str) and body["system"], "system")
    tools = body.get("tools")
    need(isinstance(tools, list) and {t["name"] for t in tools} == TOOLS, "tools")
    for t in tools:
        need(t["input_schema"].get("type") == "object", "input_schema")
    msgs = body.get("messages")
    need(isinstance(msgs, list) and msgs and msgs[0]["role"] == "user", "messages start with user")
    for a, b in zip(msgs, msgs[1:]):
        need(a["role"] != b["role"], "roles must alternate")
    last = msgs[-1]
    need(last["role"] == "user", "last must be user")
    results = [c for c in last["content"] if c.get("type") == "tool_result"]
    if not results:
        return {"content": [{"type": "text", "text": "Looking."},
                            {"type": "tool_use", "id": "tu_1", "name": "list_dir", "input": {"path": "."}}],
                "stop_reason": "tool_use"}
    need(msgs[-2]["role"] == "assistant" and any(c.get("type") == "tool_use" for c in msgs[-2]["content"]), "tool_use turn")
    need(results[0]["tool_use_id"] == "tu_1", "tool_use_id")
    need("hello.txt" in results[0]["content"], "tool_result content")
    return {"content": [{"type": "text", "text": "done-anthropic"}], "stop_reason": "end_turn"}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, obj):
        d = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(d)))
        self.end_headers()
        self.wfile.write(d)

    def do_GET(self):
        if self.path.startswith("/v1/models"):
            return self.reply(200, {"data": [{"id": "mock-model"}, {"id": "models/other-model"}]})
        self.reply(404, {"error": {"message": "not found"}})

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        try:
            body = json.loads(self.rfile.read(n))
        except Exception:
            return self.reply(400, {"error": {"message": "body is not JSON"}})
        if body.get("model") == "missing-model":
            return self.reply(404, {"error": {"message": "model not found"}})
        try:
            if self.path == "/v1/chat/completions":
                return self.reply(200, check_openai(self.headers, body))
            if self.path == "/v1/messages":
                return self.reply(200, check_anthropic(self.headers, body))
        except Bad as e:
            print("FORMAT ERROR:", e, file=sys.stderr, flush=True)
            return self.reply(400, {"error": {"message": "format: %s" % e}})
        except Exception as e:
            print("SERVER ERROR:", repr(e), file=sys.stderr, flush=True)
            return self.reply(400, {"error": {"message": "server: %r" % e}})
        self.reply(404, {"error": {"message": "unknown path " + self.path}})


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 8765), H).serve_forever()
