# Orca Evidence Map

Status: Draft

Purpose: map planning questions to available evidence before proposing new infrastructure.

---

## Evidence sources currently available

- Historical run stdout logs (session transcripts)
- Run summaries (JSON)
- Metrics logs (`metrics.jsonl` where present)
- Queue history (issue states, dependency edits, notes)
- Commit/diff history tied to runs

---

## Question-to-evidence mapping

| Planning question | Primary evidence source(s) | Analysis method | Current confidence | Gap |
|---|---|---|---|---|
| Is task granularity too small? | stdout logs, queue history, summary cadence | classify runs by task size proxy, compare coordination overhead and rework | Low-Med | Need consistent task-size proxy |
| Are agents overengineering due to missing design intent? | task specs, diffs, reviewer notes | compare spec intent vs implementation scope | Low | Need explicit spec intent fields |
| Do knowledge artifacts influence behavior? | knowledge entries, subsequent run traces | trace whether known lessons are applied/ignored | Low | Weak linkage between knowledge and run behavior |
| Is queue steering quality improving outcomes? | queue edits, downstream run results | pre/post impact analysis on blocked/rework rates | Low | Need traceability from steering action to run cohort |
| Is summary quality sufficient for analysis? | summary JSON + manual audits | semantic quality scoring rubric | Low-Med | No shared rubric yet |
| Is formal A/B infra currently necessary? | unresolved decision log, repeated debates | count decisions blocked by evidence insufficiency | Medium | Need decision-stalemate tracking |

---

## Evidence collection principles

1. Use existing artifacts first.
2. Add new telemetry only when it closes a specific decision-critical gap.
3. Prefer lightweight, manually auditable analysis passes before automation.
4. Record assumptions made during analysis explicitly.
