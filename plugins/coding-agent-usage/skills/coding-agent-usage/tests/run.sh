#!/usr/bin/env bash
# coding-agent-usage test suite — drives the three scripts on throwaway fixtures.
# Fully offline: a fresh benchmark cache under a temp HOME makes benchmark.load skip the network,
# and ccusage is stubbed on PATH so multiprovider never shells out.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL="$(cd "$HERE/.." && pwd)"
SCRIPTS="$SKILL/scripts"
BENCH="$SKILL/assets/benchmarks.json"
ROOT="$(mktemp -d)"
PASS=0; FAIL=0

ok(){ PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
ko(){ FAIL=$((FAIL+1)); printf '  \033[31m✗ %s\033[0m\n' "$1"; }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || ko "$3 — expected [$1] got [$2]"; }
assert_contains(){ case "$2" in *"$1"*) ok "$3";; *) ko "$3 — expected to contain [$1] in [$2]";; esac; }
run_py(){ while IFS= read -r l; do case "$l" in PASS*) ok "${l#PASS }";; FAIL*) ko "${l#FAIL }";; esac; done < <(python3 "$1"); }

export SCRIPTS BENCH

# --- offline scaffolding: temp HOME + a FRESH benchmark cache so load() uses it (origin "cache") ---
export HOME="$ROOT/home"
mkdir -p "$HOME/.cache/coding-agent-usage"
python3 - "$HOME/.cache/coding-agent-usage/benchmark.json" <<'PY'
import json, time, sys
json.dump({"mean":13.0,"p90":30.0,"fetched_at":time.time(),"month_low":150.0,"month_high":250.0}, open(sys.argv[1],"w"))
PY

# --- stub ccusage (invoked via `npx ... ccusage`) on PATH; must never be reached when a fixture is passed ---
NPX_LOG="$ROOT/npx.log"; : > "$NPX_LOG"
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/npx" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$NPX_LOG"
echo '{"daily":[]}'
EOF
chmod +x "$ROOT/bin/npx"
export PATH="$ROOT/bin:$PATH"

usage(){ python3 "$SCRIPTS/collect-usage.py" "$1"; }
mp(){ python3 "$SCRIPTS/collect-multiprovider.py" "$1"; }
get(){ python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))" "$1" "$2"; }

echo "coding-agent-usage tests"

# ======================================================================
# A. benchmark.py — pure lognormal / percentile math (no network)
# ======================================================================
echo "[benchmark math]"
cat > "$ROOT/t_bench.py" <<'PY'
import importlib.util, os, math, tempfile, shutil
spec = importlib.util.spec_from_file_location("benchmark", os.path.join(os.environ["SCRIPTS"], "benchmark.py"))
b = importlib.util.module_from_spec(spec); spec.loader.exec_module(b)
def ck(c, m): print(("PASS " if c else "FAIL ") + m)

mu, sigma, median = b.fit_lognormal(13, 30)
ck(abs(mu - 1.7513) < 1e-3, "fit_lognormal(13,30) mu approx 1.7513")
ck(abs(sigma - 1.2816) < 1e-3, "fit_lognormal(13,30) sigma approx 1.2816")
ck(abs(median - 5.76) < 0.05, "fit_lognormal(13,30) median exp(mu) approx 5.76")
cdf = lambda x: 0.5 * (1 + math.erf((math.log(x) - mu) / (sigma * math.sqrt(2))))
ck(abs(cdf(30) - 0.90) < 2e-3, "fitted dist puts the p90 anchor at the 90th percentile")
ck(abs(math.exp(mu + sigma * sigma / 2) - 13) < 0.2, "fitted dist mean recovers the $13 anchor")

