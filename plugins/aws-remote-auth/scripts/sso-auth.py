#!/usr/bin/env python3
"""
aws-remote-auth — detect expired AWS SSO and trigger device-code re-auth (autofill code).

Subcommands:
  hook              PreToolUse: read the tool call JSON on stdin; for `aws` commands whose
                    profile has an expired/missing SSO session, start a detached device-code
                    login, capture the autofill URL + code, and emit a deny decision carrying
                    them — so the model surfaces an actionable prompt instead of a raw error.
  login [profile]   Start (or reuse) a device-code login and print the autofill URL + code.
  status [profile]  Report whether the profile's SSO session is valid (local check, no network).

Generic: nothing is account-specific. Profile is auto-detected (--profile in the command, else
$AWS_PROFILE, else 'default'); the SSO portal/URL come from ~/.aws/config; expiry is read locally
from ~/.aws/sso/cache (no network). Set AWS_REMOTE_AUTH_NO_LAUNCH=1 to detect without launching.
"""

import configparser
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

AWS_DIR = Path(os.environ.get("AWS_CONFIG_FILE", Path.home() / ".aws" / "config")).expanduser()
SSO_CACHE = Path.home() / ".aws" / "sso" / "cache"
PENDING_DIR = Path(tempfile.gettempdir()) / "aws-remote-auth"
PENDING_TTL = 9 * 60
SKEW = 60
AUTOFILL_RE = re.compile(r"(https?://\S*[?&]user_code=([A-Za-z0-9-]+))")


def resolve_profile(command=""):
    m = re.search(r"--profile[ =]([^\s\"']+)", command)
    if m:
        return m.group(1)
    return os.environ.get("AWS_PROFILE") or "default"


def _config():
    cp = configparser.ConfigParser(interpolation=None)
    if AWS_DIR.is_file():
        cp.read(AWS_DIR)
    return cp


def start_url_for(profile):
    cp = _config()
    section = "default" if profile == "default" else f"profile {profile}"
    if not cp.has_section(section):
        return None
    if cp.has_option(section, "sso_start_url"):
        return cp.get(section, "sso_start_url")
    if cp.has_option(section, "sso_session"):
        sess = f"sso-session {cp.get(section, 'sso_session')}"
        if cp.has_section(sess) and cp.has_option(sess, "sso_start_url"):
            return cp.get(sess, "sso_start_url")
    return None


def token_expiry(start_url):
    if not SSO_CACHE.is_dir():
        return None
    for f in SSO_CACHE.glob("*.json"):
        try:
            data = json.loads(f.read_text(encoding="utf-8"))
        except (ValueError, OSError):
            continue
        if data.get("startUrl") == start_url and data.get("accessToken") and data.get("expiresAt"):
            raw = data["expiresAt"].replace("Z", "+00:00")
            try:
                return datetime.fromisoformat(raw)
            except ValueError:
                return None
    return None


def is_valid(start_url):
    exp = token_expiry(start_url)
    return exp is not None and exp.timestamp() > time.time() + SKEW


def _pending_path(start_url):
    key = hashlib.sha256(start_url.encode()).hexdigest()[:16]
    return PENDING_DIR / f"{key}.json"


def start_device_login(profile, start_url):
    pending = _pending_path(start_url)
    if pending.is_file() and (time.time() - pending.stat().st_mtime) < PENDING_TTL:
        try:
            cached = json.loads(pending.read_text(encoding="utf-8"))
            if cached.get("url"):
                return cached["url"], cached.get("code", "")
        except (ValueError, OSError):
            pass

    PENDING_DIR.mkdir(parents=True, exist_ok=True)
    log = tempfile.NamedTemporaryFile("w+", dir=PENDING_DIR, suffix=".log", delete=False)
    log.close()
    with open(log.name, "w") as out:
        subprocess.Popen(
            ["aws", "sso", "login", "--profile", profile, "--use-device-code", "--no-browser"],
            stdout=out, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, start_new_session=True,
        )

    deadline = time.time() + 12
    while time.time() < deadline:
        text = Path(log.name).read_text(encoding="utf-8", errors="replace")
        m = AUTOFILL_RE.search(text)
        if m:
            url, code = m.group(1), m.group(2)
            pending.write_text(json.dumps({"url": url, "code": code}), encoding="utf-8")
            return url, code
        time.sleep(0.4)
    return None, None


def cmd_hook():
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        payload = {}
    command = (payload.get("tool_input") or {}).get("command", "")
    if not re.match(r"\s*aws\b", command):
        return
    profile = resolve_profile(command)
    start_url = start_url_for(profile)
    if start_url is None or is_valid(start_url):
        return

    if os.environ.get("AWS_REMOTE_AUTH_NO_LAUNCH"):
        url, code = "(no-launch)", "(no-launch)"
    else:
        url, code = start_device_login(profile, start_url)

    if url:
        reason = (f"AWS SSO for profile '{profile}' is expired. Authenticate (autofill, approve in any "
                  f"browser): {url}  — code {code}. Then re-run the command.")
    else:
        reason = (f"AWS SSO for profile '{profile}' is expired. Run: "
                  f"aws sso login --profile {profile} --use-device-code, then re-run the command.")
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": reason}}))


def cmd_login(profile, wait=False, timeout=600):
    start_url = start_url_for(profile)
    if start_url is None:
        print(f"❌ profile '{profile}' has no SSO config (sso_start_url / sso_session) in {AWS_DIR}", file=sys.stderr)
        sys.exit(1)
    if is_valid(start_url):
        print(f"✅ profile '{profile}' SSO session is still valid — no login needed.")
        return
    url, code = start_device_login(profile, start_url)
    if url:
        print(f"🔐 AWS SSO login for '{profile}' — approve in any browser:\n  {url}\n  code: {code}", flush=True)
    else:
        print(f"Started device login for '{profile}', but could not capture the code. "
              f"Run manually: aws sso login --profile {profile} --use-device-code", flush=True)
    if not wait:
        print("Once approved, re-run your command.")
        return
    print(f"⏳ waiting for approval (up to {timeout // 60} min)…", flush=True)
    deadline = time.time() + timeout
    while time.time() < deadline:
        if is_valid(start_url):
            print(f"✅ '{profile}' authenticated.")
            return
        time.sleep(3)
    print(f"⏳ timed out waiting for '{profile}' approval", file=sys.stderr)
    sys.exit(1)


def cmd_status(profile):
    start_url = start_url_for(profile)
    if start_url is None:
        print(f"profile '{profile}': not an SSO profile")
        return
    exp = token_expiry(start_url)
    if exp is None:
        print(f"profile '{profile}': no cached SSO token (login required) [{start_url}]")
    elif exp.timestamp() > time.time() + SKEW:
        print(f"profile '{profile}': valid until {exp.isoformat()} [{start_url}]")
    else:
        print(f"profile '{profile}': expired at {exp.isoformat()} (login required) [{start_url}]")


def main():
    sub = sys.argv[1] if len(sys.argv) > 1 else ""
    if sub == "hook":
        cmd_hook()
    elif sub == "login":
        rest = sys.argv[2:]
        prof = next((a for a in rest if not a.startswith("-")), None) or resolve_profile()
        cmd_login(prof, wait="--wait" in rest)
    elif sub == "status":
        cmd_status(sys.argv[2] if len(sys.argv) > 2 else resolve_profile())
    else:
        print("usage: sso-auth.py <hook|login [--wait]|status> [profile]", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
