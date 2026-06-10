#!/usr/bin/env bash
# security-audit test suite — exercises Trivy-JSON parsing, severity prioritization, prod-vs-tooling
# separation, multi-folder aggregation, and the Markdown + HTML reports. A stubbed `trivy` on PATH
# emits fixture JSON so the parse/prioritize/render path runs deterministically without real Trivy.
set -u
AUDIT="$(cd "$(dirname "$0")/.." && pwd)/scripts/audit.py"
ROOT="$(mktemp -d)"
PASS=0; FAIL=0

PY="$(command -v python3)"
mkdir -p "$ROOT/realbin"
for b in python3 git bash cat; do ln -sf "$(command -v "$b")" "$ROOT/realbin/$b"; done

CACHE="$ROOT/cache"; mkdir -p "$CACHE"
export TRIVY_CACHE_DIR="$CACHE"

ok(){ PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
ko(){ FAIL=$((FAIL+1)); printf '  \033[31m✗ %s\033[0m\n' "$1"; }
assert_contains(){ case "$2" in *"$1"*) ok "$3";; *) ko "$3 — expected to contain [$1]";; esac; }
assert_absent(){ case "$2" in *"$1"*) ko "$3 — unexpected [$1]";; *) ok "$3";; esac; }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || ko "$3 — expected [$1] got [$2]"; }
assert_before(){ # $1 needle-A $2 needle-B $3 haystack $4 msg : A must appear before B
  local a b; a=$(printf '%s' "$3" | grep -n -- "$1" | head -1 | cut -d: -f1)
  b=$(printf '%s' "$3" | grep -n -- "$2" | head -1 | cut -d: -f1)
  { [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; } && ok "$4" || ko "$4 — [$1]@$a not before [$2]@$b"
}

# --- stub trivy on PATH: routes fixture JSON from <scanned-dir>/.trivy-fixture.json ---
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/trivy" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then echo "Version: 0.50.0"; exit 0; fi
for a in "$@"; do last="$a"; done
case " $* " in *" --download-db-only "*) exit 0;; esac
fx="$last/.trivy-fixture.json"
if [ -f "$fx" ]; then cat "$fx"; exit 0; fi
echo '{"Results":[]}'; exit 0
STUB
chmod +x "$ROOT/bin/trivy"
STUBPATH="$ROOT/bin:$ROOT/realbin"

mkrepo(){ mkdir -p "$ROOT/$1"; [ -n "${2:-}" ] && printf '%s' "$2" > "$ROOT/$1/.trivy-fixture.json"; }
audit(){ env PATH="$STUBPATH" "$PY" "$AUDIT" --no-version-check "$@" 2>&1; }

echo "security-audit tests"

# ============================================================================
# Python unit block — parse / prioritize / render on fixture JSON, direct calls.
# ============================================================================
cat > "$ROOT/unit.py" <<'PY'
import importlib.util, os, re
spec = importlib.util.spec_from_file_location("audit", os.environ["AUDIT"])
audit = importlib.util.module_from_spec(spec); spec.loader.exec_module(audit)
def check(c, m): print(("PASS " if c else "FAIL ") + m)

# severity prioritization: CRITICAL → HIGH → MEDIUM → LOW → UNKNOWN
items = [{"sev": s} for s in ("LOW", "unknown", "CRITICAL", "MEDIUM", "HIGH")]
order = [x["sev"] for x in audit.by_severity(items)]
check(order == ["CRITICAL", "HIGH", "MEDIUM", "LOW", "unknown"], "U. by_severity orders CRITICAL→…→UNKNOWN (case-insensitive)")
check(audit.SEV_ORDER["CRITICAL"] < audit.SEV_ORDER["LOW"], "U. SEV_ORDER ranks CRITICAL above LOW")

