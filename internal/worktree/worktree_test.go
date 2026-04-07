package worktree

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestSetupCreatesWorktreesAndIsIdempotent(t *testing.T) {
	repo := initRepo(t, "main")
	writeAndCommit(t, repo, "README.md", "seed\n", "seed")

	result, err := Setup(SetupConfig{RepoPath: repo, Count: 2})
	if err != nil {
		t.Fatalf("setup worktrees: %v", err)
	}
	if result.BaseRef != "main" {
		t.Fatalf("base ref mismatch: got %q want main", result.BaseRef)
	}
	if len(result.Created) != 2 {
		t.Fatalf("expected 2 created worktrees, got %#v", result.Created)
	}

	wt1 := filepath.Join(repo, "worktrees", "agent-1")
	wt2 := filepath.Join(repo, "worktrees", "agent-2")
	if _, err := os.Stat(wt1); err != nil {
		t.Fatalf("missing worktree 1: %v", err)
	}
	if _, err := os.Stat(wt2); err != nil {
		t.Fatalf("missing worktree 2: %v", err)
	}

	branch1 := runGitOutput(t, wt1, "branch", "--show-current")
	if branch1 != "swarm/agent-1" {
		t.Fatalf("unexpected branch for agent-1: %q", branch1)
	}
	branch2 := runGitOutput(t, wt2, "branch", "--show-current")
	if branch2 != "swarm/agent-2" {
		t.Fatalf("unexpected branch for agent-2: %q", branch2)
	}

	again, err := Setup(SetupConfig{RepoPath: repo, Count: 2})
	if err != nil {
		t.Fatalf("idempotent setup failed: %v", err)
	}
	if len(again.Created) != 0 {
		t.Fatalf("expected no created worktrees on second run, got %#v", again.Created)
	}
	if len(again.Existing) != 2 {
		t.Fatalf("expected 2 existing worktrees on second run, got %#v", again.Existing)
	}
}

func TestResolveBaseRefOrder(t *testing.T) {
	t.Run("explicit override wins", func(t *testing.T) {
		repo := initRepo(t, "main")
		writeAndCommit(t, repo, "a.txt", "a\n", "a")
		writeAndCommit(t, repo, "b.txt", "b\n", "b")

		base, _, err := resolveBaseRef(repo, "main~1")
		if err != nil {
			t.Fatalf("resolve base ref: %v", err)
		}
		if base != "main~1" {
			t.Fatalf("base ref mismatch: got %q want main~1", base)
		}
	})

	t.Run("local main preferred", func(t *testing.T) {
		repo := initRepo(t, "main")
		writeAndCommit(t, repo, "a.txt", "a\n", "a")

		base, _, err := resolveBaseRef(repo, "")
		if err != nil {
			t.Fatalf("resolve base ref: %v", err)
		}
		if base != "main" {
			t.Fatalf("base ref mismatch: got %q want main", base)
		}
	})

	t.Run("origin main when local main missing", func(t *testing.T) {
		remote, local := seedRemoteAndClone(t)
		_ = remote
		runGitCmd(t, local, "checkout", "-b", "dev")
		runGitCmd(t, local, "branch", "-D", "main")

		base, _, err := resolveBaseRef(local, "")
		if err != nil {
			t.Fatalf("resolve base ref: %v", err)
		}
		if base != "origin/main" {
			t.Fatalf("base ref mismatch: got %q want origin/main", base)
		}
	})

	t.Run("current branch fallback", func(t *testing.T) {
		repo := initRepo(t, "dev")
		writeAndCommit(t, repo, "a.txt", "a\n", "a")

		base, _, err := resolveBaseRef(repo, "")
		if err != nil {
			t.Fatalf("resolve base ref: %v", err)
		}
		if base != "dev" {
			t.Fatalf("base ref mismatch: got %q want dev", base)
		}
	})
}

func TestResolveBaseRefWarnsOnDivergence(t *testing.T) {
	remote, local := seedRemoteAndClone(t)
	other := cloneRepo(t, remote, "other")
	configUser(t, other)

	writeAndCommit(t, local, "local.txt", "local\n", "local")
	writeAndCommit(t, other, "remote.txt", "remote\n", "remote")
	runGitCmd(t, other, "push", "origin", "main")
	runGitCmd(t, local, "fetch", "origin", "main")

	base, warnings, err := resolveBaseRef(local, "")
	if err != nil {
		t.Fatalf("resolve base ref: %v", err)
	}
	if base != "main" {
		t.Fatalf("base ref mismatch: got %q want main", base)
	}

	joined := strings.Join(warnings, "\n")
	if !strings.Contains(joined, "local main and origin/main differ") {
		t.Fatalf("expected divergence warning, got %#v", warnings)
	}
}

func TestSetupRejectsInvalidExplicitBaseRef(t *testing.T) {
	repo := initRepo(t, "main")
	writeAndCommit(t, repo, "README.md", "seed\n", "seed")

	_, err := Setup(SetupConfig{
		RepoPath:        repo,
		Count:           1,
		BaseRefOverride: "does-not-exist",
	})
	if err == nil {
		t.Fatal("expected invalid ORCA_BASE_REF error")
	}
	if !strings.Contains(err.Error(), "ORCA_BASE_REF does not resolve") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func initRepo(t *testing.T, initialBranch string) string {
	t.Helper()
	repo := t.TempDir()
	runGitCmd(t, "", "init", "-b", initialBranch, repo)
	configUser(t, repo)
	return repo
}

func initBareRepo(t *testing.T) string {
	t.Helper()
	bare := filepath.Join(t.TempDir(), "remote.git")
	runGitCmd(t, "", "init", "--bare", bare)
	return bare
}

func seedRemoteAndClone(t *testing.T) (remote string, local string) {
	t.Helper()
	remote = initBareRepo(t)
	seed := initRepo(t, "main")
	runGitCmd(t, seed, "remote", "add", "origin", remote)
	writeAndCommit(t, seed, "README.md", "seed\n", "seed")
	runGitCmd(t, seed, "push", "-u", "origin", "main")

	local = cloneRepo(t, remote, "local")
	configUser(t, local)
	return remote, local
}

func cloneRepo(t *testing.T, remote, name string) string {
	t.Helper()
	dst := filepath.Join(t.TempDir(), name)
	runGitCmd(t, "", "clone", "-b", "main", remote, dst)
	return dst
}

func configUser(t *testing.T, repo string) {
	t.Helper()
	runGitCmd(t, repo, "config", "user.name", "Orca Test")
	runGitCmd(t, repo, "config", "user.email", "orca-test@example.com")
}

func writeAndCommit(t *testing.T, repo, rel, content, message string) {
	t.Helper()
	full := filepath.Join(repo, rel)
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		t.Fatalf("mkdir parent: %v", err)
	}
	if err := os.WriteFile(full, []byte(content), 0o644); err != nil {
		t.Fatalf("write file: %v", err)
	}
	runGitCmd(t, repo, "add", rel)
	runGitCmd(t, repo, "commit", "-m", message)
}

func runGitOutput(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %s failed: %v\n%s", strings.Join(args, " "), err, out)
	}
	return strings.TrimSpace(string(out))
}

func runGitCmd(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", args...)
	if dir != "" {
		cmd.Dir = dir
	}
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %s failed: %v\n%s", strings.Join(args, " "), err, out)
	}
}
