#!/usr/bin/env bash
# aws-remote-auth test suite — drives the PreToolUse hook + resolver surface on a hermetic
# ~/.aws sandbox. A stubbed `aws` on PATH simulates the device-code login (and its absence);
# the SSO cache is seeded with fixture tokens so expiry detection is deterministic — no network,
# no real AWS, no live device-code flow.
set -u
SSO="$(cd "$(dirname "$0")/.." && pwd)/scripts/sso-auth.py"
ROOT="$(mktemp -d)"
PASS=0; FAIL=0

ok(){ PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
ko(){ FAIL=$((FAIL+1)); printf '  \033[31m✗ %s\033[0m\n' "$1"; }
assert_contains(){ case "$2" in *"$1"*) ok "$3";; *) ko "$3 — expected to contain [$1] in [$2]";; esac; }
assert_absent(){ case "$2" in *"$1"*) ko "$3 — unexpected [$1]";; *) ok "$3";; esac; }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || ko "$3 — expected [$1] got [$2]"; }

# --- hermetic ~/.aws sandbox (HOME drives the non-overridable sso/cache path) ---
HOME_DIR="$ROOT/home"; AWS="$HOME_DIR/.aws"; CACHE="$AWS/sso/cache"
mkdir -p "$CACHE"
export HOME="$HOME_DIR"
export AWS_CONFIG_FILE="$AWS/config"
export AWS_SHARED_CREDENTIALS_FILE="$AWS/credentials"
unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_REMOTE_AUTH_NO_LAUNCH

cat > "$AWS/config" <<'EOF'
[profile dev]
sso_start_url = https://my.awsapps.com/start
sso_region = eu-west-1
sso_account_id = 111
sso_role_name = Admin
region = eu-west-3

[profile chained]
source_profile = dev
role_arn = arn:aws:iam::222:role/Foo

[profile sess]
sso_session = corp
sso_account_id = 333
sso_role_name = Admin

[sso-session corp]
sso_start_url = https://corp.awsapps.com/start
sso_region = us-east-1

[profile plain]
region = eu-west-3

[profile cyca]
source_profile = cycb

[profile cycb]
source_profile = cyca
EOF

# --- stub aws on PATH: emits a device-code autofill URL, counts `sso login` invocations ---
BIN="$ROOT/bin"; mkdir -p "$BIN"
AWS_CALLS="$ROOT/aws-sso-login.log"; : > "$AWS_CALLS"
cat > "$BIN/aws" <<EOF
#!/usr/bin/env bash
if [ "\$1 \$2" = "sso login" ]; then
  echo "\$@" >> "$AWS_CALLS"
  echo "Attempting to automatically open the SSO authorization page in your default browser."
  echo "If the browser does not open, open this URL:"
  echo "https://device.sso.eu-west-1.amazonaws.com/?user_code=WXYZ-7788"
fi
exit 0
EOF
chmod +x "$BIN/aws"
# a minimal real-tool PATH so `which(aws)` is the only forge-presence variable under test
REAL="$ROOT/realbin"; mkdir -p "$REAL"
for t in python3 bash env rm cat; do ln -sf "$(command -v "$t")" "$REAL/$t" 2>/dev/null; done
export PATH="$BIN:$REAL:$PATH"