# collect: all three result classes parsed into their buckets
data = {"Results": [
    {"Target": "package-lock.json", "Class": "lang-pkgs", "Vulnerabilities": [
        {"Severity": "CRITICAL", "VulnerabilityID": "CVE-1", "PkgName": "lodash",
         "InstalledVersion": "1.0", "FixedVersion": "1.1", "PrimaryURL": "http://a"},
        {"Severity": "HIGH", "VulnerabilityID": "CVE-2", "PkgName": "axios",
         "InstalledVersion": "2.0", "FixedVersion": "", "PrimaryURL": ""}]},
    {"Target": "Dockerfile", "Class": "config", "Misconfigurations": [
        {"Severity": "MEDIUM", "ID": "DS002", "Title": "root user"}]},
    {"Target": ".env", "Class": "secret", "Secrets": [
        {"Severity": "CRITICAL", "RuleID": "aws-key", "Title": "k", "StartLine": 3}]},
]}
v, s, m, dt = audit.collect(data)
check(len(v) == 2 and len(s) == 1 and len(m) == 1, "U. collect buckets vuln/secret/misconfig by class")
check(dt == {"package-lock.json"}, "U. collect records only lang-pkgs targets as dep_targets")
check(s[0]["target"] == ".env:3", "U. secret location is target:StartLine")
check(m[0]["id"] == "DS002" and v[0]["fixed"] == "1.1", "U. misconfig ID + vuln FixedVersion mapped")

# id/rule fallbacks: AVDID when ID missing, Category when RuleID missing
fb = {"Results": [
    {"Target": "main.tf", "Class": "config", "Misconfigurations": [
        {"Severity": "HIGH", "AVDID": "AVD-AWS-0001", "Title": "open sg"}]},
    {"Target": "cfg.yaml", "Class": "secret", "Secrets": [
        {"Severity": "HIGH", "Category": "general", "Title": "t", "StartLine": 9}]},
]}
v2, s2, m2, _ = audit.collect(fb)
check(m2[0]["id"] == "AVD-AWS-0001", "U. misconfig falls back to AVDID when ID absent")
check(s2[0]["rule"] == "general", "U. secret falls back to Category when RuleID absent")

# missing-field defaults: UNKNOWN severity, '?' ids
defs = {"Results": [{"Target": "x", "Class": "lang-pkgs", "Vulnerabilities": [{}]}]}
vd, _, _, _ = audit.collect(defs)
check(vd[0]["sev"] == "UNKNOWN" and vd[0]["id"] == "?" and vd[0]["pkg"] == "?", "U. absent vuln fields default to UNKNOWN/?")

# classify_vulns: a lockfile nested under another of the SAME kind is tooling (secondary)
vc = [
    {"sev": "HIGH", "target": "package-lock.json"},
    {"sev": "LOW", "target": "vendor/magento/update/package-lock.json"},
    {"sev": "MEDIUM", "target": "composer.lock"},
]
audit.classify_vulns(vc, {"package-lock.json", "vendor/magento/update/package-lock.json", "composer.lock"})
flags = {x["target"]: x["primary"] for x in vc}
check(flags["package-lock.json"] is True, "U. root lockfile classified prod (primary)")
check(flags["vendor/magento/update/package-lock.json"] is False, "U. nested same-kind lockfile classified tooling")
check(flags["composer.lock"] is True, "U. lone composer.lock stays prod")

# classify_vulns: different lockfile kinds nested don't cross-suppress
vk = [{"sev": "HIGH", "target": "sub/yarn.lock"}, {"sev": "HIGH", "target": "package-lock.json"}]
audit.classify_vulns(vk, {"sub/yarn.lock", "package-lock.json"})
check(all(x["primary"] for x in vk), "U. distinct lockfile kinds are both prod (no cross-suppression)")

# classify_vulns: with no dep_targets every vuln defaults to primary
vn = [{"sev": "HIGH", "target": "Dockerfile"}]
audit.classify_vulns(vn, set())
check(vn[0]["primary"] is True, "U. vuln outside any lockfile defaults to prod")

