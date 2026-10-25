"""One-time, operator-approved pairing. SQLite contains hashes, never bearer tokens."""
import hashlib
import hmac
import json
from pathlib import Path
import re
import secrets
import sqlite3
import threading
import time
from urllib.parse import urlsplit


class PairingError(Exception):
    def __init__(self, status, code):
        self.status, self.code = status, code


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def access_credentials(value):
    if (not isinstance(value, dict) or set(value) != {"clientID", "clientSecret"}
            or not isinstance(value["clientID"], str) or not isinstance(value["clientSecret"], str)
            or not re.fullmatch(r"[A-Za-z0-9._-]{16,160}", value["clientID"])
            or not re.fullmatch(r"[A-Za-z0-9_-]{32,160}", value["clientSecret"])):
        raise ValueError("invalid_access_handoff")
    return value


def endpoint(value):
    parts = urlsplit(value)
    if (parts.scheme != "https" or not parts.hostname or parts.username or parts.password
            or parts.port is not None or parts.query or parts.fragment or parts.path not in ("", "/")
            or not re.fullmatch(r"[A-Za-z0-9.-]+", parts.hostname)):
        raise ValueError("https_origin_required")
    return "https://" + parts.hostname.lower()


class PairingStore:
    def __init__(self, path, clock=time.time):
        self.clock, self.lock = clock, threading.Lock()
        self.db = sqlite3.connect(str(path), check_same_thread=False, isolation_level=None)
        self.db.execute("PRAGMA busy_timeout=5000")
        self.db.execute("PRAGMA secure_delete=ON")
        self.db.executescript("""
          CREATE TABLE IF NOT EXISTS grants (
            id TEXT PRIMARY KEY, claim_hash TEXT NOT NULL, manage_hash TEXT NOT NULL,
            origin TEXT NOT NULL, expires REAL NOT NULL, role TEXT NOT NULL,
            state TEXT NOT NULL, device_id TEXT, token_hash TEXT, name TEXT, code TEXT);
          CREATE TABLE IF NOT EXISTS devices (
            id TEXT PRIMARY KEY, token_hash TEXT UNIQUE NOT NULL, name TEXT NOT NULL,
            role TEXT NOT NULL, created REAL NOT NULL, revoked INTEGER NOT NULL DEFAULT 0);
          CREATE TABLE IF NOT EXISTS pairing_rate (bucket INTEGER PRIMARY KEY, count INTEGER NOT NULL);
        """)
        columns = {row[1] for row in self.db.execute("PRAGMA table_info(grants)")}
        if "access_json" not in columns:
            self.db.execute("ALTER TABLE grants ADD COLUMN access_json TEXT")
        self.db.execute("UPDATE grants SET access_json=NULL WHERE expires <= ?", (self.clock(),))

    def create(self, origin, role="viewer", ttl=300, access=None):
        origin = endpoint(origin)
        if role not in ("viewer", "admin") or not 30 <= ttl <= 300:
            raise ValueError("invalid_grant")
        ident, claim, manage = secrets.token_hex(12), secrets.token_urlsafe(32), secrets.token_urlsafe(32)
        expires = self.clock() + ttl
        handoff = json.dumps(access_credentials(access)) if access is not None else None
        with self.lock:
            self.db.execute("BEGIN IMMEDIATE")
            try:
                # A new QR replaces outstanding offers, never existing paired devices.
                self.db.execute("DELETE FROM grants WHERE state != 'approved' OR expires < ?", (self.clock() - 3600,))
                self.db.execute("INSERT INTO grants(id,claim_hash,manage_hash,origin,expires,role,state,access_json) VALUES (?, ?, ?, ?, ?, ?, 'waiting', ?)",
                                (ident, digest(claim), digest(manage), origin, expires, role, handoff))
                self.db.execute("COMMIT")
            except Exception:
                self.db.execute("ROLLBACK")
                raise
        return {"manager": ident + "." + manage, "ticket": ident + "." + claim,
                "expiresAt": expires, "endpoint": origin, "role": role}

    def _get(self, credential, column):
        if not isinstance(credential, str) or not re.fullmatch(r"[a-f0-9]{24}\.[A-Za-z0-9_-]{43}", credential):
            raise PairingError(401, "pairing_unauthorized")
        ident, secret = credential.split(".")
        # column is a hardcoded caller constant, never user input.
        row = self.db.execute("SELECT * FROM grants WHERE id = ?", (ident,)).fetchone()
        index = 1 if column == "claim" else 2
        if row is None or not hmac.compare_digest(row[index], digest(secret)):
            raise PairingError(401, "pairing_unauthorized")
        if row[4] <= self.clock() and row[6] not in ("approved", "rejected"):
            raise PairingError(410, "pairing_expired")
        return row

    def _rate(self):
        bucket = int(self.clock() // 60)
        self.db.execute("DELETE FROM pairing_rate WHERE bucket < ?", (bucket,))
        self.db.execute("INSERT INTO pairing_rate VALUES (?, 1) ON CONFLICT(bucket) DO UPDATE SET count=count+1", (bucket,))
        if self.db.execute("SELECT count FROM pairing_rate WHERE bucket=?", (bucket,)).fetchone()[0] > 30:
            raise PairingError(429, "pairing_rate_limited")

    def request(self, ticket, token_hash, name):
        if (not isinstance(token_hash, str) or not re.fullmatch(r"[a-f0-9]{64}", token_hash)
                or not isinstance(name, str) or not 1 <= len(name.strip()) <= 60
                or any(ord(c) < 32 for c in name)):
            raise PairingError(400, "invalid_pairing_request")
        with self.lock:
            self._rate()
            self.db.execute("BEGIN IMMEDIATE")
            try:
                row = self._get(ticket, "claim")
                if row[6] != "waiting":
                    raise PairingError(409, "pairing_already_claimed")
                ident, code = secrets.token_hex(12), "%06d" % secrets.randbelow(1000000)
                self.db.execute("UPDATE grants SET state='pending', device_id=?, token_hash=?, name=?, code=? WHERE id=?",
                                (ident, token_hash, name.strip(), code, row[0]))
                self.db.execute("COMMIT")
                return {"state": "pending", "deviceId": ident, "verificationCode": code}
            except Exception:
                self.db.execute("ROLLBACK")
                raise

    def offer(self, manager):
        with self.lock:
            row = self._get(manager, "manage")
            return {"state": row[6], "endpoint": row[3], "expiresAt": row[4], "role": row[5],
                    "deviceName": row[9], "verificationCode": row[10]}

    def decide(self, manager, approve):
        with self.lock:
            self.db.execute("BEGIN IMMEDIATE")
            try:
                row = self._get(manager, "manage")
                if row[6] != "pending":
                    raise PairingError(409, "pairing_not_pending")
                if approve:
                    self.db.execute("INSERT INTO devices(id,token_hash,name,role,created) VALUES (?,?,?,?,?)",
                                    (row[7], row[8], row[9], row[5], self.clock()))
                else:
                    self.db.execute("UPDATE grants SET access_json=NULL WHERE id=?", (row[0],))
                self.db.execute("UPDATE grants SET state=? WHERE id=?", ("approved" if approve else "rejected", row[0]))
                self.db.execute("COMMIT")
            except Exception:
                self.db.execute("ROLLBACK")
                raise
        return {"state": "approved" if approve else "rejected"}

    def result(self, token):
        if not isinstance(token, str) or not re.fullmatch(r"[A-Za-z0-9_-]{43}", token):
            raise PairingError(401, "pairing_unauthorized")
        hashed = digest(token)
        with self.lock:
            device = self.db.execute("SELECT id, revoked FROM devices WHERE token_hash=?", (hashed,)).fetchone()
            if device:
                result = {"state": "revoked" if device[1] else "approved", "deviceId": device[0]}
                row = self.db.execute("SELECT access_json,expires FROM grants WHERE device_id=?", (device[0],)).fetchone()
                if not device[1] and row and row[0] and row[1] > self.clock():
                    result["access"] = json.loads(row[0])
                return result
            row = self.db.execute("SELECT state,expires,device_id,code FROM grants WHERE token_hash=?", (hashed,)).fetchone()
            if not row:
                raise PairingError(401, "pairing_unauthorized")
            state = "expired" if row[1] <= self.clock() else row[0]
            return {"state": state, "deviceId": row[2], "verificationCode": row[3]}

    def role(self, hashed):
        with self.lock:
            row = self.db.execute("SELECT role FROM devices WHERE token_hash=? AND revoked=0", (hashed,)).fetchone()
            if row:
                # First authenticated API call confirms receipt. Wipe the temporary handoff.
                self.db.execute("UPDATE grants SET access_json=NULL WHERE token_hash=? AND access_json IS NOT NULL", (hashed,))
            return row[0] if row else None

    def devices(self):
        with self.lock:
            return [dict(zip(("id", "name", "role", "createdAt", "revoked"), row)) for row in
                    self.db.execute("SELECT id,name,role,created,revoked FROM devices ORDER BY created DESC")]

    def revoke(self, ident):
        with self.lock:
            changed = self.db.execute("UPDATE devices SET revoked=1 WHERE id=?", (ident,)).rowcount
            self.db.execute("UPDATE grants SET access_json=NULL WHERE device_id=?", (ident,))
        return changed == 1


def main():
    import argparse
    import os
    import sys
    from urllib.parse import urlencode
    parser = argparse.ArgumentParser(description="CoreNest operator-only pairing console")
    parser.add_argument("--database", default="/data/pairing.sqlite3")
    sub = parser.add_subparsers(dest="command", required=True)
    create = sub.add_parser("create")
    create.add_argument("--endpoint", required=True)
    create.add_argument("--role", choices=("viewer", "admin"), default="viewer")
    create.add_argument("--access-stdin", action="store_true", help="Private optional bootstrap/device Access credentials via stdin, never arguments")
    sub.add_parser("list")
    revoke = sub.add_parser("revoke")
    revoke.add_argument("device_id")
    args = parser.parse_args()
    os.umask(0o077)
    store = PairingStore(args.database)
    try:
        if args.command == "create":
            access = None
            if args.access_stdin:
                raw = sys.stdin.buffer.read(2049)
                if len(raw) > 2048:
                    raise ValueError("invalid_access_handoff")
                access = json.loads(raw)
                if not isinstance(access, dict) or set(access) != {"bootstrap", "device"}:
                    raise ValueError("invalid_access_handoff")
                access_credentials(access["bootstrap"])
                access_credentials(access["device"])
            grant = store.create(args.endpoint, args.role, access=access["device"] if access else None)
            # Ticket only lives in the browser fragment, never URLs sent to a web server.
            payload_value = {"type": "corenest-pair", "version": 1, "endpoint": grant["endpoint"],
                             "ticket": grant["ticket"], "expiresAt": grant["expiresAt"]}
            if access:
                payload_value["access"] = access["bootstrap"]
            payload = json.dumps(payload_value, separators=(",", ":"))
            print(json.dumps({"fragment": urlencode({"manager": grant["manager"], "offer": payload}),
                              "expiresAt": grant["expiresAt"]}))
        elif args.command == "list":
            print(json.dumps(store.devices(), ensure_ascii=False))
        else:
            if not store.revoke(args.device_id):
                raise SystemExit("Device not found.")
            print("Device credential revoked.")
    finally:
        store.db.close()


if __name__ == "__main__":
    main()
