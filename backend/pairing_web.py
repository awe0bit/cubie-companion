"""Local operator UI and unauthenticated, narrowly-scoped pairing protocol."""
import base64
import io
import json
from pathlib import Path
from pairing import PairingError

STATIC = Path(__file__).parent / "web"


def body(env):
    try:
        size = int(env.get("CONTENT_LENGTH", "0"))
        if not 0 < size <= 1024:
            raise PairingError(413, "invalid_body_size")
        if env.get("CONTENT_TYPE", "").split(";")[0] != "application/json":
            raise PairingError(415, "json_required")
        result = json.loads(env["wsgi.input"].read(size))
        if not isinstance(result, dict):
            raise ValueError()
        return result
    except (ValueError, UnicodeError):
        raise PairingError(400, "invalid_json")


class PairingWeb:
    def __init__(self, store):
        self.store = store

    def dispatch(self, env):
        path, method = env.get("PATH_INFO", ""), env.get("REQUEST_METHOD")
        if env.get("QUERY_STRING"):
            raise PairingError(400, "query_not_supported")
        if path in ("/pair", "/pair.js", "/pair.css") and method == "GET":
            file, mime = {"/pair": ("pair.html", "text/html"), "/pair.js": ("pair.js", "text/javascript"),
                          "/pair.css": ("pair.css", "text/css")}[path]
            return (STATIC / file).read_bytes(), mime + "; charset=utf-8"
        if path == "/v1/pairing/result" and method == "GET":
            auth = env.get("HTTP_AUTHORIZATION", "")
            return self.store.result(auth[7:] if auth.startswith("Bearer ") else ""), None
        if method != "POST":
            raise PairingError(405, "method_not_allowed")
        data = body(env)
        if path == "/v1/pairing/request" and set(data) == {"ticket", "tokenSHA256", "name"}:
            return self.store.request(data["ticket"], data["tokenSHA256"], data["name"]), None
        auth = env.get("HTTP_AUTHORIZATION", "")
        manager = auth[8:] if auth.startswith("Pairing ") else ""
        if path == "/pairing/offer" and set(data) <= {"payload"}:
            offer = self.store.offer(manager)
            if "payload" in data and offer["state"] == "waiting":
                # Render locally: no external QR service receives the pairing ticket.
                payload = data["payload"]
                if not isinstance(payload, str) or len(payload) > 600:
                    raise PairingError(400, "invalid_offer")
                import qrcode
                import qrcode.image.pure
                image = qrcode.make(payload, image_factory=qrcode.image.pure.PyPNGImage)
                output = io.BytesIO()
                image.save(output)
                offer["qr"] = "data:image/png;base64," + base64.b64encode(output.getvalue()).decode()
            return offer, None
        if path == "/pairing/decision" and set(data) == {"approve"} and type(data["approve"]) is bool:
            return self.store.decide(manager, data["approve"]), None
        raise PairingError(404, "not_found")

    def __call__(self, env, start):
        try:
            data, mime = self.dispatch(env)
            code = 200
        except PairingError as error:
            data, mime, code = {"error": error.code}, None, error.status
        except Exception:
            data, mime, code = {"error": "pairing_unavailable"}, None, 503
        content = data if mime else json.dumps(data, ensure_ascii=False).encode()
        from http import HTTPStatus
        start("%d %s" % (code, HTTPStatus(code).phrase), [
            ("Content-Type", mime or "application/json; charset=utf-8"), ("Content-Length", str(len(content))),
            ("Cache-Control", "no-store"), ("X-Content-Type-Options", "nosniff"),
            ("Referrer-Policy", "no-referrer"), ("X-Frame-Options", "DENY"),
            ("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; img-src data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'")])
        return [content]