# report counts + section ordering on a mixed dataset
mv = [
    {"sev": "CRITICAL", "id": "CVE-1", "url": "http://a", "pkg": "lodash", "installed": "1.0", "fixed": "1.1", "target": "package-lock.json"},
    {"sev": "HIGH", "id": "CVE-2", "url": "", "pkg": "axios", "installed": "2.0", "fixed": "", "target": "package-lock.json"},
    {"sev": "LOW", "id": "CVE-3", "url": "", "pkg": "tool", "installed": "1", "fixed": "2", "target": "sub/update/package-lock.json"},
]
audit.classify_vulns(mv, {"package-lock.json", "sub/update/package-lock.json"})
ms = [{"sev": "CRITICAL", "rule": "aws-key", "title": "k", "target": ".env:3"}]
mm = [{"sev": "MEDIUM", "id": "DS002", "title": "root user", "target": "Dockerfile"}]
md = audit.report(".", mv, ms, mm, 100, "foot", None)
check("**5 findings**" in md, "U. report header totals all classes")
check("2 critical · 1 high · 1 medium · 1 low" in md, "U. severity tally line ordered crit→low")
check("vulnerabilities: 2 prod (1 fixable) · 1 in nested sub-projects" in md, "U. prod/fixable/nested summary")
check("secrets: 1 · misconfig: 1" in md, "U. secret + misconfig summary counts")
for sec in ("## Vulnerabilities — fixable", "## Vulnerabilities — no fix available",
            "## Vulnerabilities — nested sub-projects", "## Secrets", "## Misconfigurations (IaC)"):
    check(sec in md, f"U. report has section [{sec[:32].strip('# ')}]")
check(md.index("## Vulnerabilities — fixable") < md.index("## Vulnerabilities — no fix") < md.index("## Vulnerabilities — nested sub-projects"), "U. vuln sections ordered fixable→nofix→nested")
check(md.index("## Secrets") < md.index("## Misconfigurations"), "U. secrets section precedes misconfig")
check("**1.1**" in md and "`lodash`" in md, "U. fixable row bolds the fixed version")
check("[CVE-1](http://a)" in md, "U. advisory linked when URL present")
check("| HIGH | `axios` |" in md, "U. unfixable vuln rendered without a fixed column")
check("sub/update/package-lock.json" in md.split("## Vulnerabilities — nested sub-projects")[1], "U. nested vuln lands in the nested section")

# empty / clean repo report
clean = audit.report(".", [], [], [], 100, "foot", None)
check("**0 findings**" in clean and "none" in clean, "U. clean repo → 0 findings / none")
check("No findings at the requested severities. ✅" in clean, "U. clean repo prints the all-clear line")
check("## Vulnerabilities" not in clean, "U. clean repo emits no finding sections")

# warning passthrough
warned = audit.report(".", [], [], [], 100, "foot", "DB stale, reconnect")
check("[!WARNING]" in warned and "DB stale, reconnect" in warned, "U. db warning surfaced as a callout")

# secret-only and misconfig-only single-class reports
so = audit.report(".", [], ms, [], 100, "foot", None)
check("## Secrets" in so and "## Vulnerabilities" not in so and "## Misconfigurations" not in so, "U. secret-only report shows only the Secrets section")
mo = audit.report(".", [], [], mm, 100, "foot", None)
check("## Misconfigurations (IaC)" in mo and "## Secrets" not in mo, "U. misconfig-only report shows only the IaC section")

# table --limit truncation
many = []
for i in range(5):
    many.append({"sev": "HIGH", "id": f"CVE-{i}", "url": "", "pkg": f"p{i}", "installed": "1", "fixed": "2", "target": "package-lock.json"})
audit.classify_vulns(many, {"package-lock.json"})
lim = audit.report(".", many, [], [], 2, "foot", None)
check("_+3 more (raise --limit)_" in lim, "U. report truncates rows past --limit with a +N more marker")

# no dedup: identical findings are NOT collapsed (documents actual behavior)
dup_data = {"Results": [{"Target": "package-lock.json", "Class": "lang-pkgs", "Vulnerabilities": [
    {"Severity": "HIGH", "VulnerabilityID": "CVE-9", "PkgName": "x", "InstalledVersion": "1", "FixedVersion": "2", "PrimaryURL": ""},
    {"Severity": "HIGH", "VulnerabilityID": "CVE-9", "PkgName": "x", "InstalledVersion": "1", "FixedVersion": "2", "PrimaryURL": ""}]}]}
dv, _, _, _ = audit.collect(dup_data)
check(len(dv) == 2, "U. duplicate findings are kept (collect does not dedup)")

# cell() escapes pipes and flattens newlines so table rows stay intact
check(audit.cell("a|b\nc") == "a\\|b c", "U. cell escapes | and flattens newlines")