bench = b.load(os.environ["BENCH"])
ck(bench["source_origin"] == "cache", "load() uses the fresh cache offline (origin cache)")
cad = bench["cost_per_active_day_usd"]
ck(cad["mean"] == 13.0 and cad["p90"] == 30.0, "cache anchors propagate into bench")
ck(abs(cad["mu"] - 1.7513) < 1e-3 and abs(cad["sigma"] - 1.2816) < 1e-3, "load() overrides static mu/sigma with the fit")
ck(bench["cost_per_month_usd"]["mean"] == 200, "monthly mean = round((150+250)/2) = 200")

tmp = tempfile.mkdtemp(); b.CACHE_PATH = os.path.join(tmp, "benchmark.json")
b.fetch_live = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("offline"))
seed = b.load(os.environ["BENCH"])
ck(seed["source_origin"] == "seed", "no cache + offline → origin seed")
scad = seed["cost_per_active_day_usd"]
ck(abs(scad["mu"] - mu) < 1e-3 and abs(scad["sigma"] - sigma) < 1e-3,
   "seed mu/sigma mirror fit_lognormal(seed anchors) — offline fallback places users at the same percentile")
shutil.rmtree(tmp, ignore_errors=True)

ck(sigma == round(b.Z90, 4), "real anchors (13,30) hit the disc<=0 branch → sigma = Z90")
mu3, sig3, med3 = b.fit_lognormal(30, 13)
ck(sig3 > round(b.Z90, 4), "spread anchors (disc>0) solve sigma from the quadratic (sigma>Z90)")
PY
run_py "$ROOT/t_bench.py"

# ======================================================================
# B. collect-usage.py — pure helpers (family / project_label / tool_label / band / percentile / cost)
# ======================================================================
echo "[collect-usage helpers]"
cat > "$ROOT/t_usage_helpers.py" <<'PY'
import importlib.util, os, math
spec = importlib.util.spec_from_file_location("cu", os.path.join(os.environ["SCRIPTS"], "collect-usage.py"))
cu = importlib.util.module_from_spec(spec); spec.loader.exec_module(cu)
def ck(c, m): print(("PASS " if c else "FAIL ") + m)
home = os.path.expanduser("~")

ck(cu.family("claude-opus-4-8-20260101") == "opus", "family: opus 4.8 → opus")
ck(cu.family("claude-opus-4-5") == "opus", "family: opus 4.5 → opus")
ck(cu.family("claude-opus-4-1-20250101") == "opus_legacy", "family: opus 4.1 → opus_legacy")
ck(cu.family("claude-opus-4-0") == "opus_legacy", "family: opus 4.0 → opus_legacy")
ck(cu.family("claude-3-opus-20240229") == "opus_legacy", "family: claude 3 opus → opus_legacy (3-opus token)")
ck(cu.family("claude-opus-4-10-20270101") == "opus", "family: future opus 4.10 → opus (numeric compare, not substring)")
ck(cu.family("claude-opus-5-0") == "opus", "family: opus 5.0 → opus")
ck(cu.family("claude-opus-4-20250514") == "opus", "family: date suffix never parsed as a version")
ck(cu.family("claude-sonnet-4-5") == "sonnet", "family: sonnet")
ck(cu.family("claude-haiku-4-5") == "haiku", "family: haiku")
ck(cu.family("gpt-5") == "default", "family: non-claude → default")
ck(cu.family("") == "default", "family: empty → default")

ck(cu.project_label(home + "/src/zv/workspace") == "zv/workspace", "project: ~/src/a/b → a/b")
ck(cu.project_label(home + "/src/zv/workspace/polaris") == "zv/workspace", "project: ~/src/a/b/c → a/b (src shortcut)")
ck(cu.project_label(home + "/work/a/b/c") == "b/c", "project: deep non-src → last two parts")
ck(cu.project_label(home + "/src/foo") == "src/foo", "project: ~/src/foo (len<3) → src/foo")
ck(cu.project_label("/opt/x/y/z") == "y/z", "project: outside home → last two parts")
ck(cu.project_label(None) == "(unknown)", "project: None → (unknown)")
ck(cu.project_label("") == "(unknown)", "project: empty → (unknown)")

