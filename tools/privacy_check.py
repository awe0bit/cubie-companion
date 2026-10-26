"""Fail closed on private deployment material. Never print the matched value.

Optional --private-values reads a LOCAL JSON string list/object for exact matching;
the file itself must remain outside the repository. CI uses generic checks only.
"""
import argparse
import ipaddress
import json
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
FORBIDDEN_NAME = re.compile(r"(^|/)(\.env(?:\..*)?|.*\.credentials\.json|.*\.local\.(json|md)|"
                            r"verification-.*\.json|cloud-build-.*\.json|.*\.(pem|key|p12|pfx|mobileprovision)|"
                            r".*\.sqlite3(?:-.*)?|cookies.*|storage.state.*)$", re.I)
HOME_PATH = re.compile(r"(?:[A-Za-z]:[\\/](?:Users|用户)[\\/][^\s\"'<>]+|" + "/" +
                       r"Users/[^/\s\"'<>]+|" + "/" + r"home/(?!runner\b)[^/\s\"'<>]+)")
PHONE = re.compile(r"(?<![A-Za-z0-9])1[3-9][0-9]{9}(?![A-Za-z0-9])")
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})")
IP = re.compile(r"(?<![A-Za-z0-9])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![A-Za-z0-9])")
URL = re.compile(r"https?://[^\s\"'<>`]+")
PUBLIC_DOC_HOSTS = {"github.com", "developer.apple.com", "developers.cloudflare.com", "docs.docker.com",
                    "docs.radxa.com", "www.w3.org", "www.apple.com", "api.github.com",
                    "registry.npmjs.org", "docs.expo.dev"}
EXAMPLE_NETWORKS = [ipaddress.ip_network(value) for value in ("192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24")]


def tracked():
    raw = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT)
    return [value.decode("utf-8") for value in raw.split(b"\0") if value]


def violations(path, data, private_values=()):
    problems = []
    if FORBIDDEN_NAME.search(path) or path.startswith(("docs/screenshots/", ".a7s-monitor/")):
        problems.append("private_file_type")
    if any(value and value in data for value in private_values):
        problems.append("private_exact_match")
    if b"\0" in data[:8192] or path.endswith((".png", ".jpg", ".jpeg", ".zip", ".ipa")):
        if path.lower().endswith((".jpg", ".jpeg", ".zip", ".ipa")):
            problems.append("non_source_media_or_archive")
        return problems
    text = data.decode("utf-8", errors="replace")
    if HOME_PATH.search(text): problems.append("personal_home_path")
    if PHONE.search(text): problems.append("possible_phone_number")
    if any(not match.group(1).endswith(("example.com", "example.invalid")) for match in EMAIL.finditer(text)):
        problems.append("personal_email")
    for match in URL.finditer(text):
        value = match.group()
        if any(marker in value for marker in ("\\", "$", "%", "{", "[", "你的")):
            continue  # Interpolated URLs/placeholders are not deployed values.
        try: host = urlsplit(value).hostname
        except ValueError: continue
        if host and not (host in PUBLIC_DOC_HOSTS or host in {"localhost", "127.0.0.1"}
                         or host == "example.com" or host.endswith((".example.com", ".example.test", ".example.invalid"))):
            problems.append("non_example_service_domain")
    for match in IP.finditer(text):
        try: address = ipaddress.ip_address(match.group())
        except ValueError: continue
        if (not address.is_loopback and not address.is_unspecified
                and not any(address in network for network in EXAMPLE_NETWORKS)):
            problems.append("non_example_network_address"); break
    return sorted(set(problems))


def private_strings(value):
    if isinstance(value, str):
        # Short/empty placeholders should not make every source file match.
        return [value.encode()] if len(value) >= 12 else []
    if isinstance(value, dict): return sum((private_strings(v) for v in value.values()), [])
    if isinstance(value, list): return sum((private_strings(v) for v in value), [])
    return []


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--staged", action="store_true", help="Check exact index blobs before committing")
    parser.add_argument("--private-values", type=Path)
    args = parser.parse_args()
    values = []
    if args.private_values:
        private = args.private_values.resolve()
        if ROOT == private or ROOT in private.parents:
            raise SystemExit("Private values file must be outside this repository.")
        values = private_strings(json.loads(private.read_text(encoding="utf-8-sig")))
    failures = []
    for path in tracked():
        data = (subprocess.check_output(["git", "show", ":" + path], cwd=ROOT) if args.staged
                else (ROOT / path).read_bytes())
        for category in violations(path, data, values): failures.append({"file": path, "category": category})
    print(json.dumps({"privacy_check": "failed" if failures else "passed", "files_checked": len(tracked()),
                      "findings": failures}, ensure_ascii=False))
    if failures: raise SystemExit(1)


if __name__ == "__main__": main()
