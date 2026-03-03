# Orca Plan: Migrating from Codex CLI to Pi

Status: Draft for discussion and refinement (not an implementation spec).

## 1) Purpose

This document proposes a staged migration path from direct Codex CLI usage to Pi as the execution harness in Orca.

Primary intent:
- keep current Orca workflow reliable,
- minimize migration risk,
- create a path to richer orchestration and observability later.

Non-goals (for now):
- immediate rewrite of Orca loop architecture,
- immediate adoption of custom extensions/skills,
- immediate model/provider changes.

---

## 2) Current Baseline (What Orca is coupled to today)

Orca currently assumes Codex-specific behavior in several places:

1. **Default runtime command** in `start.sh` / `agent-loop.sh` points to `codex exec ...`.
2. **Reasoning knob mapping** uses Codex-style `-c model_reasoning_effort=...`.
3. **Last message capture** relies on Codex flag `--output-last-message`.
4. **Token extraction** parses run log text (`tokens used` block), which is format-dependent.
5. **Operational expectations** are tuned around current Codex output/log shape.

This means a direct swap to Pi is feasible, but not fully equivalent without follow-up work.

---

## 3) Migration Strategy Overview

Recommended sequence:

1. **Minimal migration first**: Pi as a drop-in command runner, keep Orca loop structure unchanged.
2. **Structured integration second**: consume Pi JSON events for robust metrics/last-message capture.
3. **Optional expansion later**: use Pi extensions/skills/prompts where they clearly improve operator outcomes.

This keeps migration reversible and limits blast radius.

### 3.1 Strategic relationship to the redesign

This migration plan is tactical. It changes the runtime path used by the existing loop.

The redesign documents are strategic/architectural. They define longer-lived boundaries and principles: harness vs. agent responsibilities, invariant enforcement, optional-vs-mandatory context, and artifact/observability shape.

Tactical plans should serve those strategic goals, but they are not a substitute for them.

Because the operating environment is non-static (model/runtime behavior shifts, queue/task shape changes, operator workflow evolves), tactical execution can surface new information that invalidates assumptions. This plan should therefore be treated as revisable via an explicit feedback loop:

1. define hypothesis and success/failure criteria,
2. run canary,
3. compare against baseline metrics,
4. decide (promote/hold/rollback),
5. update plan and, if needed, strategic docs.

### 3.2 Thin runtime adapter layer (draft, non-final)

Status: proposal for discussion; contract details are intentionally non-final.

Goal: make runtime substitution (`codex`, `pi`, future variants) practical without turning Orca into a generic agent framework.

Design constraints:
- narrow seam: runtime invocation + artifact normalization only,
- no policy logic in adapter (claiming/merge/invariant policy stays in harness),
- rollback must remain fast (single switch),
- missing capability states must be explicit (`missing`/`parse_error`), never silently ignored.

Adapter responsibilities:
1. Construct runtime command from selected runtime/profile and shared run inputs.
2. Execute the runtime with the rendered prompt.
3. Normalize core outputs for the loop:
   - final assistant message artifact,
   - usage/token metrics artifact,
   - optional structured events artifact.
4. Expose capability metadata so harness logic can select compatible behavior.

Proposed control-plane contract (draft):
- `AGENT_RUNTIME` — selected runtime (`codex|pi`) (default remains project-defined).
- `AGENT_RUNTIME_PROFILE` — runtime profile (`codex-baseline|pi-minimal|pi-json`, extensible).
- `AGENT_RUNTIME_ADAPTER` — optional adapter entrypoint override (path/command).
- `AGENT_ALLOW_DIRECT_COMMAND` — `0|1`, default `0`; enables temporary adapter bypass for emergency rollback/debug.
- `AGENT_COMMAND` — legacy direct command escape hatch; honored only when `AGENT_ALLOW_DIRECT_COMMAND=1`.

Precedence rule (draft):
1. if `AGENT_ALLOW_DIRECT_COMMAND=1` and `AGENT_COMMAND` is set, run direct-command mode,
2. otherwise use adapter mode (`AGENT_RUNTIME` + `AGENT_RUNTIME_PROFILE` + optional `AGENT_RUNTIME_ADAPTER`).

Operational note (draft):
- Record execution mode in metrics (`adapter` vs `direct_command`) so comparisons remain attributable.

Proposed run contract (draft):
- Harness passes run inputs via env/args (prompt path, model, reasoning level, output paths).
- Adapter writes a single normalized result JSON artifact consumed by `agent-loop.sh`.
- Result artifact must include `schema_version` so the parser can evolve safely.
- Harness validates required fields and treats unknown/incompatible schema versions as explicit parse failures (never silent fallback).