# HTML dashboard: KPIs, badges, sections, escaping
hv = list(mv)
h = audit.report_html(".", hv, ms, mm, "foot", None)
check("<!DOCTYPE html>" in h and "<title>Security audit — ." in h, "H. HTML doc + title")
check('<h1><em>5</em> findings</h1>' in h, "H. headline findings count")
check('<div class="value">2</div><div class="label">critical</div>' in h, "H. critical KPI")
check('<div class="value">1/2</div><div class="label">vulns fixable</div>' in h, "H. fixable/prod KPI excludes nested")
check('<div class="value">1</div><div class="label">nested (tooling)</div>' in h, "H. nested-tooling KPI present")
check('<div class="value">1</div><div class="label">secrets</div>' in h, "H. secrets KPI")
check('class="sev crit"' in h and 'class="sev high"' in h, "H. severity badge classes mapped")
check("Vulnerabilities — fixable" in h and "Misconfigurations (IaC)" in h, "H. fixable + IaC sections rendered")
check('<span class="fix">1.1</span>' in h, "H. fixed version highlighted")
check('<a href="http://a">CVE-1</a>' in h, "H. advisory anchored when URL present")

# HTML escaping of an injected target
xss = [{"sev": "HIGH", "id": "<x>", "url": "", "pkg": "p", "installed": "1", "fixed": "", "target": "a<b>&c"}]
audit.classify_vulns(xss, set())
hx = audit.report_html(".", xss, [], [], "foot", None)
check("a&lt;b&gt;&amp;c" in hx and "<b>&c" not in hx.split("footer")[0].split("a&lt;")[0][-40:], "H. target HTML-escaped (no raw injection)")

# HTML empty state
he = audit.report_html(".", [], [], [], "foot", None)
check('class="empty"' in he and "<em>0</em> findings" in he, "H. empty HTML shows 0 findings + empty notice")
PY

while IFS= read -r line; do
  case "$line" in PASS*) ok "${line#PASS }";; FAIL*) ko "${line#FAIL }";; esac
done < <(env AUDIT="$AUDIT" "$PY" "$ROOT/unit.py")

# ============================================================================
# End-to-end CLI block — main() driven through the stubbed trivy.
# ============================================================================

# E1. single folder, mixed findings → prioritized Markdown, deterministic footer (empty cache)
mkrepo single '{"Results":[
 {"Target":"package-lock.json","Class":"lang-pkgs","Vulnerabilities":[
   {"Severity":"CRITICAL","VulnerabilityID":"CVE-A","PkgName":"lodash","InstalledVersion":"1.0","FixedVersion":"1.1","PrimaryURL":"http://a"},
   {"Severity":"MEDIUM","VulnerabilityID":"CVE-B","PkgName":"axios","InstalledVersion":"2.0","FixedVersion":"","PrimaryURL":""}]},
 {"Target":".env","Class":"secret","Secrets":[{"Severity":"HIGH","RuleID":"aws-key","Title":"k","StartLine":2}]},
 {"Target":"main.tf","Class":"config","Misconfigurations":[{"Severity":"LOW","ID":"AVD-1","Title":"no tags"}]}]}'
out=$(audit "$ROOT/single")
assert_contains '**4 findings**' "$out" "E1. totals every finding class"
assert_contains '1 critical · 1 high · 1 medium · 1 low' "$out" "E1. severity tally ordered crit→low"
assert_contains 'vuln DB: age unknown' "$out" "E1. empty cache → deterministic 'age unknown' footer"
assert_absent '[!WARNING]' "$out" "E1. no DB-stale warning with empty cache"
assert_before 'Vulnerabilities — fixable' 'Secrets' "$out" "E1. vulns rendered before secrets"
assert_before 'Secrets' 'Misconfigurations' "$out" "E1. secrets rendered before misconfig"
assert_contains 'scanner: Trivy 0.50.0' "$out" "E1. footer reports stubbed trivy version"

# E2. clean repo (no findings) → all-clear, exit 0
mkrepo clean '{"Results":[]}'
out=$(audit "$ROOT/clean"); rc=$?
assert_contains '**0 findings**' "$out" "E2. clean repo → 0 findings"
assert_contains 'No findings at the requested severities. ✅' "$out" "E2. all-clear line"
assert_eq 0 "$rc" "E2. clean scan exits 0"

