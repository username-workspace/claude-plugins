# skills — marketplace engineering rules

Claude Code plugin marketplace (stdlib-only Python + bash + git). Each plugin under `plugins/<name>/`
ships `.claude-plugin/plugin.json`, `web.json`, optional `hooks/`, `skills/<name>/SKILL.md`, and a
hermetic test suite under `tests/` (`run.sh` / `integration.sh`).

## Quality gate

`bash scripts/run-tests.sh` — every hermetic suite, discovered automatically, must be green. Suites
must stay hermetic: throwaway repos, stubbed forge CLIs, and **every hook invocation pins
`CLAUDE_PLUGIN_ROOT`** (the gate itself runs inside a Stop hook where it points elsewhere).

## The incident rule (strongly enforced)

A defect found in real usage is fixed **evidence-first**, with the proof-of-fix protocol:

1. Reproduce it deterministically *before* touching code — the smallest failing probe, recorded
   (`proof-of-fix record`, accepted only if it fails).
2. Fix the root cause — never the symptom, never a weakened probe.
3. Prove it with the same probe (`proof-of-fix check`), and land the repro as a **permanent test** in
   the owning suite (or `tests/harness/run.sh` when it crosses plugins).

No fix merges without its incident test. The commit message tells the incident honestly: what was
seen, the real root cause, how the repro proves the fix.

## Real-usage validation (the hermetic suites cannot cover this)

Hermetic tests idealize composition, environment, time, and state evolution. Two complements:

- **Observability first** — hooks persist evidence for their silent paths (e.g. every gate run writes
  verdict + output tail + duration to `.git/swd-gate.json`). A red seen only in a hook must be
  diagnosable from a file, never from speculation.
- **The E2E lane** — `bash tests/e2e/run.sh` replays seeded generated scenarios (flow × gate × CI)
  against the real sandbox forge `username-workspace/harness-e2e` (plan-steered CI): real pushes, PRs,
  checks and registration windows. Self-healing: stale `e2e/*` branches/PRs are garbage-collected,
  each failure is retried once to classify flake vs defect, and persistent failures file a labelled
  issue on this repo with the reproduction command. Run it deliberately (release, harness change,
  schedule) — it is excluded from the CI gate.

## Conventions

- Conventional Commits; never commit to `main` (branch + PR); no AI attribution.
- Versions bump together: `plugins/<name>/.claude-plugin/plugin.json` **and**
  `.claude-plugin/marketplace.json`.
- Shell-command config fields (`gate`, `judge_command`, …) are honored only from `.git/` or
  `--config` — never from cloneable working-tree files.
- Plugin state lives in `.git/<plugin>-*.json` (never committed); sibling coupling goes through those
  files and degrades to inert when the sibling is absent.
