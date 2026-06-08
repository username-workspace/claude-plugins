#!/usr/bin/env python3
import json, os, sys, math, glob
from collections import defaultdict, Counter
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
BENCH_PATH = os.path.join(HERE, "..", "assets", "benchmarks.json")
sys.path.insert(0, HERE)
import benchmark


def load_benchmarks():
    return benchmark.load(BENCH_PATH)


def projects_dir(argv):
    if len(argv) > 1 and argv[1]:
        base = os.path.expanduser(argv[1])
    else:
        base = os.path.expanduser(os.environ.get("CLAUDE_CONFIG_DIR", "~/.claude"))
    cand = os.path.join(base, "projects")
    return cand if os.path.isdir(cand) else base


def family(model):
    m = (model or "").lower()
    if "opus" in m:
        legacy = any(t in m for t in ("opus-3", "opus-4-0", "opus-4-1", "4.0", "4.1"))
        recent = any(t in m for t in ("4-5", "4-6", "4-7", "4-8", "4.5", "4.6", "4.7", "4.8"))
        return "opus_legacy" if (legacy and not recent) else "opus"
    for fam in ("sonnet", "haiku"):
        if fam in m:
            return fam
    return "default"


def rate(pricing, model):
    return pricing.get(family(model), pricing["default"])


def message_cost(usage, model, pricing):
    r = rate(pricing, model)
    inp = usage.get("input_tokens", 0) or 0
    out = usage.get("output_tokens", 0) or 0
    read = usage.get("cache_read_input_tokens", 0) or 0
    write = usage.get("cache_creation_input_tokens", 0) or 0
    return (
        inp * r["input"]
        + out * r["output"]
        + read * r["cache_read"]
        + write * r["cache_write_5m"]
    ) / 1_000_000.0


def project_label(cwd):
    if not cwd:
        return "(unknown)"
    home = os.path.expanduser("~")
    p = cwd[len(home) + 1 :] if cwd.startswith(home + "/") else cwd
    parts = [s for s in p.split("/") if s]
    if not parts:
        return "~"
    if parts[0] == "src" and len(parts) >= 3:
        return "/".join(parts[1:3])
    return "/".join(parts[-2:]) if len(parts) > 2 else "/".join(parts)


def tool_label(name):
    if name.startswith("mcp__"):
        seg = name.split("__")
        return "mcp:" + (seg[1] if len(seg) > 1 else "?")
    return name


def parse_ts(ts):
    if not ts:
        return None
    try:
        dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        return dt.astimezone()
    except Exception:
        return None


def norm_percentile(x, mu, sigma):
    if x <= 0:
        return 0.0
    z = (math.log(x) - mu) / sigma
    return 0.5 * (1 + math.erf(z / math.sqrt(2)))


def band(p):
    if p < 0.25:
        return "Light user"
    if p < 0.75:
        return "Typical"
    if p < 0.90:
        return "Heavy user"
    if p < 0.99:
        return "Power user"
    return "Top 1%"