# E3. prod-vs-tooling separation surfaces through main()
mkrepo nested '{"Results":[
 {"Target":"package-lock.json","Class":"lang-pkgs","Vulnerabilities":[
   {"Severity":"HIGH","VulnerabilityID":"CVE-P","PkgName":"prod","InstalledVersion":"1","FixedVersion":"2","PrimaryURL":""}]},
 {"Target":"tools/update/package-lock.json","Class":"lang-pkgs","Vulnerabilities":[
   {"Severity":"LOW","VulnerabilityID":"CVE-T","PkgName":"tooling","InstalledVersion":"1","FixedVersion":"","PrimaryURL":""}]}]}'
out=$(audit "$ROOT/nested")
assert_contains '1 prod (1 fixable) · 1 in nested sub-projects' "$out" "E3. prod vs nested split in summary"
assert_contains 'Vulnerabilities — nested sub-projects' "$out" "E3. nested section emitted"
assert_contains 'tools/update/package-lock.json' "$out" "E3. tooling target shown in nested section"

# E4. multi-folder aggregation → targets prefixed with folder label
mkrepo mfa '{"Results":[{"Target":"package-lock.json","Class":"lang-pkgs","Vulnerabilities":[
   {"Severity":"CRITICAL","VulnerabilityID":"CVE-A","PkgName":"a","InstalledVersion":"1","FixedVersion":"2","PrimaryURL":""}]}]}'
mkrepo mfb '{"Results":[{"Target":".env","Class":"secret","Secrets":[
   {"Severity":"HIGH","RuleID":"key","Title":"k","StartLine":5}]}]}'
out=$(audit "$ROOT/mfa" "$ROOT/mfb")
assert_contains '**2 findings**' "$out" "E4. findings aggregated across folders"
assert_contains 'mfa/package-lock.json' "$out" "E4. folder-A target prefixed with label"
assert_contains 'mfb/.env:5' "$out" "E4. folder-B secret prefixed with label"

# E5. secrets-only target → only the Secrets section
mkrepo seconly '{"Results":[{"Target":".env","Class":"secret","Secrets":[
   {"Severity":"CRITICAL","RuleID":"private-key","Title":"pk","StartLine":1}]}]}'
out=$(audit "$ROOT/seconly")
assert_contains '## Secrets' "$out" "E5. secrets-only → Secrets section"
assert_absent '## Vulnerabilities' "$out" "E5. secrets-only → no vuln section"
assert_absent '## Misconfigurations' "$out" "E5. secrets-only → no misconfig section"

# E6. IaC-only target → only the Misconfigurations section, severity-ordered
mkrepo iaconly '{"Results":[{"Target":"main.tf","Class":"config","Misconfigurations":[
   {"Severity":"LOW","AVDID":"AVD-LOW","Title":"low issue"},
   {"Severity":"CRITICAL","ID":"AVD-CRIT","Title":"open to world"}]}]}'
out=$(audit "$ROOT/iaconly")
assert_contains '## Misconfigurations (IaC)' "$out" "E6. IaC-only → Misconfigurations section"
assert_absent '## Secrets' "$out" "E6. IaC-only → no secrets section"
assert_before 'open to world' 'low issue' "$out" "E6. misconfig rows ordered CRITICAL before LOW"

# E7. trivy returns no usable output → exit 1
mkdir -p "$ROOT/noout" "$ROOT/noout-bin"
cat > "$ROOT/noout-bin/trivy" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "--version" ] && { echo "Version: 0.50.0"; exit 0; }
case " $* " in *" --download-db-only "*) exit 0;; esac
echo "trivy boom" >&2; exit 1
STUB
chmod +x "$ROOT/noout-bin/trivy"
out=$(env PATH="$ROOT/noout-bin:$ROOT/realbin" TRIVY_CACHE_DIR="$CACHE" "$PY" "$AUDIT" --no-version-check "$ROOT/noout" 2>&1); rc=$?
assert_eq 1 "$rc" "E7. empty trivy output → exit 1"
assert_contains 'trivy scan failed' "$out" "E7. empty output surfaces a scan-failed message"

# E8. trivy returns non-JSON → exit 1
mkdir -p "$ROOT/njout-bin" "$ROOT/nj"
cat > "$ROOT/njout-bin/trivy" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "--version" ] && { echo "Version: 0.50.0"; exit 0; }
case " $* " in *" --download-db-only "*) exit 0;; esac
echo "this is not json"; exit 0
STUB
chmod +x "$ROOT/njout-bin/trivy"
out=$(env PATH="$ROOT/njout-bin:$ROOT/realbin" TRIVY_CACHE_DIR="$CACHE" "$PY" "$AUDIT" --no-version-check "$ROOT/nj" 2>&1); rc=$?
assert_eq 1 "$rc" "E8. non-JSON trivy output → exit 1"
assert_contains 'unparseable JSON' "$out" "E8. non-JSON surfaces an unparseable message"

