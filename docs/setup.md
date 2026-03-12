# Orca Setup Flow (Ubuntu/WSL)

This guide is the canonical onboarding flow for a new local Orca checkout.

## 1. Prerequisites

Required platform and tooling:

1. Ubuntu (WSL preferred)
2. `git`, `tmux`, `jq`, `flock`, `curl`, `python3`
3. `codex` CLI installed and available on `PATH`

## 2. Recommended Onboarding Sequence

Run the exact flow below from the repository root:

```bash
./orca.sh doctor
./orca.sh bootstrap --yes
./orca.sh doctor
```

Why this order:

1. first `doctor` captures baseline gaps without mutating anything
2. `bootstrap` applies guided remediations and fails hard on unresolved Codex auth
3. final `doctor` confirms readiness before `orca start`

For planning-only validation:

```bash
./orca.sh bootstrap --yes --dry-run
```

## 3. Required Manual Steps

`bootstrap` helps with automation, but these operator-owned steps still matter:

1. Codex auth:
```bash
codex login
codex login status
```
2. Git auth/push readiness:
```bash
git remote -v
GIT_TERMINAL_PROMPT=1 git ls-remote --exit-code origin HEAD
```
3. Shell `PATH` refresh (if `br` was newly installed):
```bash
export PATH="$HOME/.local/bin:$PATH"
hash -r
br --version
```

## 4. Troubleshooting Map

Use `./orca.sh doctor --json` to map failures by stable check ID.

Common failures and remediation:

1. `dep.br.present` or `dep.br.executable`
   - symptom: `br` missing or not runnable
   - action: install/repair `br`, then verify `br --version`
2. `dep.codex.present`
   - symptom: `codex` missing on `PATH`
   - action: install Codex CLI and confirm `codex --version`
3. `repo.origin_reachable` (warning)
   - symptom: cannot reach `origin` due network/auth
   - action: run `GIT_TERMINAL_PROMPT=1 git ls-remote --exit-code origin HEAD`
4. `queue.workspace_dir`, `queue.br_doctor`, `queue.id_prefix`
   - symptom: queue workspace missing/unhealthy
   - action: `br init`, `br doctor`, `br config set id.prefix orca`
5. Bootstrap fails at Codex gate
   - symptom: final bootstrap step errors with auth remediation
   - action:
```bash
codex login
codex login status
./orca.sh bootstrap --yes
```

## 5. Ready State Checklist

You are ready to launch sessions when:

1. `./orca.sh doctor` exits `0`
2. `./orca.sh doctor --json` reports `.ok == true`
3. `./orca.sh bootstrap --yes --dry-run` completes with no errors
