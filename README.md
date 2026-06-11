# skills

Open, horizontal, re-usable Claude Code skills & plugins by **Username** ([Studio A.I.](https://username.digital)).
Company-specific (vertical) skills live in a separate private repo.

## Install

```text
/plugin marketplace add username-workspace/skills
/plugin install <plugin>@username
```

## The delivery harness

Four of these plugins compose into an autonomous delivery pipeline — each one useful alone, loosely
coupled through `.git` state when together:

**ship-when-done** commits at each milestone and opens the draft PR only when the work is provably
done (quality gate green) → **merge-review** holds every push until an adversarial review passes →
**mr-watchdog** watches the PR's CI in the background and brings the verdict back into the session
(`ok, all good — CI green`) → **proof-of-fix** enforces evidence-first bug fixing: a recorded probe
that fails before the fix and passes after it.

## Plugins

<!-- plugins:begin -->
| Plugin | Version | Category | What it does |
|---|---|---|---|
| [`claude-remote-spawn`](./plugins/claude-remote-spawn) | 1.3.0 | Agents | Spawn a new Claude Code session remotely, on your own machine. |
| [`find-session`](./plugins/find-session) | 1.0.4 | Agents | Find and resume the past Claude Code session you're thinking of. |
| [`delivery-metrics`](./plugins/delivery-metrics) | 1.0.6 | Analytics | Turn git history into a developer productivity & quality dashboard. |
| [`aws-remote-auth`](./plugins/aws-remote-auth) | 1.0.3 | DevOps | Re-authenticate to AWS from anywhere, on demand, with an autofill device code. |
| [`mr-watchdog`](./plugins/mr-watchdog) | 2.2.0 | DevOps | Open a merge request, then forget it — a background watcher follows its CI and hands the verdict back to your session. |
| [`ship-when-done`](./plugins/ship-when-done) | 1.6.0 | DevOps | Commit at each milestone, push so nothing is lost, open the PR when it's actually done. |
| [`coding-agent-usage`](./plugins/coding-agent-usage) | 1.2.1 | FinOps | See your AI coding-agent usage — and where you rank against other developers. |
| [`merge-review`](./plugins/merge-review) | 1.2.0 | Quality | An adversarial reviewer that scores the diff, fixes what's attested, and loops until it's merge-ready. |
| [`proof-of-fix`](./plugins/proof-of-fix) | 1.0.1 | Quality | Prove the bug before fixing it — then prove the fix with the same probe. Red before, green after. |
| [`security-audit`](./plugins/security-audit) | 1.3.3 | Security | One Trivy scan, every ecosystem — a prioritised security report. |
<!-- plugins:end -->

## Quality

Every plugin ships a hermetic test suite — `bash scripts/run-tests.sh` runs them all (CI gate).
Real usage is validated separately: a generative E2E lane (`tests/e2e/`) replays full deliveries —
seeded scenarios, project archetypes, human-divergence twists — against a real sandbox forge, and
every proven situation is recorded in `tests/e2e/coverage.json`. Engineering rules (the incident
rule, symptom vs root cause) live in [CLAUDE.md](./CLAUDE.md).

## License

MIT — see [LICENSE](./LICENSE).