Example normalized result artifact:

```json
{
  "schema_version": "orca.runtime-result.v1",
  "mode": "adapter",
  "runtime": "pi",
  "profile": "pi-minimal",
  "exit_code": 0,
  "final_message": {"status": "ok", "path": ".../last-message.md"},
  "usage": {"status": "missing", "input_tokens": null, "output_tokens": null, "total_tokens": null},
  "events": {"status": "missing", "path": null}
}
```

Proposed capability contract (draft):
- Adapter supports a lightweight `describe` operation returning capability flags, e.g.:
  - `supports_reasoning_level`
  - `supports_final_message_artifact`
  - `supports_structured_events`
  - `supports_usage_metrics`

Non-goals:
- not a provider-agnostic orchestration framework,
- not prompt-chain management,
- not moving harness correctness invariants into adapter/plugin code.

---

## 4) Minimal Initial Migration Plan (Low-Risk)

## M0 — Baseline and Guardrails

Goal: establish objective before/after comparison.

Actions:
1. Freeze and record current baseline metrics for a representative period (success rate, blocked rate, median run duration, operator intervention count).
2. Define explicit rollback criteria before any switch.
3. Add/confirm a single runtime switch in Orca (prefer adapter-mode `AGENT_RUNTIME` + `AGENT_RUNTIME_PROFILE`; keep direct-command override as break-glass only) so switching back is immediate.

Exit criteria:
- baseline snapshot exists,
- rollback criteria are documented,
- runtime switch mechanism is agreed.

## M1 — Pi Drop-In (Text Mode)

Goal: run Orca loops through Pi with minimal script changes.

Candidate runtime profile (example):

```bash
pi -p --no-session --no-extensions --no-skills --no-prompt-templates --model gpt-5.3-codex
```

Notes:
- keep model constant initially (Codex model via Pi) to isolate harness effects,
- disable optional Pi resources at first to maximize determinism,
- accept temporary reduction in token/last-message fidelity if needed.

Expected behavior changes in this phase:
- last-message capture may be weaker than Codex-specific path,
- token extraction may degrade to `missing/parse_error` until JSON integration.

Exit criteria:
- loops complete end-to-end,
- summary JSON contract still reliable,
- no major increase in failures vs baseline.

## M2 — Canary Rollout

Goal: validate reliability under realistic use.

Actions:
1. Run a limited canary (e.g., one agent on Pi, others unchanged).
2. Compare against baseline and active Codex runs on:
   - run success/failure mix,
   - merge safety behavior,
   - operator workload,
   - run-to-run variance.
3. Capture qualitative differences (prompt adherence, verbosity, issue claiming behavior).

Exit criteria:
- no severe regression,
- operator confidence that Pi can replace Codex path for standard runs.

## M3 — Decision Gate

Possible outcomes:
1. **Promote Pi as default runtime** (recommended if canary is stable), or
2. **Keep dual runtime mode** while hardening, or
3. **Revert and defer** (if regressions are operationally expensive).

Rollback trigger examples:
- sustained decline in completion rate,
- repeated coordination protocol misses,
- substantial operator babysitting overhead.

---

## 5) Further Options (Post-Minimal)

These are optional upgrades after basic migration stability.

### F1 — Pi JSON Event Integration (High value, moderate effort)

Why:
- replace fragile log scraping with structured events.

Potential upgrades:
1. Use `pi --mode json` for worker runs.
2. Parse `message_end` assistant usage for token/cost metrics.
3. Persist a deterministic “final assistant message” artifact from events.
4. Add richer run telemetry from tool execution events.

Tradeoff:
- more parser code in Orca, but much better observability and less format fragility.

### F2 — Runtime Profiles and Resource Isolation

Why:
- keep automation deterministic while still using Pi.

Potential upgrades:
1. Define explicit Orca Pi profiles (strict/experimental).
2. Keep strict profile with disabled extensions/skills by default.
3. Use controlled project-level Pi settings for reproducibility.

Tradeoff:
- extra profile maintenance, but cleaner operational boundaries.

### F3 — Extension-based Safety and Policy Hooks

Why:
- move some policy checks from prompt-only to enforceable runtime hooks.

Potential upgrades:
1. Path protection / destructive command confirmation.
2. Additional repo safety checks before risky commands.
3. Optional custom logging events for status/reporting.

Tradeoff:
- extension code adds maintenance/security surface.

### F4 — Role-specific Prompting and Skills

Why:
- aligns with redesign goals for specialized worker/inspector/librarian modes.

