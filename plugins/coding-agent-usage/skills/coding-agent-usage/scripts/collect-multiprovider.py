#!/usr/bin/env python3
import json, os, sys, subprocess, math
from collections import defaultdict
from datetime import date

HERE = os.path.dirname(os.path.abspath(__file__))
BENCH_PATH = os.path.join(HERE, "..", "assets", "benchmarks.json")
CCUSAGE_VERSION = "20.0.11"

PROVIDERS = {
    "Anthropic": ("#a8231f", ("claude", "opus", "sonnet", "haiku")),
    "OpenAI": ("#3d5a7f", ("gpt", "codex", "o1-", "o3-", "o4-")),
    "Google": ("#9a7b4a", ("gemini", "gemma")),
}


def norm_percentile(x, mu, sigma):
    if x <= 0:
        return 0.0
    return 0.5 * (1 + math.erf((math.log(x) - mu) / (sigma * math.sqrt(2))))


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
        ["npx", "-y", f"ccusage@{CCUSAGE_VERSION}", "daily", "--json"],
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
    n_active = len(set(days)) or 1

    sys.path.insert(0, HERE)
    import benchmark
    bench = benchmark.load(BENCH_PATH)
    cad = bench["cost_per_active_day_usd"]

    span_days = (date.fromisoformat(max(days)) - date.fromisoformat(min(days))).days + 1 if days else 1
    months = max(span_days / 30.4375, 0.0001)
    month_mean = bench["cost_per_month_usd"]["mean"]

    def placement(cost):
        v = cost / n_active
        pct = norm_percentile(v, cad["mu"], cad["sigma"])
        monthly = cost / months
        return {"per_active_day": round(v, 2), "percentile": round(100 * pct, 1), "band": band(pct),
                "monthly": round(monthly), "x_vs_mean": round(monthly / month_mean, 1)}

    percentile = {
        "benchmark": {"mean": cad["mean"], "p90": cad["p90"], "median": cad["median_implied"],
                      "mu": cad["mu"], "sigma": cad["sigma"], "source": bench["source"],
                      "source_label": bench.get("source_label"), "source_url": bench.get("source_url"),
                      "source_origin": bench.get("source_origin"), "retrieved": bench.get("retrieved")},
        "total": placement(total),
        "anthropic": placement(p_cost.get("Anthropic", 0)),
    }

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
            "source": "ccusage",
            "first_day": min(days) if days else None,
            "last_day": max(days) if days else None,
            "active_days": len(set(days)),
            "tool": "coding-agent-usage 1.0 / multiprovider",
        },
        "totals": {
            "cost": round(total, 2),
            "tokens": sum(p_tok.values()),
            "providers": len(providers),
            "anthropic_share_pct": round(100 * p_cost.get("Anthropic", 0) / total, 1),
        },
        "percentile": percentile,
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