def main():
    bench = load_benchmarks()
    pricing = bench["pricing_usd_per_mtok"]
    root = projects_dir(sys.argv)
    files = glob.glob(os.path.join(root, "**", "*.jsonl"), recursive=True)

    tok = Counter()
    total_cost = 0.0
    assistant_turns = thinking_turns = sidechain_turns = 0
    tool_calls = web_tool_calls = 0
    user_prompts = 0

    by_model = defaultdict(lambda: {"turns": 0, "cost": 0.0, "output": 0, "total": 0})
    by_project = defaultdict(lambda: {"turns": 0, "cost": 0.0, "total": 0, "sessions": set()})
    by_tool = Counter()
    by_hour = [0] * 24
    by_weekday = [0] * 7
    versions = Counter()
    sessions = defaultdict(lambda: {"turns": 0, "cost": 0.0, "first": None, "last": None})
    active_days = set()
    weekly = defaultdict(lambda: {"cost": 0.0, "output": 0, "total": 0, "turns": 0, "sessions": set()})

    first_dt = last_dt = None
    seen_uuid = set()
    seen_msgid = set()
    thinking_ids = set()

    for fp in files:
        try:
            fh = open(fp, "r", errors="ignore")
        except Exception:
            continue
        with fh:
            for line in fh:
                if '"assistant"' not in line and '"type":"user"' not in line and '"type": "user"' not in line:
                    continue
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                t = d.get("type")
                uid = d.get("uuid")
                if uid is not None:
                    if uid in seen_uuid:
                        continue
                    seen_uuid.add(uid)
                sid = d.get("sessionId") or "?"
                dt = parse_ts(d.get("timestamp"))

                if t == "user":
                    msg = d.get("message") or {}
                    c = msg.get("content")
                    is_human = isinstance(c, str) or (
                        isinstance(c, list) and any(isinstance(b, dict) and b.get("type") == "text" for b in c)
                    )
                    if is_human and not d.get("isSidechain"):
                        user_prompts += 1
                    continue

                if t != "assistant":
                    continue
                msg = d.get("message") or {}
                model = msg.get("model") or "unknown"
                mid = msg.get("id")

                content = msg.get("content")
                if isinstance(content, list):
                    for b in content:
                        if not isinstance(b, dict):
                            continue
                        bt = b.get("type")
                        if bt == "thinking" and mid:
                            thinking_ids.add(mid)
                        elif bt == "tool_use":
                            tool_calls += 1
                            by_tool[tool_label(b.get("name", "?"))] += 1

                if mid is not None and mid in seen_msgid:
                    continue
                if mid is not None:
                    seen_msgid.add(mid)

                usage = msg.get("usage") or {}
                cost = message_cost(usage, model, pricing)
                assistant_turns += 1
                total_cost += cost
                inp = usage.get("input_tokens", 0) or 0
                out = usage.get("output_tokens", 0) or 0
                read = usage.get("cache_read_input_tokens", 0) or 0
                cw = usage.get("cache_creation_input_tokens", 0) or 0
                tok["input"] += inp
                tok["output"] += out
                tok["cache_read"] += read
                tok["cache_creation"] += cw
                mtotal = inp + out + read + cw

                bm = by_model[model]
                bm["turns"] += 1
                bm["cost"] += cost
                bm["output"] += out
                bm["total"] += mtotal

                cwd = d.get("cwd")
                pl = project_label(cwd)
                bp = by_project[pl]
                bp["turns"] += 1
                bp["cost"] += cost
                bp["total"] += mtotal
                bp["sessions"].add(sid)

                ver = d.get("version")
                if ver:
                    versions[ver] += 1
                if d.get("isSidechain"):
                    sidechain_turns += 1

                stu = usage.get("server_tool_use") or {}
                web_tool_calls += (stu.get("web_search_requests", 0) or 0) + (stu.get("web_fetch_requests", 0) or 0)

                s = sessions[sid]
                s["turns"] += 1
                s["cost"] += cost
                if dt:
                    if s["first"] is None or dt < s["first"]:
                        s["first"] = dt
                    if s["last"] is None or dt > s["last"]:
                        s["last"] = dt
                    active_days.add(dt.date().isoformat())
                    by_hour[dt.hour] += 1
                    by_weekday[dt.weekday()] += 1
                    if first_dt is None or dt < first_dt:
                        first_dt = dt
                    if last_dt is None or dt > last_dt:
                        last_dt = dt
                    monday = (dt.date() - timedelta(days=dt.weekday())).isoformat()
                    w = weekly[monday]
                    w["cost"] += cost
                    w["output"] += out
                    w["total"] += mtotal
                    w["turns"] += 1
                    w["sessions"].add(sid)

    tok["total"] = tok["input"] + tok["output"] + tok["cache_read"] + tok["cache_creation"]
    thinking_turns = len(thinking_ids)
    n_sessions = len(sessions)
    n_active = len(active_days)
    cost_per_active_day = total_cost / n_active if n_active else 0.0

    span_days = (last_dt.date() - first_dt.date()).days + 1 if first_dt and last_dt else 0
    months = max(span_days / 30.4375, 0.0001)
    monthly_cost = total_cost / months

    cad = bench["cost_per_active_day_usd"]
    pct_cad = norm_percentile(cost_per_active_day, cad["mu"], cad["sigma"])

    cache_base = tok["cache_read"] + tok["cache_creation"] + tok["input"]
    cache_hit = tok["cache_read"] / cache_base if cache_base else 0.0

    durations = [
        (s["last"] - s["first"]).total_seconds() / 60.0
        for s in sessions.values()
        if s["first"] and s["last"]
    ]
    mean_session_min = sum(durations) / len(durations) if durations else 0.0

    if weekly:
        today = datetime.now().astimezone().date()
        cur_monday = (today - timedelta(days=today.weekday())).isoformat()
        weeks_sorted = sorted(w for w in weekly if w < cur_monday)
    else:
        weeks_sorted = []

    model_rows = sorted(
        [
            {
                "model": m.replace("claude-", "").replace("-20", " 20") if m.startswith("claude") else m,
                "raw": m,
                "turns": v["turns"],
                "cost": round(v["cost"], 2),
                "output_tokens": v["output"],
                "total_tokens": v["total"],
                "share_pct": round(100 * v["cost"] / total_cost, 1) if total_cost else 0,
            }
            for m, v in by_model.items()
        ],
        key=lambda r: -r["cost"],
    )

    project_rows = sorted(
        [
            {
                "project": p,
                "sessions": len(v["sessions"]),
                "turns": v["turns"],
                "cost": round(v["cost"], 2),
                "total_tokens": v["total"],
                "share_pct": round(100 * v["cost"] / total_cost, 1) if total_cost else 0,
            }
            for p, v in by_project.items()
        ],
        key=lambda r: -r["cost"],
    )

    web_tool_calls += by_tool.get("WebSearch", 0) + by_tool.get("WebFetch", 0)
    tool_total = sum(by_tool.values()) or 1
    tool_rows = [
        {"tool": t, "count": c, "share_pct": round(100 * c / tool_total, 1)}
        for t, c in by_tool.most_common(16)
    ]

    out = {
        "metadata": {
            "tool": "claude-code-diagnosis 1.0",
            "scope": root,
            "files": len(files),
            "first_day": first_dt.date().isoformat() if first_dt else None,
            "last_day": last_dt.date().isoformat() if last_dt else None,
            "span_days": span_days,
            "active_days": n_active,
            "pricing_note": bench["pricing_note"],
            "benchmark_source": bench["source"],
            "benchmark_source_label": bench.get("source_label"),
            "benchmark_source_url": bench.get("source_url"),
            "benchmark_source_origin": bench.get("source_origin"),
            "benchmark_retrieved": bench["retrieved"],
        },
        "totals": {
            "cost": round(total_cost, 2),
            "monthly_cost": round(monthly_cost, 2),
            "cost_per_active_day": round(cost_per_active_day, 2),
            "tokens": dict(tok),
            "sessions": n_sessions,
            "user_prompts": user_prompts,
            "assistant_turns": assistant_turns,
            "tool_calls": tool_calls,
            "web_tool_calls": web_tool_calls,
            "projects": len(by_project),
            "thinking_pct": round(100 * thinking_turns / assistant_turns, 1) if assistant_turns else 0,
            "sidechain_pct": round(100 * sidechain_turns / assistant_turns, 1) if assistant_turns else 0,
            "sidechain_turns": sidechain_turns,
            "cache_hit_pct": round(100 * cache_hit, 1),
            "mean_turns_per_session": round(assistant_turns / n_sessions, 1) if n_sessions else 0,
            "mean_cost_per_session": round(total_cost / n_sessions, 2) if n_sessions else 0,
            "mean_session_min": round(mean_session_min, 1),
            "mean_prompts_per_active_day": round(user_prompts / n_active, 1) if n_active else 0,
        },
        "percentile": {
            "cost_per_active_day": {
                "value": round(cost_per_active_day, 2),
                "percentile": round(100 * pct_cad, 1),
                "band": band(pct_cad),
                "mean_benchmark": cad["mean"],
                "p90_benchmark": cad["p90"],
                "median_benchmark": cad["median_implied"],
            },
            "monthly_cost": {
                "value": round(monthly_cost, 2),
                "mean_benchmark": bench["cost_per_month_usd"]["mean"],
                "x_vs_mean": round(monthly_cost / bench["cost_per_month_usd"]["mean"], 1),
            },
        },
        "by_model": model_rows,
        "by_project": project_rows[:12],
        "by_tool": tool_rows,
        "by_hour": by_hour,
        "by_weekday": by_weekday,
        "versions": [{"version": v, "turns": c} for v, c in versions.most_common(8)],
        "weekly": {
            "weeks": weeks_sorted,
            "cost": [round(weekly[w]["cost"], 2) for w in weeks_sorted],
            "output_tokens": [weekly[w]["output"] for w in weeks_sorted],
            "total_tokens": [weekly[w]["total"] for w in weeks_sorted],
            "turns": [weekly[w]["turns"] for w in weeks_sorted],
            "sessions": [len(weekly[w]["sessions"]) for w in weeks_sorted],
        },
        "benchmark": bench,
    }
    json.dump(out, sys.stdout, default=str)


if __name__ == "__main__":
    main()
