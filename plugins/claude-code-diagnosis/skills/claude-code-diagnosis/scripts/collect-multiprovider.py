#!/usr/bin/env python3
import json, os, sys, subprocess
from collections import defaultdict

PROVIDERS = {
    "Anthropic": ("#a8231f", ("claude", "opus", "sonnet", "haiku")),
    "OpenAI": ("#3d5a7f", ("gpt", "codex", "o1-", "o3-", "o4-")),
    "Google": ("#9a7b4a", ("gemini", "gemma")),
}


def provider_of(model):
    m = (model or "").lower()
    for name, (_, keys) in PROVIDERS.items():
        if any(k in m for k in keys):
            return name
    return "Other"


def color_of(name):
    return PROVIDERS.get(name, ("#b3a78f",))[0]


def load_daily(argv):
    if len(argv) > 1 and argv[1] and os.path.isfile(os.path.expanduser(argv[1])):
        with open(os.path.expanduser(argv[1])) as f:
            return json.load(f)
    out = subprocess.run(
        ["npx", "-y", "ccusage@latest", "daily", "--json"],
        capture_output=True, text=True, timeout=180,
    )
    if out.returncode != 0 or not out.stdout.strip():
        sys.stderr.write("ccusage failed: " + (out.stderr or "no output") + "\n")
        sys.exit(2)
    return json.loads(out.stdout)


def main():
    d = load_daily(sys.argv)
    rows = d.get("daily", [])
    if not rows:
        sys.stderr.write("no daily rows from ccusage\n")
        sys.exit(2)

    p_cost = defaultdict(float)
    p_tok = defaultdict(int)
    p_out = defaultdict(int)
    p_models = defaultdict(lambda: defaultdict(float))
    monthly = defaultdict(lambda: defaultdict(float))
    months = set()
    days = []

    for r in rows:
        day = r.get("period") or r.get("date")
        if day:
            days.append(day)
            month = day[:7]
            months.add(month)
        for mb in r.get("modelBreakdowns", []):
            name = mb.get("modelName", "?")
            prov = provider_of(name)
            cost = mb.get("cost", 0) or 0
            tot = (
                (mb.get("inputTokens", 0) or 0)
                + (mb.get("outputTokens", 0) or 0)
                + (mb.get("cacheReadTokens", 0) or 0)
                + (mb.get("cacheCreationTokens", 0) or 0)
            )
            p_cost[prov] += cost
            p_tok[prov] += tot
            p_out[prov] += mb.get("outputTokens", 0) or 0
            p_models[prov][name] += cost
            if day:
                monthly[day[:7]][prov] += cost

    total = sum(p_cost.values()) or 1.0
    months_sorted = sorted(months)
    prov_sorted = sorted(p_cost, key=lambda k: -p_cost[k])

    providers = [
        {
            "name": p,
            "color": color_of(p),
            "cost": round(p_cost[p], 2),
            "share_pct": round(100 * p_cost[p] / total, 1),
            "tokens": p_tok[p],
            "output_tokens": p_out[p],
            "models": [
                {"model": mn, "cost": round(c, 2)}
                for mn, c in sorted(p_models[p].items(), key=lambda kv: -kv[1])
            ],
        }
        for p in prov_sorted
    ]

    all_models = []
    for p in providers:
        for m in p["models"]:
            all_models.append({"model": m["model"], "provider": p["name"], "cost": m["cost"],
                               "share_pct": round(100 * m["cost"] / total, 1), "color": p["color"]})
    all_models.sort(key=lambda r: -r["cost"])

    out = {
        "metadata": {
            "source": "ccusage (all detected coding agents)",
            "first_day": min(days) if days else None,
            "last_day": max(days) if days else None,
            "active_days": len(set(days)),
            "tool": "claude-code-diagnosis 1.0 / multiprovider",
        },
        "totals": {
            "cost": round(total, 2),
            "tokens": sum(p_tok.values()),
            "providers": len(providers),
            "anthropic_share_pct": round(100 * p_cost.get("Anthropic", 0) / total, 1),
        },
        "providers": providers,
        "monthly": {
            "months": months_sorted,
            "cost": {p["name"]: [round(monthly[m].get(p["name"], 0), 2) for m in months_sorted] for p in providers},
        },
        "by_model": all_models[:14],
    }
    json.dump(out, sys.stdout, default=str)


if __name__ == "__main__":
    main()
