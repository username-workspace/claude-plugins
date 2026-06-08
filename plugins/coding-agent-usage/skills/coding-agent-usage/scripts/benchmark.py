import json, os, re, ssl, time, math, urllib.request

SOURCE_URL = "https://code.claude.com/docs/en/costs"
CACHE_PATH = os.path.expanduser("~/.cache/coding-agent-usage/benchmark.json")
TTL_SECONDS = 24 * 3600
Z90 = 1.2815515594


def fit_lognormal(mean, p90):
    lnM, lnP = math.log(mean), math.log(p90)
    disc = (2 * Z90) ** 2 - 4 * (2 * (lnP - lnM))
    if disc > 0:
        s = math.sqrt(disc)
        sigma = (2 * Z90 - s) / 2
        if sigma <= 0:
            sigma = (2 * Z90 + s) / 2
        mu = lnP - Z90 * sigma
    else:
        sigma = Z90
        mu = ((lnM - sigma * sigma / 2) + (lnP - Z90 * sigma)) / 2
    return round(mu, 4), round(sigma, 4), round(math.exp(mu), 2)


def fetch_live(timeout=15):
    req = urllib.request.Request(SOURCE_URL, headers={"User-Agent": "coding-agent-usage"})
    html = urllib.request.urlopen(req, timeout=timeout, context=ssl.create_default_context()).read().decode("utf-8", "ignore")
    mean = re.search(r"\$(\d+(?:\.\d+)?)\s+per developer per active day", html)
    p90 = re.search(r"below\s+\$(\d+)\s+per active day for 90", html)
    month = re.search(r"\$(\d+)[-–](\d+)\s+per developer per month", html)
    if not (mean and p90):
        raise ValueError("expected figures not found on source page")
    out = {"mean": float(mean.group(1)), "p90": float(p90.group(1)), "fetched_at": time.time()}
    if month:
        out["month_low"], out["month_high"] = float(month.group(1)), float(month.group(2))
    return out


def _read_cache():
    try:
        with open(CACHE_PATH) as f:
            return json.load(f)
    except Exception:
        return None


def _write_cache(data):
    try:
        os.makedirs(os.path.dirname(CACHE_PATH), exist_ok=True)
        with open(CACHE_PATH, "w") as f:
            json.dump(data, f)
    except Exception:
        pass


def load(static_path):
    with open(static_path) as f:
        bench = json.load(f)

    cache = _read_cache()
    live = None
    fresh = cache and (time.time() - cache.get("fetched_at", 0) < TTL_SECONDS)
    if fresh:
        live, origin = cache, "cache"
    else:
        try:
            live = fetch_live()
            _write_cache(live)
            origin = "live"
        except Exception:
            live, origin = (cache, "stale-cache") if cache else (None, "seed")

    cad = bench["cost_per_active_day_usd"]
    if live:
        cad["mean"], cad["p90"] = live["mean"], live["p90"]
        cad["mu"], cad["sigma"], cad["median_implied"] = fit_lognormal(live["mean"], live["p90"])
        if "month_low" in live:
            bench["cost_per_month_usd"]["low"] = live["month_low"]
            bench["cost_per_month_usd"]["high"] = live["month_high"]
            bench["cost_per_month_usd"]["mean"] = round((live["month_low"] + live["month_high"]) / 2)
        bench["retrieved"] = time.strftime("%Y-%m-%d", time.localtime(live.get("fetched_at", time.time())))

    bench["source_url"] = SOURCE_URL
    bench["source_origin"] = origin
    bench["source_label"] = "Anthropic — Claude Code cost docs"
    return bench
