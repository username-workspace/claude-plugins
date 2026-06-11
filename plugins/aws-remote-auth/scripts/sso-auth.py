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
$AWS_PROFILE, else 'default'). SSO config is resolved from BOTH ~/.aws/config and ~/.aws/credentials
(honouring AWS_CONFIG_FILE / AWS_SHARED_CREDENTIALS_FILE), across every layout: profiles declared in
either file, legacy `sso_start_url` keys, the `sso_session` token-provider format, and assume-role
chains via `source_profile`. Expiry is read locally from ~/.aws/sso/cache (no network). Set
AWS_REMOTE_AUTH_NO_LAUNCH=1 to detect without launching.
"""

import configparser
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path

SSO_CACHE = Path.home() / ".aws" / "sso" / "cache"
PENDING_DIR = Path.home() / ".aws" / "sso" / "remote-auth-pending"
PENDING_TTL = 9 * 60
SKEW = 60
AUTOFILL_RE = re.compile(r"(https?://\S*[?&]user_code=([A-Za-z0-9-]+))")


def _config_path():
    return Path(os.environ.get("AWS_CONFIG_FILE", Path.home() / ".aws" / "config")).expanduser()


def _creds_path():
    return Path(os.environ.get("AWS_SHARED_CREDENTIALS_FILE", Path.home() / ".aws" / "credentials")).expanduser()


def _read_ini(path):
    cp = configparser.ConfigParser(interpolation=None, strict=False)
    if path.is_file():
        try:
            cp.read(path, encoding="utf-8")
        except (configparser.Error, OSError, UnicodeDecodeError):
            pass
    return cp


def _load_profiles():
    profiles, sessions = {}, {}
    cfg = _read_ini(_config_path())
    for sect in cfg.sections():
        if sect.startswith("profile "):
            profiles.setdefault(sect[8:].strip(), {}).update(cfg.items(sect))
        elif sect.startswith("sso-session "):
            sessions.setdefault(sect[12:].strip(), {}).update(cfg.items(sect))
        else:
            profiles.setdefault(sect.strip(), {}).update(cfg.items(sect))
    crd = _read_ini(_creds_path())
    for sect in crd.sections():
        if sect.startswith("sso-session "):
            sessions.setdefault(sect[12:].strip(), {}).update(crd.items(sect))
        else:
            profiles.setdefault(sect.strip(), {}).update(crd.items(sect))
    return profiles, sessions


def resolve_profile(command=""):
    m = re.search(r"--profile[ =]([^\s\"']+)", command)
    if m:
        return m.group(1)
    return os.environ.get("AWS_PROFILE") or os.environ.get("AWS_DEFAULT_PROFILE") or "default"


def resolve_sso(profile, profiles=None, sessions=None, _seen=None):
    if profiles is None:
        profiles, sessions = _load_profiles()
    _seen = _seen if _seen is not None else set()
    if profile in _seen:
        return None
    _seen.add(profile)
    p = profiles.get(profile)
    if not p:
        return None
    if p.get("sso_start_url"):
        return {"start_url": p["sso_start_url"], "region": p.get("sso_region"), "login_profile": profile}
    if p.get("sso_session"):
        s = sessions.get(p["sso_session"], {})
        if s.get("sso_start_url"):
            return {"start_url": s["sso_start_url"], "region": s.get("sso_region"), "login_profile": profile}
        return None
    if p.get("source_profile"):
        return resolve_sso(p["source_profile"], profiles, sessions, _seen)
    return None


def token_expiry(start_url):
    # The same portal can have several cache files (legacy startUrl-hash + sso_session-name-hash,
    # or stale tokens never pruned). Take the FRESHEST match, not the first one the glob yields,
    # so a leftover expired token never masks a valid one (which would force a needless re-login).
    if not SSO_CACHE.is_dir():
        return None
    best = None
    for f in SSO_CACHE.glob("*.json"):
        try:
            data = json.loads(f.read_text(encoding="utf-8"))
        except (ValueError, OSError):
            continue
        cached = data.get("startUrl")
        if cached and cached.rstrip("/") == start_url.rstrip("/") and data.get("accessToken") and data.get("expiresAt"):
            raw = data["expiresAt"].replace("Z", "+00:00")
            try:
                exp = datetime.fromisoformat(raw)
            except ValueError:
                continue
            if best is None or exp > best:
                best = exp
    return best


def is_valid(start_url):
    exp = token_expiry(start_url)
    return exp is not None and exp.timestamp() > time.time() + SKEW


def _pending_path(start_url):
    key = hashlib.sha256(start_url.encode()).hexdigest()[:16]
    return PENDING_DIR / f"{key}.json"


def start_device_login(login_profile, start_url):
    pending = _pending_path(start_url)
    if pending.is_file() and (time.time() - pending.stat().st_mtime) < PENDING_TTL:
        try:
            cached = json.loads(pending.read_text(encoding="utf-8"))
            if cached.get("url"):
                return cached["url"], cached.get("code", "")
        except (ValueError, OSError):
            pass

    PENDING_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(PENDING_DIR, 0o700)
    log = tempfile.NamedTemporaryFile("w+", dir=PENDING_DIR, suffix=".log", delete=False)
    log.close()
    try:
        with open(log.name, "w") as out:
            subprocess.Popen(
                ["aws", "sso", "login", "--profile", login_profile, "--use-device-code", "--no-browser"],
                stdout=out, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, start_new_session=True,
            )
    except OSError:
        return None, None

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
    info = resolve_sso(profile)
    if info is None or is_valid(info["start_url"]) or shutil.which("aws") is None:
        return

    if os.environ.get("AWS_REMOTE_AUTH_NO_LAUNCH"):
        url, code = "(no-launch)", "(no-launch)"
    else:
        url, code = start_device_login(info["login_profile"], info["start_url"])

    if url:
        reason = (f"AWS SSO for profile '{profile}' is expired. Authenticate (autofill, approve in any "
                  f"browser): {url}  — code {code}. Then re-run the command.")
    else:
        reason = (f"AWS SSO for profile '{profile}' is expired. Run: "
                  f"aws sso login --profile {info['login_profile']} --use-device-code, then re-run the command.")
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": reason}}))


def cmd_login(profile, wait=False, timeout=600):
    info = resolve_sso(profile)
    if info is None:
        print(f"❌ profile '{profile}' has no resolvable SSO config (sso_start_url / sso_session / "
              f"source_profile) in {_config_path()} or {_creds_path()}", file=sys.stderr)
        sys.exit(1)
    start_url, login_profile = info["start_url"], info["login_profile"]
    if is_valid(start_url):
        print(f"✅ profile '{profile}' SSO session is still valid — no login needed.")
        return
    if shutil.which("aws") is None:
        print("❌ AWS CLI not found on PATH. Install AWS CLI v2 (device-code login requires it).", file=sys.stderr)
        sys.exit(1)
    url, code = start_device_login(login_profile, start_url)
    if url:
        print(f"🔐 AWS SSO login for '{profile}' — approve in any browser:\n  {url}\n  code: {code}", flush=True)
    else:
        print(f"Started device login for '{profile}', but could not capture the code (needs AWS CLI v2). "
              f"Run manually: aws sso login --profile {login_profile}", flush=True)
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
    info = resolve_sso(profile)
    if info is None:
        print(f"profile '{profile}': not an SSO profile")
        return
    start_url = info["start_url"]
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
