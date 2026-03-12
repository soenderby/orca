# Async Monitor Goals & Future Notes

**Status:** Context + backlog notes (non-spec)  
**Date:** 2026-03-12  
**Authoritative implementation spec:** `docs/async-monitor-v0-spec.md`  
**Input narratives:** `docs/user-stories.md`

---

## Purpose of this document

This file is intentionally **not** an implementation spec.

Its job is to capture:
1. why we are building this,
2. the boundaries we want to preserve,
3. future ideas that are explicitly out of scope for the next implementation.

All implementation behavior should be taken from `docs/async-monitor-v0-spec.md`.

---

## What the user stories tell us

From `docs/user-stories.md`, the core pain is:
- multiple concurrent agents across projects,
- loss of operator attention due to context switching,
- need to return quickly to sessions that changed state,
- need to support both disposable task agents and long-lived persistent agents.

For this tool, we focus only on orchestration + monitoring concerns.

---

## Design boundary (important)

This tool follows a Unix-style boundary:
- small, composable commands,
- local terminal output,
- explicit state in simple files,
- no policy engine and no embedded project knowledge system.

This means we are **not** solving project memory/context management here.
That can be handled later by separate tools that integrate with this one.

---

## Current goals (for the next implementation)

1. Monitor managed Orca sessions in foreground.
2. Register and monitor externally started persistent sessions.
3. Provide one-step helper to create + register observed tmux targets.
4. Keep behavior deterministic, local, and notify-only.

---

## Non-goals for this cycle

- no daemon/service process,
- no auto-restart/retry,
- no remote notifications,
- no project context packaging protocol,
- no coupling with Emacs log tooling.

---

## Deferred future ideas (not part of v0 spec)

1. Daemonized monitor mode.
2. Heartbeat/artifact protocol for observed persistent agents.
3. Richer completion signaling for non-Orca persistent sessions.
4. Integration points for project/context bundles from external tools.
5. Better event sinks (desktop notifications, chat integrations, etc.).

These remain future options and should not alter v0 implementation scope.
