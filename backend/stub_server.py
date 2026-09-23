#!/usr/bin/env python3
"""Contract stub for SeeFood's OpenJEV client smoke tests.

Emulates the two real server personalities the app targets and VALIDATES the
requests the client sends, so the smoke test proves wire shapes, not just
response tolerance:

  upstream  — upstream OpenJEV (razorback16/openjev README):
              POST /v1/systemone accepts `images`; /systemone is absent (404);
              POST /v1/chat/completions serves captions.
  mesh      — mesh-llm origin/main openai-frontend:
              POST /systemone (only); non-empty `images` -> 501 unsupported_model_feature
              "this PoC supports one text-only System One read; images, ...";
              /v1/systemone -> 404; /v1/chat/completions accepts image_url parts.

Env:
  SEEFOOD_STUB_PROFILE  upstream | mesh   (default upstream)
  SEEFOOD_STUB_PORT     port to bind      (default 8081)

Deterministic answers: hotdog noul = 0.97 (upstream), 0.93 (mesh);
state containing "salad" -> 0.02 so negative cases are exercisable.
"""

import base64
import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PROFILE = os.environ.get("SEEFOOD_STUB_PROFILE", "upstream")
PORT = int(os.environ.get("SEEFOOD_STUB_PORT", "8081"))

DATA_URL_RE = re.compile(r"^data:image/(jpeg|png|webp|gif);base64,[A-Za-z0-9+/=\s]+$")

UNSUPPORTED_MSG = (
    "this PoC supports one text-only System One read; images, multiple "
    "steps/samples, thinking, and sequential reads are not yet supported"
)


def oai_error(status: int, message: str, code: str) -> bytes:
    body = {"error": {"message": message, "type": "invalid_request_error",
                      "param": None, "code": code}}
    return json.dumps(body).encode()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # request log to stdout for evidence
        sys.stdout.write(f"[{PROFILE}:{PORT}] {self.command} {self.path}\n")
        sys.stdout.flush()

    # -- helpers ---------------------------------------------------------
    def _send(self, status: int, payload: bytes, ctype: str = "application/json") -> None:
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _send_json(self, status: int, obj) -> None:
        self._send(status, json.dumps(obj).encode())

    def _body(self) -> dict:
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        try:
            obj = json.loads(raw)
        except json.JSONDecodeError:
            self._send(400, b"invalid JSON body", "text/plain")
            raise SystemExit(0)
        if not isinstance(obj, dict):
            self._send(400, b"JSON body must be an object", "text/plain")
            raise SystemExit(0)
        return obj

    @staticmethod
    def _reject(message: str) -> None:
        Handler._send_static(400, message)

    @staticmethod
    def _send_static(status: int, message: str) -> None:
        # used from validation helpers; prints via stderr of the server process
        raise AssertionError(f"contract violation: {message}")

    # -- contract checks -------------------------------------------------
    def _validate_systemone_common(self, body: dict) -> None:
        assert isinstance(body.get("model"), str) and body["model"], "model must be a non-empty string"
        assert isinstance(body.get("state"), str), "state must be a string"
        q = body.get("questions")
        assert isinstance(q, dict) and q, "questions must be a non-empty object"
        hot = q.get("hotdog")
        assert isinstance(hot, dict), "questions.hotdog must exist"
        assert hot.get("type") == "noul", "questions.hotdog.type must be 'noul'"
        assert isinstance(hot.get("instructions"), str) and hot["instructions"], \
            "questions.hotdog.instructions must be a non-empty string"

    def _validate_images(self, body: dict) -> None:
        images = body.get("images")
        assert isinstance(images, list) and images, "images must be a non-empty array"
        for image in images:
            assert isinstance(image, str), "images entries must be data-URL strings"
            assert DATA_URL_RE.match(image), f"image not a jpeg/png/webp/gif data URL: {image[:48]}..."
        # decodable base64
        for image in images:
            payload = image.split(",", 1)[1]
            base64.b64decode(payload, validate=False)

    def _validate_caption_request(self, body: dict) -> None:
        assert isinstance(body.get("model"), str) and body["model"], "model must be a non-empty string"
        messages = body.get("messages")
        assert isinstance(messages, list) and messages, "messages must be a non-empty array"
        first = messages[0]
        assert first.get("role") == "user", "first message role must be user"
        content = first.get("content")
        assert isinstance(content, list), "content must be an array of parts"
        kinds = {part.get("type") for part in content}
        assert "text" in kinds, "content must include a text part"
        image_parts = [p for p in content if p.get("type") == "image_url"]
        assert image_parts, "content must include an image_url part"
        url = image_parts[0].get("image_url")
        assert isinstance(url, dict), "image_url part must be {image_url: {url}}"
        assert DATA_URL_RE.match(url.get("url", "")), "image_url.url must be a jpeg data URL"

    # -- routes ----------------------------------------------------------
    def do_POST(self):
        try:
            if self.path == "/v1/systemone":
                if PROFILE == "upstream":
                    self._systemone(allows_images=True)
                else:
                    # mesh-llm origin/main registers only /systemone; /v1/* misses -> 404.
                    self._send(404, oai_error(404, f"route not found: {self.path}", "not_found"))
            elif self.path == "/systemone":
                if PROFILE == "upstream":
                    self._send(404, oai_error(404, f"route not found: {self.path}", "not_found"))
                else:
                    self._systemone(allows_images=False)
            elif self.path == "/v1/chat/completions":
                body = self._body()
                self._validate_caption_request(body)
                caption = ("A grilled hot dog with mustard in a plain bun."
                           if PROFILE == "upstream" else
                           "A hot dog with mustard on a plain bun.")
                self._send_json(200, {
                    "id": "chatcmpl-stub",
                    "object": "chat.completion",
                    "model": body["model"],
                    "choices": [{
                        "index": 0,
                        "message": {"role": "assistant", "content": caption},
                        "finish_reason": "stop",
                    }],
                    "usage": {"prompt_tokens": 812, "completion_tokens": 12, "total_tokens": 824},
                })
            else:
                self._send(404, oai_error(404, f"route not found: {self.path}", "not_found"))
        except AssertionError as violation:
            sys.stderr.write(f"[{PROFILE}:{PORT}] CONTRACT VIOLATION: {violation}\n")
            self._send_json(400, {"error": {"message": f"stub contract violation: {violation}",
                                            "type": "invalid_request_error", "code": "stub_contract_violation"}})

    def _systemone(self, allows_images: bool) -> None:
        body = self._body()
        self._validate_systemone_common(body)
        has_images = bool(body.get("images"))
        if has_images:
            if not allows_images:
                self._send(501, oai_error(501, UNSUPPORTED_MSG, "unsupported_model_feature"))
                return
            self._validate_images(body)
        state = body.get("state", "")
        probability = 0.02 if "salad" in state.lower() else (0.97 if PROFILE == "upstream" else 0.93)
        model = "openjev-latest" if PROFILE == "upstream" else "diffusiongemma-26B-A4B-it-Q4_K_M"
        self._send_json(200, {
            "model": model,
            "answers": {"hotdog": {"type": "noul", "noul": probability}},
            "usage": {"input_tokens": 142 if has_images else 64, "output_tokens": 0},
        })

    def do_GET(self):
        self._send(404, oai_error(404, f"route not found: {self.path}", "not_found"))


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    sys.stdout.write(f"[{PROFILE}:{PORT}] stub up\n")
    sys.stdout.flush()
    server.serve_forever()