Potential upgrades:
1. Worker/inspector/librarian prompt templates via Pi prompts.
2. Focused skills for recurring workflows (queue triage, dependency analysis, status synthesis).

Tradeoff:
- faster evolution, but higher context/resource management complexity.

### F5 — Provider and Model Strategy

Why:
- Pi enables multi-provider portability without changing harness again.

Potential upgrades:
1. Keep Codex for coding loops, evaluate alternatives for inspector/review tasks.
2. Use staged model experimentation with measurable criteria.

Tradeoff:
- portability and optionality vs expanded tuning matrix.

---

## 6) Tradeoff Considerations

| Dimension | Potential Benefit | Potential Drawback | Mitigation |
|---|---|---|---|
| Integration surface | JSON/RPC/SDK are stronger than plain CLI output parsing | More moving parts | Phase adoption; keep fallback path |
| Extensibility | Extensions/skills/prompts can accelerate workflow evolution | Configuration sprawl and hidden behavior | Start with strict profile; no auto extras |
| Observability | Structured usage/tool events improve metrics quality | Requires parser and schema work | Implement after minimal cutover |
| Determinism | Pi can be run in minimal mode | Default auto-discovery can reduce reproducibility | Use explicit `--no-*` profile initially |
| Security | Can implement custom gates in extensions | Extensions/packages are arbitrary code | Trust policy + code review + pinning |
| Migration cost | Early low-risk path is simple | Full parity (last message/tokens) requires follow-up | Stage work; prioritize high ROI items |
| Lock-in | Pi supports multiple providers/models | New dependency on Pi behavior/versioning | Version pinning + rollback-compatible runtime switch |

---

## 7) Key Open Questions

1. Should Orca maintain **permanent dual-runtime support** (`codex` + `pi`) or treat Codex path as temporary fallback only?
2. What is the minimum acceptable observability parity before promoting Pi to default?
3. Do we want to rely on Pi context files (`AGENTS.md`) in worker runs, or isolate worker behavior strictly through injected prompt content?
4. At what point do extensions become justified vs “just keep shell scripts”?

---

## 8) Suggested Evaluation Criteria

Use a fixed comparison window and score each candidate profile on:

1. Completion rate / blocked rate
2. Median run time and variance
3. Merge safety incidents / claim discipline issues
4. Operator intervention frequency
5. Metrics fidelity (token/cost completeness, artifact quality)
6. Reproducibility and ease of rollback

Promote only if reliability is not worse and operational friction is not higher.

---

## 9) Decision Matrix (for Go / Hold / No-Go)

Use this matrix after M2 canary to compare options (e.g., `codex-baseline`, `pi-minimal`, `pi+json`, `pi+extensions`).

Scoring scale per criterion:
- **1** = poor / materially worse than baseline
- **3** = acceptable / roughly neutral
- **5** = clearly better than baseline

### Weighted criteria

| Criterion | Weight | What to measure |
|---|---:|---|
| **Observability** | **40%** | Metrics completeness, token/cost fidelity, deterministic artifact capture, ease of debugging run failures |
| **Extensibility** | **35%** | Effort to add new roles/workflows, policy hooks, provider/model options, integration flexibility (JSON/RPC/SDK) |
| **Operational simplicity** | **25%** | Day-2 operator burden, setup complexity, reproducibility, rollback speed |

### Scoring template

| Option | Observability (40) | Extensibility (35) | Operational simplicity (25) | Weighted total (100) | Notes |
|---|---:|---:|---:|---:|---|
| codex-baseline |  |  |  |  |  |
| pi-minimal |  |  |  |  |  |
| pi+json |  |  |  |  |  |
| pi+extensions |  |  |  |  |  |

Weighted total formula:

```text
total = (obs_score/5)*40 + (ext_score/5)*35 + (ops_score/5)*25
```

### Hard gates (must pass regardless of score)

1. **Reliability gate**: completion rate and blocked/failure rate are not materially worse than baseline across the comparison window.
2. **Safety gate**: no increase in merge/claim protocol violations or unsafe write behavior.
3. **Rollback gate**: operator can revert runtime mode quickly with no data-path breakage.

### Suggested decision thresholds

- **Promote**: weighted total ≥ 75 **and** all hard gates pass.
- **Hold / iterate**: weighted total 60–74, or gates pass but high-variance behavior remains.
- **No-Go / defer**: weighted total < 60, or any hard gate fails.

---

## 10) Recommendation

Adopt **minimal Pi migration first** (drop-in runtime, strict profile, same model), then decide on JSON integration once stability is proven.

This path captures most strategic upside (future flexibility and better interfaces) while containing near-term risk.