ck(cu.tool_label("mcp__playwright__click") == "mcp:playwright", "tool: mcp__server__tool → mcp:server")
ck(cu.tool_label("mcp__only") == "mcp:only", "tool: mcp__server (no tool seg) → mcp:server")
ck(cu.tool_label("Bash") == "Bash", "tool: plain name unchanged")

ck(cu.band(0.10) == "Light user", "band <0.25 → Light user")
ck(cu.band(0.50) == "Typical", "band <0.75 → Typical")
ck(cu.band(0.80) == "Heavy user", "band <0.90 → Heavy user")
ck(cu.band(0.95) == "Power user", "band <0.99 → Power user")
ck(cu.band(0.999) == "Top 1%", "band >=0.99 → Top 1%")

ck(cu.norm_percentile(0, 1.0, 1.0) == 0.0, "percentile: x<=0 → 0")
ck(abs(cu.norm_percentile(math.exp(1.7513), 1.7513, 1.2816) - 0.5) < 1e-6, "percentile: x=exp(mu) → 0.5 (median)")
ck(abs(cu.norm_percentile(30, 1.7513, 1.2816) - 0.90) < 2e-3, "percentile: x=p90 anchor → 0.90")

pricing = {
    "opus": {"input": 5, "output": 25, "cache_read": 0.5, "cache_write_5m": 6.25},
    "default": {"input": 3, "output": 15, "cache_read": 0.3, "cache_write_5m": 3.75},
}
u = {"input_tokens": 1000, "output_tokens": 2000, "cache_read_input_tokens": 4000, "cache_creation_input_tokens": 8000}
ck(abs(cu.message_cost(u, "claude-opus-4-8", pricing) - 0.107) < 1e-9, "message_cost: opus token mix = $0.107")
ck(cu.message_cost({}, "claude-opus-4-8", pricing) == 0.0, "message_cost: empty usage = $0")
ck(abs(cu.message_cost({"output_tokens": 1_000_000}, "x", pricing) - 15.0) < 1e-9, "message_cost: 1M output @ default = $15")
PY
run_py "$ROOT/t_usage_helpers.py"

# ======================================================================
# C. collect-usage.py — end-to-end on fixture transcripts (hand-computed totals)
# ======================================================================
echo "[collect-usage end-to-end]"

# C1. canonical fixture: dedup, totals, per-project, model mix, cache, tools, thinking, sidechain, versions
P="$ROOT/c1"; mkdir -p "$P"
cat > "$P/sess.jsonl" <<EOF
{"type":"user","uuid":"hu1","sessionId":"s1","timestamp":"2026-06-01T09:00:00Z","message":{"role":"user","content":"do the thing"}}
{"type":"assistant","uuid":"a1","sessionId":"s1","cwd":"$HOME/src/zv/workspace","timestamp":"2026-06-01T10:00:00Z","version":"1.2.3","message":{"id":"m1","model":"claude-opus-4-8","usage":{"input_tokens":1000,"output_tokens":2000,"cache_read_input_tokens":4000,"cache_creation_input_tokens":8000},"content":[{"type":"thinking","thinking":"hmm"},{"type":"tool_use","name":"Bash"}]}}
{"type":"assistant","uuid":"a1-dup","sessionId":"s1","cwd":"$HOME/src/zv/workspace","timestamp":"2026-06-01T10:00:00Z","message":{"id":"m1","model":"claude-opus-4-8","usage":{"input_tokens":99999,"output_tokens":99999},"content":[]}}
{"type":"assistant","uuid":"a2","sessionId":"s1","cwd":"$HOME/src/zv/workspace","timestamp":"2026-06-01T10:05:00Z","message":{"id":"m2","model":"claude-sonnet-4-5","usage":{"input_tokens":1000,"output_tokens":1000},"content":[{"type":"tool_use","name":"mcp__playwright__click"},{"type":"tool_use","name":"WebSearch"}]}}
{"type":"assistant","uuid":"a3","sessionId":"s2","cwd":"$HOME/src/other/repo","timestamp":"2026-06-02T11:00:00Z","isSidechain":true,"message":{"id":"m3","model":"claude-haiku-4-5","usage":{"input_tokens":2000,"output_tokens":0,"server_tool_use":{"web_search_requests":2,"web_fetch_requests":1}},"content":[]}}
EOF
usage "$P" > "$ROOT/c1.json"