now_plus(){ python3 -c "import datetime,sys;print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(seconds=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1"; }
seed_token(){ printf '{"startUrl":"%s","accessToken":"tok","expiresAt":"%s"}\n' "$1" "$2" > "$CACHE/token.json"; }
clear_cache(){ rm -f "$CACHE"/*.json 2>/dev/null || true; }
clear_pending(){ rm -rf "$(python3 -c 'import tempfile,os;print(os.path.join(tempfile.gettempdir(),"aws-remote-auth"))')"; }
hook(){ printf '%s' "$1" | python3 "$SSO" hook 2>&1; }

echo "aws-remote-auth tests"

# 1. expired token on an aws command → deny with autofill URL + code captured from `aws`
clear_pending; clear_cache; seed_token "https://my.awsapps.com/start" "$(now_plus -3600)"
out=$(hook '{"tool_input":{"command":"aws s3 ls --profile dev"}}')
assert_contains '"permissionDecision": "deny"' "$out" "1. expired token → deny decision"
assert_contains 'profile '\''dev'\'' is expired' "$out" "1. names the expired profile"
assert_contains 'user_code=WXYZ-7788' "$out" "1. autofill URL surfaced in the reason"
assert_contains 'code WXYZ-7788' "$out" "1. device code surfaced in the reason"
assert_eq 1 "$(wc -l < "$AWS_CALLS" | tr -d ' ')" "1. triggered exactly one aws sso login"
assert_contains '--use-device-code' "$(cat "$AWS_CALLS")" "1. login used --use-device-code"
assert_contains '--no-browser' "$(cat "$AWS_CALLS")" "1. login used --no-browser"
assert_contains '--profile dev' "$(cat "$AWS_CALLS")" "1. login targeted the resolved profile"

# 2. valid (far-future) token → pass through, no deny, no login launched
clear_pending; clear_cache; : > "$AWS_CALLS"; seed_token "https://my.awsapps.com/start" "$(now_plus 36000)"
out=$(hook '{"tool_input":{"command":"aws s3 ls --profile dev"}}')
assert_eq "" "$out" "2. valid session → silent pass-through"
assert_eq 0 "$(wc -l < "$AWS_CALLS" | tr -d ' ')" "2. no login launched on a valid session"

# 3. missing token (no cache) → treated as expired → deny
clear_pending; clear_cache
out=$(hook '{"tool_input":{"command":"aws s3 ls --profile dev"}}')
assert_contains '"permissionDecision": "deny"' "$out" "3. missing token → deny"

# 4. non-aws command → never touches AWS, passes through
clear_pending; clear_cache; : > "$AWS_CALLS"
out=$(hook '{"tool_input":{"command":"kubectl get pods --profile dev"}}')
assert_eq "" "$out" "4. non-aws command → pass-through"
assert_eq 0 "$(wc -l < "$AWS_CALLS" | tr -d ' ')" "4. non-aws command → no login launched"

# 5. word-boundary: an `aws`-prefixed token that is not the aws CLI must not trigger
out=$(hook '{"tool_input":{"command":"awscli-wrapper deploy"}}')
assert_eq "" "$out" "5. awscli-wrapper (no \\b) → not treated as aws"

# 6. leading whitespace before aws is still matched (re allows \\s*aws\\b)
clear_pending; clear_cache
out=$(hook '{"tool_input":{"command":"   aws s3 ls --profile dev"}}')
assert_contains '"permissionDecision": "deny"' "$out" "6. leading whitespace still matches aws"

# 7. aws subcommand with a VALID session → no trigger even though it is an aws command
clear_pending; clear_cache; seed_token "https://my.awsapps.com/start" "$(now_plus 36000)"
out=$(hook '{"tool_input":{"command":"aws sts get-caller-identity --profile dev"}}')
assert_eq "" "$out" "7. valid aws subcommand → no re-auth nag"

# 8. profile resolution: --profile in the command wins; expiry checked for THAT profile
clear_pending; clear_cache; seed_token "https://corp.awsapps.com/start" "$(now_plus -10)"
out=$(hook '{"tool_input":{"command":"aws s3 ls --profile sess"}}')
assert_contains "profile 'sess' is expired" "$out" "8. --profile sess resolved via sso_session"

# 9. profile from $AWS_PROFILE when the command has no --profile
clear_pending; clear_cache; seed_token "https://my.awsapps.com/start" "$(now_plus -10)"
out=$(AWS_PROFILE=dev python3 "$SSO" hook <<<'{"tool_input":{"command":"aws s3 ls"}}' 2>&1)
assert_contains "profile 'dev' is expired" "$out" "9. profile falls back to \$AWS_PROFILE"

# 10. profile with NO resolvable SSO config (plain creds profile) → pass through
clear_pending; clear_cache
out=$(hook '{"tool_input":{"command":"aws s3 ls --profile plain"}}')
assert_eq "" "$out" "10. non-SSO profile → pass-through (nothing to re-auth)"

# 11. unknown profile (not in config) → pass through
out=$(hook '{"tool_input":{"command":"aws s3 ls --profile ghost"}}')
assert_eq "" "$out" "11. unknown profile → pass-through"

# 12. malformed payloads never crash, never deny
clear_pending; clear_cache; seed_token "https://my.awsapps.com/start" "$(now_plus -10)"
assert_eq "" "$(hook 'not-json{{{')" "12a. malformed JSON → pass-through"
assert_eq "" "$(printf '' | python3 "$SSO" hook 2>&1)" "12b. empty stdin → pass-through"
assert_eq "" "$(hook '{}')" "12c. missing tool_input → pass-through"
assert_eq "" "$(hook '{"tool_input":null}')" "12d. null tool_input → pass-through"
assert_eq "" "$(hook '{"tool_input":{}}')" "12e. missing command → pass-through"

# 13. aws CLI absent on PATH → pass through (cannot device-code login without it)
clear_pending; clear_cache; seed_token "https://my.awsapps.com/start" "$(now_plus -10)"
out=$(env PATH="$REAL" HOME="$HOME" AWS_CONFIG_FILE="$AWS_CONFIG_FILE" \
        AWS_SHARED_CREDENTIALS_FILE="$AWS_SHARED_CREDENTIALS_FILE" \
        python3 "$SSO" hook <<<'{"tool_input":{"command":"aws s3 ls --profile dev"}}' 2>&1)
assert_eq "" "$out" "13. aws not on PATH → pass-through (no deny)"

# 14. NO_LAUNCH detection: deny without ever spawning a login
clear_pending; clear_cache; : > "$AWS_CALLS"; seed_token "https://my.awsapps.com/start" "$(now_plus -10)"
out=$(AWS_REMOTE_AUTH_NO_LAUNCH=1 python3 "$SSO" hook <<<'{"tool_input":{"command":"aws s3 ls --profile dev"}}' 2>&1)
assert_contains '"permissionDecision": "deny"' "$out" "14. NO_LAUNCH → still detects + denies"
assert_contains '(no-launch)' "$out" "14. NO_LAUNCH placeholder used instead of a real code"
assert_eq 0 "$(wc -l < "$AWS_CALLS" | tr -d ' ')" "14. NO_LAUNCH → aws sso login NOT spawned"

# 15. pending-cache reuse: a second expired hook reuses the captured URL, no relaunch
clear_pending; clear_cache; : > "$AWS_CALLS"; seed_token "https://my.awsapps.com/start" "$(now_plus -10)"
hook '{"tool_input":{"command":"aws s3 ls --profile dev"}}' >/dev/null
hook '{"tool_input":{"command":"aws s3 ls --profile dev"}}' >/dev/null
assert_eq 1 "$(wc -l < "$AWS_CALLS" | tr -d ' ')" "15. pending cache → only one login across two denies"

# 16. emitted hook payload is well-formed JSON for the PreToolUse contract
clear_pending; clear_cache; seed_token "https://my.awsapps.com/start" "$(now_plus -10)"
out=$(hook '{"tool_input":{"command":"aws s3 ls --profile dev"}}')
echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin)["hookSpecificOutput"]; assert d["hookEventName"]=="PreToolUse"; assert d["permissionDecision"]=="deny"; assert d["permissionDecisionReason"]' \
  && ok "16. deny payload is valid PreToolUse JSON" || ko "16. deny payload is valid PreToolUse JSON"

# 17. unit: resolver + autofill regex + pending key (driven through the module directly)
cat > "$ROOT/unit.py" <<'PY'
import importlib.util, os, hashlib
spec = importlib.util.spec_from_file_location("sso", os.environ["SSO"])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
def check(c, msg): print(("PASS " if c else "FAIL ") + "17. " + msg)

check(m.resolve_profile("aws s3 ls --profile dev") == "dev", "resolve_profile: --profile X")
check(m.resolve_profile("aws s3 ls --profile=dev") == "dev", "resolve_profile: --profile=X")
check(m.resolve_profile("aws s3 ls") == "default", "resolve_profile: default fallback")
os.environ["AWS_DEFAULT_PROFILE"] = "ddp"
check(m.resolve_profile("aws s3 ls") == "ddp", "resolve_profile: $AWS_DEFAULT_PROFILE fallback")
del os.environ["AWS_DEFAULT_PROFILE"]

check(m.resolve_sso("dev")["start_url"] == "https://my.awsapps.com/start", "resolve_sso: sso_start_url profile")
ch = m.resolve_sso("chained")
check(ch["start_url"] == "https://my.awsapps.com/start" and ch["login_profile"] == "dev", "resolve_sso: source_profile chain → parent start_url, parent login")
se = m.resolve_sso("sess")
check(se["start_url"] == "https://corp.awsapps.com/start" and se["region"] == "us-east-1", "resolve_sso: sso_session token-provider format")
check(se["login_profile"] == "sess", "resolve_sso: sso_session login stays on the requesting profile")
check(m.resolve_sso("plain") is None, "resolve_sso: non-SSO profile → None")
check(m.resolve_sso("ghost") is None, "resolve_sso: unknown profile → None")
check(m.resolve_sso("cyca") is None, "resolve_sso: source_profile cycle → None (no infinite loop)")

u = "https://device.sso.us-east-1.amazonaws.com/?user_code=ABCD-1234"
g = m.AUTOFILL_RE.search("see " + u + " now")
check(g and g.group(1) == u and g.group(2) == "ABCD-1234", "AUTOFILL_RE: extracts full URL + code")
check(m.AUTOFILL_RE.search("https://x/?foo=bar") is None, "AUTOFILL_RE: no user_code → no match")

start = "https://my.awsapps.com/start"
expect = hashlib.sha256(start.encode()).hexdigest()[:16] + ".json"
check(m._pending_path(start).name == expect, "_pending_path: sha256[:16]-keyed per start_url")
check(m._pending_path(start) != m._pending_path("https://other/start"), "_pending_path: distinct per portal")

check(m.is_valid("https://my.awsapps.com/start") is False, "is_valid: within-SKEW token (seeded) is not valid")
PY
clear_cache; seed_token "https://my.awsapps.com/start" "$(now_plus 30)"
while IFS= read -r line; do
  case "$line" in PASS*) ok "${line#PASS }";; FAIL*) ko "${line#FAIL }";; esac
done < <(SSO="$SSO" python3 "$ROOT/unit.py")

# 18. status subcommand mirrors the local validity check (no network)
clear_cache; seed_token "https://my.awsapps.com/start" "$(now_plus -3600)"
assert_contains 'expired' "$(python3 "$SSO" status dev)" "18a. status → expired"
clear_cache; seed_token "https://my.awsapps.com/start" "$(now_plus 36000)"
assert_contains 'valid until' "$(python3 "$SSO" status dev)" "18b. status → valid"
clear_cache
assert_contains 'no cached SSO token' "$(python3 "$SSO" status dev)" "18c. status → no token"
assert_contains 'not an SSO profile' "$(python3 "$SSO" status plain)" "18d. status → non-SSO profile"

# 18e. several cache files for one portal → the FRESHEST token wins; a leftover expired one
# must never mask a valid one (a false "expired" would force a needless re-login), any glob order
clear_cache
printf '{"startUrl":"https://my.awsapps.com/start","accessToken":"old","expiresAt":"%s"}\n' "$(now_plus -3600)" > "$CACHE/stale.json"
printf '{"startUrl":"https://my.awsapps.com/start","accessToken":"new","expiresAt":"%s"}\n' "$(now_plus 36000)" > "$CACHE/zzz_fresh.json"
assert_contains 'valid until' "$(python3 "$SSO" status dev)" "18e. freshest of several cache files wins (no false expired)"
clear_cache
printf '{"startUrl":"https://my.awsapps.com/start","accessToken":"new","expiresAt":"%s"}\n' "$(now_plus 36000)" > "$CACHE/aaa_fresh.json"
printf '{"startUrl":"https://my.awsapps.com/start","accessToken":"old","expiresAt":"%s"}\n' "$(now_plus -3600)" > "$CACHE/zzz_stale.json"
assert_contains 'valid until' "$(python3 "$SSO" status dev)" "18e. order-independent: stale-first still resolves valid"

# 19. CLI usage contract: unknown/blank subcommand → usage on stderr, exit 2
out=$(python3 "$SSO" bogus 2>&1); rc=$?
assert_contains 'usage: sso-auth.py' "$out" "19a. unknown subcommand → usage"
assert_eq 2 "$rc" "19b. unknown subcommand → exit 2"
python3 "$SSO" >/dev/null 2>&1; assert_eq 2 "$?" "19c. no subcommand → exit 2"

echo
echo "PASS=$PASS FAIL=$FAIL"
rm -rf "$ROOT"
[ "$FAIL" -eq 0 ]