# E9. trivy not installed → exit 3 with install hint
mkdir -p "$ROOT/notrivy"
out=$(env PATH="$ROOT/realbin" TRIVY_CACHE_DIR="$CACHE" "$PY" "$AUDIT" --no-version-check "$ROOT/notrivy" 2>&1); rc=$?
assert_eq 3 "$rc" "E9. missing trivy → exit 3"
assert_contains 'trivy not found' "$out" "E9. missing trivy → install hint"

# E10. HTML dashboard output → dark report file with expected counts/sections
mkrepo htmlrepo '{"Results":[
 {"Target":"package-lock.json","Class":"lang-pkgs","Vulnerabilities":[
   {"Severity":"CRITICAL","VulnerabilityID":"CVE-H","PkgName":"lodash","InstalledVersion":"1.0","FixedVersion":"1.1","PrimaryURL":"http://a"}]},
 {"Target":"main.tf","Class":"config","Misconfigurations":[{"Severity":"HIGH","ID":"AVD-9","Title":"SG allows 0.0.0.0/0"}]}]}'
out=$(audit --format html --out "$ROOT/report.html" "$ROOT/htmlrepo")
assert_contains "$ROOT/report.html" "$out" "E10. HTML path echoed to stdout"
[ -f "$ROOT/report.html" ] && ok "E10. HTML file written" || ko "E10. HTML file written"
htm=$(cat "$ROOT/report.html")
assert_contains '<!DOCTYPE html>' "$htm" "E10. doctype present"
assert_contains '<em>2</em> findings' "$htm" "E10. headline finding count"
assert_contains '--dark:#0c0d10' "$htm" "E10. dark dashboard CSS embedded"
assert_contains 'Vulnerabilities — fixable' "$htm" "E10. fixable section in dashboard"
assert_contains 'Misconfigurations (IaC)' "$htm" "E10. IaC section in dashboard"
assert_contains 'SG allows 0.0.0.0/0' "$htm" "E10. misconfig title rendered in HTML"
assert_contains 'class="sev crit"' "$htm" "E10. critical badge class in HTML"

# E11. gitignored_skips on a REAL repo — root scan AND subdirectory scan (porcelain paths
# are toplevel-relative; the subdir case used to produce skips that matched nothing)
g="$ROOT/gitskips"; mkdir -p "$g/apps/api/node_modules" "$g/apps/api/src"
git -C "$g" init -q -b main; git -C "$g" config user.email t@t.t; git -C "$g" config user.name t
printf 'node_modules/\n.env.local\n' > "$g/.gitignore"
echo x > "$g/apps/api/node_modules/junk.js"; echo s > "$g/apps/api/.env.local"; echo k > "$g/apps/api/src/ok.js"
git -C "$g" add -A; git -C "$g" -c commit.gpgsign=false commit -qm init
skips_of(){ env AUDIT="$AUDIT" SCAN="$1" "$PY" - <<'PY'
import importlib.util, os, json
spec = importlib.util.spec_from_file_location("audit", os.environ["AUDIT"])
audit = importlib.util.module_from_spec(spec); spec.loader.exec_module(audit)
d, f = audit.gitignored_skips(os.environ["SCAN"])
print(json.dumps({"dirs": d, "files": f}))
PY
}
out=$(skips_of "$g")
assert_contains 'apps/api/node_modules' "$out" "E11. root scan skips ignored dir"
assert_contains 'apps/api/.env.local' "$out" "E11. root scan skips ignored file"
out=$(skips_of "$g/apps/api")
assert_contains '"node_modules"' "$out" "E11. SUBDIR scan skips node_modules (root-relative rebase)"
assert_contains '".env.local"' "$out" "E11. SUBDIR scan skips .env.local"
assert_absent 'apps/api/apps' "$out" "E11. no doubled apps/api/apps path"

echo
echo "PASS=$PASS FAIL=$FAIL"
rm -rf "$ROOT"
[ "$FAIL" -eq 0 ]