# dedup: the byte-different but same-message.id duplicate (other uuid, huge fake usage) must NOT inflate anything.
# opus mix = .107 ; sonnet 1000in+1000out @3/15 = .018 ; haiku 2000in @1 = .002  → total .127 → 0.13
assert_eq "0.13"  "$(get "$ROOT/c1.json" "d['totals']['cost']")"               "C1. total cost = .107+.018+.002 = 0.13 (dup ignored)"
assert_eq "3"     "$(get "$ROOT/c1.json" "d['totals']['assistant_turns']")"    "C1. 3 assistant turns (dup collapsed)"
assert_eq "1"     "$(get "$ROOT/c1.json" "d['totals']['user_prompts']")"        "C1. 1 human prompt counted"
assert_eq "2"     "$(get "$ROOT/c1.json" "d['totals']['sessions']")"            "C1. 2 sessions"
assert_eq "4000"  "$(get "$ROOT/c1.json" "d['totals']['tokens']['input']")"     "C1. input tokens summed (dup excluded)"
assert_eq "3000"  "$(get "$ROOT/c1.json" "d['totals']['tokens']['output']")"    "C1. output tokens summed"
assert_eq "4000"  "$(get "$ROOT/c1.json" "d['totals']['tokens']['cache_read']")" "C1. cache_read tokens"
assert_eq "8000"  "$(get "$ROOT/c1.json" "d['totals']['tokens']['cache_creation']")" "C1. cache_creation tokens"
assert_eq "19000" "$(get "$ROOT/c1.json" "d['totals']['tokens']['total']")"     "C1. token total = 4000+3000+4000+8000"
# cache hit = cache_read / (cache_read+cache_creation+input) = 4000/16000 = 25.0%
assert_eq "25.0"  "$(get "$ROOT/c1.json" "d['totals']['cache_hit_pct']")"       "C1. cache-hit % = 4000/16000 = 25.0"
# thinking: 1 of 3 turns carried a thinking block ; sidechain: 1 of 3
assert_eq "33.3"  "$(get "$ROOT/c1.json" "d['totals']['thinking_pct']")"        "C1. thinking % = 1/3"
assert_eq "33.3"  "$(get "$ROOT/c1.json" "d['totals']['sidechain_pct']")"       "C1. sidechain % = 1/3"
assert_eq "1"     "$(get "$ROOT/c1.json" "d['totals']['sidechain_turns']")"     "C1. 1 sidechain turn"
# tool calls: Bash + mcp click + WebSearch = 3 ; web = server(2+1) + WebSearch(1) = 4
assert_eq "3"     "$(get "$ROOT/c1.json" "d['totals']['tool_calls']")"          "C1. 3 tool_use blocks"
assert_eq "4"     "$(get "$ROOT/c1.json" "d['totals']['web_tool_calls']")"      "C1. web tool calls = server(3)+WebSearch(1)"
# projects: 2 distinct, top by cost is zv/workspace with 2 turns
assert_eq "2"     "$(get "$ROOT/c1.json" "d['totals']['projects']")"            "C1. 2 projects"
assert_eq "zv/workspace" "$(get "$ROOT/c1.json" "d['by_project'][0]['project']")" "C1. top project = zv/workspace (src shortcut)"
assert_eq "2"     "$(get "$ROOT/c1.json" "[p for p in d['by_project'] if p['project']=='zv/workspace'][0]['turns']")" "C1. zv/workspace has 2 turns"
# model mix: 3 models, opus leads on cost, shares ~100
assert_eq "3"     "$(get "$ROOT/c1.json" "len(d['by_model'])")"                 "C1. 3 distinct models"
assert_eq "claude-opus-4-8" "$(get "$ROOT/c1.json" "d['by_model'][0]['raw']")"  "C1. opus is the top-cost model"
assert_eq "1"     "$(get "$ROOT/c1.json" "1 if abs(sum(m['share_pct'] for m in d['by_model'])-100)<=0.2 else 0")" "C1. model cost shares sum to ~100"
# versions captured
assert_eq "1.2.3" "$(get "$ROOT/c1.json" "d['versions'][0]['version']")"        "C1. version recorded"
# span/active days
assert_eq "2"     "$(get "$ROOT/c1.json" "d['metadata']['active_days']")"       "C1. 2 active days"
assert_eq "2"     "$(get "$ROOT/c1.json" "d['metadata']['span_days']")"         "C1. span = 2 days"

