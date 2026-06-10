---
name: proof-of-fix
description: >-
  Evidence-first bug fixing: prove the bug BEFORE touching code (a recorded probe that must FAIL),
  fix the root cause, then prove the fix with the SAME probe (`check` passes only when it runs
  green). Auto-engaging: a bug-shaped prompt ("fix", "bug", "regression", "ça casse", "échoue", …)
  injects the protocol into context, and a Stop hook re-runs an open repro itself — auto-closing it
  on green, handing back the failing output on red (bounded, never a loop). Use when fixing any bug,
  when asked to validate a fix empirically, or via /proof-of-fix. Horizontal: any repo, any stack —
  the probe is whatever command demonstrates the bug. Opt out per repo.
---

# proof-of-fix

A fix you cannot demonstrate is a guess. This skill turns "trust me, it's fixed" into two runs of the
same probe: **red before** the change, **green after** — the discipline that separates a root-cause
fix from a plausible-looking edit.

## The protocol

1. **Reproduce before touching code.** Write the smallest probe that demonstrates the bug — a failing
   test, a one-line command, a curl, a script. Record it:
   ```bash
   python3 scripts/repro.py record --cmd '<probe>'      # accepted ONLY if it fails
   ```
   `record` runs the probe and **refuses it if it exits 0** — a repro that passes proves nothing.
   If you cannot reproduce, say so and stop instead of fixing blind.
2. **Fix the root cause.** Never weaken the probe to make it pass — the probe is the contract.
3. **Prove the fix with the same probe.**
   ```bash
   python3 scripts/repro.py check                       # green → proven; red → failing output
   ```
   Share both runs (the recorded failure, the passing check) as the evidence for "fixed".

The best probe is a real test committed with the fix — `record --cmd 'pytest tests/test_x.py -k repro'`
— so the repro becomes a permanent regression guard. A throwaway command is fine when a test doesn't
fit; the discipline is the same.

## How it engages on its own

- **UserPromptSubmit** — when the prompt looks like a bug report or fix request (en/fr), the protocol
  is injected as context, **once per session per repo**. No repo in scope → silent.
- **Stop** — when a recorded repro is still open and the work-state changed since the last attempt,
  the hook **re-runs the probe itself**: green → the repro is auto-proven and a one-line
  `systemMessage` says so; red → a `block` hands the failing output back to the session to keep
  fixing. One attempt per work-state, capped at 5 per repro — an unconverging fix ends the turn, it
  never loops the Stop hook.

State lives in `.git/proof-of-fix.json` (never committed, one active repro per repo — the latest
recorded wins). Opt a repo out with `{ "enabled": false }` in `.proof-of-fix.json`.

## Manual / debug

```bash
python3 scripts/repro.py record --cmd 'pytest -x tests/test_bug.py'   # must fail to be accepted
python3 scripts/repro.py check                                        # must pass to prove the fix
python3 scripts/repro.py status                                       # current repro state JSON
python3 scripts/repro.py clear                                        # drop an obsolete repro
```

## Composes with the delivery harness

`record` → fix → `check` is the inner loop; ship-when-done / merge-review / mr-watchdog are the outer
loop (commit → review → push → PR → CI). A probe recorded as a real test makes the outer loop's gate
and CI inherit the regression guard for free.

## Dependencies

Only **`git`** and **Python 3** (stdlib) — the probe itself can be anything your shell runs.

## Caveats

- The probe runs with your shell privileges at `record`/`check`/Stop time — it is given by the live
  session, never read from a cloneable file. Keep probes fast (120s cap, timeout = still failing).
- One active repro per repo, by design (YAGNI) — fixing several bugs at once is the anti-pattern this
  skill exists to prevent.
- `check` proves the recorded probe passes — it cannot prove the probe was the *right* probe. A probe
  that never captured the bug stays your responsibility (that's why the failing `record` run is part
  of the evidence).