# C1b. accuracy is auditable: tokens billed at the fallback rate (unrecognized model family) are
# surfaced as a share, so a new/unknown model silently priced as the default never hides
PLACEHOLDER
P="$ROOT/c1b"; mkdir -p "$P"
cat > "$P/sess.jsonl" <<EOF
{"type":"assistant","uuid":"k1","sessionId":"s1","cwd":"$HOME/x","timestamp":"2026-06-01T10:00:00Z","message":{"id":"k1","model":"claude-sonnet-4-5","usage":{"input_tokens":1000,"output_tokens":0},"content":[]}}
{"type":"assistant","uuid":"u1","sessionId":"s1","cwd":"$HOME/x","timestamp":"2026-06-01T10:01:00Z","message":{"id":"u1","model":"some-future-model-x9","usage":{"input_tokens":3000,"output_tokens":0},"content":[]}}
EOF
usage "$P" > "$ROOT/c1b.json"
assert_eq "75.0" "$(get "$ROOT/c1b.json" "d['metadata']['fallback_priced_token_share']")" "C1b. unknown model → 3000/4000 = 75% flagged as fallback-priced"

# C2. empty input → zeroed totals, no crash, no div-by-zero
P="$ROOT/c2"; mkdir -p "$P"; : > "$P/empty.jsonl"
usage "$P" > "$ROOT/c2.json"
assert_eq "0"    "$(get "$ROOT/c2.json" "d['totals']['assistant_turns']")"  "C2. empty file → 0 turns"
assert_eq "0.0"  "$(get "$ROOT/c2.json" "d['totals']['cost']")"             "C2. empty → 0 cost"
assert_eq "0"    "$(get "$ROOT/c2.json" "d['totals']['thinking_pct']")"     "C2. empty → 0 thinking (no div-by-zero)"
assert_eq "None" "$(get "$ROOT/c2.json" "d['metadata']['first_day']")"      "C2. empty → no first_day"

# C3. malformed / partial lines are skipped; a valid record with missing cwd still parses
P="$ROOT/c3"; mkdir -p "$P"
cat > "$P/mixed.jsonl" <<'EOF'
not json at all {{{
{"type":"assistant","uuid":"x","message":{"id":"only","model":"claude-sonnet-4-5","usage":{"input_tokens":1000,"output_tokens":1000}}}
{"type":"summary","uuid":"sum"}
EOF
usage "$P" > "$ROOT/c3.json"
assert_eq "1"     "$(get "$ROOT/c3.json" "d['totals']['assistant_turns']")"  "C3. only the well-formed assistant record counts"
assert_eq "0.02"  "$(get "$ROOT/c3.json" "d['totals']['cost']")"             "C3. sonnet 1k/1k = .018 → 0.02"
assert_eq "(unknown)" "$(get "$ROOT/c3.json" "d['by_project'][0]['project']")" "C3. missing cwd → (unknown) project"

# C4. single record → percentile gauge for a known cost/active-day
P="$ROOT/c4"; mkdir -p "$P"
cat > "$P/one.jsonl" <<EOF
{"type":"assistant","uuid":"o1","sessionId":"s","cwd":"$HOME/src/a/b","timestamp":"2026-06-01T10:00:00Z","message":{"id":"only1","model":"claude-opus-4-8","usage":{"input_tokens":1000000,"output_tokens":1000000}}}
EOF
usage "$P" > "$ROOT/c4.json"
# opus 1M in + 1M out = $5 + $25 = $30 in a single active day → cost/active-day = $30 = the p90 anchor → ~90th pct
assert_eq "30.0" "$(get "$ROOT/c4.json" "d['totals']['cost_per_active_day']")" "C4. cost/active-day = \$30"
assert_eq "1" "$(get "$ROOT/c4.json" "1 if abs(d['percentile']['cost_per_active_day']['percentile']-90)<=0.2 else 0")" "C4. \$30/day → ~90th percentile (matches anchor)"
assert_eq "Power user" "$(get "$ROOT/c4.json" "d['percentile']['cost_per_active_day']['band']")" "C4. ~90th pct → Power user band"
assert_eq "1" "$(get "$ROOT/c4.json" "d['totals']['sessions']")" "C4. single session"

# ======================================================================
# D. collect-multiprovider.py — provider split, model mix, percentile, edge cases
# ======================================================================
echo "[collect-multiprovider]"

# D0. helper unit checks (provider_of / color_of)
cat > "$ROOT/t_mp_helpers.py" <<'PY'
import importlib.util, os
spec = importlib.util.spec_from_file_location("mp", os.path.join(os.environ["SCRIPTS"], "collect-multiprovider.py"))
mp = importlib.util.module_from_spec(spec); spec.loader.exec_module(mp)
def ck(c, m): print(("PASS " if c else "FAIL ") + m)
ck(mp.provider_of("claude-opus-4-8") == "Anthropic", "provider: claude → Anthropic")
ck(mp.provider_of("gpt-5-codex") == "OpenAI", "provider: gpt → OpenAI")
ck(mp.provider_of("codex-mini") == "OpenAI", "provider: codex → OpenAI")
ck(mp.provider_of("o3-mini") == "OpenAI", "provider: o3- → OpenAI")
ck(mp.provider_of("gemini-2.5-pro") == "Google", "provider: gemini → Google")
ck(mp.provider_of("llama-3") == "Other", "provider: unknown → Other")
ck(mp.provider_of("") == "Other", "provider: empty → Other")
ck(mp.color_of("Anthropic") == "#a8231f", "color: Anthropic brand red")
ck(mp.color_of("Other") == "#b3a78f", "color: Other fallback")
PY
run_py "$ROOT/t_mp_helpers.py"

# D1. three-provider fixture → split, shares, anthropic placement, model mix
cat > "$ROOT/mp1.json" <<'EOF'
{"daily":[
 {"date":"2026-06-01","modelBreakdowns":[
   {"modelName":"claude-opus-4-8","cost":6.0,"inputTokens":100,"outputTokens":200,"cacheReadTokens":300,"cacheCreationTokens":400},
   {"modelName":"gpt-5-codex","cost":3.0,"inputTokens":10,"outputTokens":20,"cacheReadTokens":0,"cacheCreationTokens":0}
 ]},
 {"date":"2026-06-02","modelBreakdowns":[
   {"modelName":"gemini-2.5-pro","cost":1.0,"inputTokens":5,"outputTokens":5,"cacheReadTokens":0,"cacheCreationTokens":0}
 ]}
]}
EOF
mp "$ROOT/mp1.json" > "$ROOT/mpout1.json"
assert_eq "0"    "$(wc -l < "$NPX_LOG" | tr -d ' ')"                              "D1. ccusage stub NOT invoked (fixture path used)"
assert_eq "10.0" "$(get "$ROOT/mpout1.json" "d['totals']['cost']")"               "D1. total cost = 6+3+1 = 10"
assert_eq "3"    "$(get "$ROOT/mpout1.json" "d['totals']['providers']")"          "D1. 3 providers"
assert_eq "60.0" "$(get "$ROOT/mpout1.json" "d['totals']['anthropic_share_pct']")" "D1. Anthropic share = 6/10 = 60%"
assert_eq "Anthropic" "$(get "$ROOT/mpout1.json" "d['providers'][0]['name']")"    "D1. Anthropic leads providers by cost"
assert_eq "1000" "$(get "$ROOT/mpout1.json" "[p for p in d['providers'] if p['name']=='Anthropic'][0]['tokens']")" "D1. Anthropic tokens = 100+200+300+400"
assert_eq "1"    "$(get "$ROOT/mpout1.json" "1 if abs(sum(p['share_pct'] for p in d['providers'])-100)<=0.2 else 0")" "D1. provider shares sum to ~100"
assert_eq "5.0"  "$(get "$ROOT/mpout1.json" "d['percentile']['total']['per_active_day']")"     "D1. total per-active-day = 10/2 = \$5"
assert_eq "3.0"  "$(get "$ROOT/mpout1.json" "d['percentile']['anthropic']['per_active_day']")" "D1. Anthropic per-active-day = 6/2 = \$3"
assert_eq "2"    "$(get "$ROOT/mpout1.json" "d['metadata']['active_days']")"       "D1. 2 active days"
assert_eq "claude-opus-4-8" "$(get "$ROOT/mpout1.json" "d['by_model'][0]['model']")" "D1. top model by cost = opus"
assert_eq "Anthropic" "$(get "$ROOT/mpout1.json" "d['by_model'][0]['provider']")"  "D1. top model tagged Anthropic"

# D2. missing-provider robustness: an unrecognised model lands in 'Other', cost still totals, 0% Anthropic
cat > "$ROOT/mp2.json" <<'EOF'
{"daily":[{"date":"2026-06-01","modelBreakdowns":[
  {"modelName":"mistral-large","cost":4.0,"inputTokens":1,"outputTokens":1,"cacheReadTokens":0,"cacheCreationTokens":0}
]}]}
EOF
mp "$ROOT/mp2.json" > "$ROOT/mpout2.json"
assert_eq "Other" "$(get "$ROOT/mpout2.json" "d['providers'][0]['name']")"          "D2. unknown model → Other provider"
assert_eq "0.0"   "$(get "$ROOT/mpout2.json" "d['totals']['anthropic_share_pct']")" "D2. no Anthropic → 0% share, no crash"
assert_eq "4.0"   "$(get "$ROOT/mpout2.json" "d['totals']['cost']")"                "D2. Other cost still totalled"

# D3. 'period' key alias (some ccusage versions) is honoured for the day
cat > "$ROOT/mp3.json" <<'EOF'
{"daily":[{"period":"2026-06-05","modelBreakdowns":[
  {"modelName":"claude-sonnet-4-5","cost":2.0,"inputTokens":1,"outputTokens":1}
]}]}
EOF
mp "$ROOT/mp3.json" > "$ROOT/mpout3.json"
assert_eq "2026-06-05" "$(get "$ROOT/mpout3.json" "d['metadata']['first_day']")"   "D3. 'period' alias used as the day key"
assert_eq "1" "$(get "$ROOT/mpout3.json" "d['metadata']['active_days']")"          "D3. single active day from period"

# D4. empty daily rows → script exits nonzero (no silent empty report)
cat > "$ROOT/mp4.json" <<'EOF'
{"daily":[]}
EOF
if python3 "$SCRIPTS/collect-multiprovider.py" "$ROOT/mp4.json" >/dev/null 2>&1; then
  ko "D4. empty daily → expected nonzero exit"
else
  ok "D4. empty daily rows → nonzero exit (no empty report)"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
rm -rf "$ROOT"
[ "$FAIL" -eq 0 ]
