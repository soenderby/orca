package git

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestRepoRootCommonDirCurrentBranchAndClean(t *testing.T) {
	repo := initRepo(t)

	root, err := RepoRoot(repo)
	if err != nil {
		t.Fatalf("repo root: %v", err)
	}
	if root != repo {
		t.Fatalf("repo root mismatch: got %q want %q", root, repo)
	}

	common, err := CommonDir(repo)
	if err != nil {
		t.Fatalf("common dir: %v", err)
	}
	if _, err := os.Stat(common); err != nil {
		t.Fatalf("common dir should exist: %v", err)
	}

	branch, err := CurrentBranch(repo)
	if err != nil {
		t.Fatalf("current branch: %v", err)
	}
	if branch != "main" {
		t.Fatalf("branch mismatch: got %q want main", branch)
	}

	clean, err := IsClean(repo)
	if err != nil {
		t.Fatalf("is clean: %v", err)
	}
	if !clean {
		t.Fatal("repo should start clean")
	}

	if err := os.WriteFile(filepath.Join(repo, "untracked.txt"), []byte("x"), 0o644); err != nil {
		t.Fatalf("write untracked file: %v", err)
	}
	clean, err = IsClean(repo)
	if err != nil {
		t.Fatalf("is clean after change: %v", err)
	}
	if clean {
		t.Fatal("repo should be dirty with untracked file")
	}
}

func TestCreateBranchMergeAndMergeAbort(t *testing.T) {
	repo := initRepo(t)
	writeAndCommit(t, repo, "base.txt", "base\n", "base")

	if err := CreateBranch(repo, "feature", "main"); err != nil {
		t.Fatalf("create feature branch: %v", err)
	}
	writeAndCommit(t, repo, "feature.txt", "feature\n", "feature")

	runGitCmd(t, repo, "checkout", "main")
	if err := Merge(repo, "feature"); err != nil {
		t.Fatalf("merge feature into main: %v", err)
	}
	if _, err := os.Stat(filepath.Join(repo, "feature.txt")); err != nil {
		t.Fatalf("expected merged file: %v", err)
	}

	// conflict case + merge abort
	if err := CreateBranch(repo, "conflict-a", "main"); err != nil {
		t.Fatalf("create conflict-a: %v", err)
	}
	writeAndCommit(t, repo, "conflict.txt", "a\n", "conflict a")

	runGitCmd(t, repo, "checkout", "main")
	if err := CreateBranch(repo, "conflict-b", "main"); err != nil {
		t.Fatalf("create conflict-b: %v", err)
	}
	writeAndCommit(t, repo, "conflict.txt", "b\n", "conflict b")

	runGitCmd(t, repo, "checkout", "main")
	if err := Merge(repo, "conflict-a"); err != nil {
		t.Fatalf("merge conflict-a into main: %v", err)
	}
	if err := Merge(repo, "conflict-b"); err == nil {
		t.Fatal("expected conflict merge to fail")
	}

	if err := MergeAbort(repo); err != nil {
		t.Fatalf("merge abort failed: %v", err)
	}
	if out, err := runGit(repo, "rev-parse", "-q", "--verify", "MERGE_HEAD"); err == nil {
		t.Fatalf("merge should be aborted, MERGE_HEAD still present: %q", out)
	}
}

func TestHasBeadsChanges(t *testing.T) {
	repo := initRepo(t)
	mkdir(t, filepath.Join(repo, ".beads"))
	writeAndCommit(t, repo, ".beads/issues.jsonl", "{}\n", "seed beads")

	if err := CreateBranch(repo, "feature", "main"); err != nil {
		t.Fatalf("create feature: %v", err)
	}
	writeAndCommit(t, repo, "other.txt", "no beads\n", "non beads change")

	changed, err := HasBeadsChanges(repo, "main")
	if err != nil {
		t.Fatalf("has beads changes: %v", err)
	}
	if changed {
		t.Fatal("expected no .beads changes")
	}

	writeAndCommit(t, repo, ".beads/issues.jsonl", "{\"id\":\"orca-1\"}\n", "beads change")
	changed, err = HasBeadsChanges(repo, "main")
	if err != nil {
		t.Fatalf("has beads changes after update: %v", err)
	}
	if !changed {
		t.Fatal("expected .beads changes")
	}
}

func TestWorktreesAndAddWorktree(t *testing.T) {
	repo := initRepo(t)
	writeAndCommit(t, repo, "base.txt", "base\n", "base")

	wtPath := filepath.Join(t.TempDir(), "agent-1")
	if err := AddWorktree(repo, wtPath, "swarm/agent-1", "main"); err != nil {
		t.Fatalf("add worktree: %v", err)
	}

	items, err := Worktrees(repo)
	if err != nil {
		t.Fatalf("list worktrees: %v", err)
	}

	foundMain := false
	foundAgent := false
	for _, item := range items {
		if item.Path == repo && item.Branch == "main" {
			foundMain = true
		}
		if item.Path == wtPath && item.Branch == "swarm/agent-1" {
			foundAgent = true
		}
	}
	if !foundMain || !foundAgent {
		t.Fatalf("expected main and agent worktrees, got %#v", items)
	}
}

func TestFetchPullPushAheadBehind(t *testing.T) {
	remote := initBareRepo(t)

	author := initRepo(t)
	runGitCmd(t, author, "remote", "add", "origin", remote)
	writeAndCommit(t, author, "README.md", "seed\n", "seed")
	runGitCmd(t, author, "push", "-u", "origin", "main")

	local := cloneRepo(t, remote, "local")
	configUser(t, local)
	other := cloneRepo(t, remote, "other")
	configUser(t, other)

	// remote gets one commit local doesn't have (local behind by 1).
	writeAndCommit(t, other, "remote.txt", "remote\n", "remote commit")
	runGitCmd(t, other, "push", "origin", "main")

	// local gets one commit remote doesn't have (local ahead by 1).
	writeAndCommit(t, local, "local.txt", "local\n", "local commit")
	runGitCmd(t, local, "fetch", "origin", "main")

	ahead, behind, err := AheadBehind(local, "main", "origin/main")
	if err != nil {
		t.Fatalf("ahead/behind: %v", err)
	}
	if ahead != 1 || behind != 1 {
		t.Fatalf("ahead/behind mismatch: got %d/%d want 1/1", ahead, behind)
	}

	// Push should fail while behind.
	if err := Push(local); err == nil {
		t.Fatal("expected push to fail when behind")
	}

	// Reconcile by resetting local to origin/main, then pull should be no-op.
	runGitCmd(t, local, "reset", "--hard", "origin/main")
	if err := FetchAndPull(local); err != nil {
		t.Fatalf("fetch and pull: %v", err)
	}

	// Now commit + push should succeed.
	writeAndCommit(t, local, "after-sync.txt", "ok\n", "after sync")
	if err := Push(local); err != nil {
		t.Fatalf("push after sync: %v", err)
	}

	// Verify remote has pushed commit.
	localHead, err := runGit(local, "rev-parse", "HEAD")
	if err != nil {
		t.Fatalf("local head: %v", err)
	}
	runGitCmd(t, other, "fetch", "origin", "main")
	remoteHead, err := runGit(other, "rev-parse", "origin/main")
	if err != nil {
		t.Fatalf("remote head after fetch: %v", err)
	}
	if localHead != remoteHead {
		t.Fatalf("remote head mismatch: local=%q remote=%q", localHead, remoteHead)
	}
}

func TestDescribe(t *testing.T) {
	repo := initRepo(t)
	writeAndCommit(t, repo, "README.md", "hello\n", "seed")

	desc, err := Describe(repo)
	if err != nil {
		t.Fatalf("describe: %v", err)
	}
	if desc == "" {
		t.Fatal("describe output should not be empty")
	}

	if err := os.WriteFile(filepath.Join(repo, "README.md"), []byte("dirty\n"), 0o644); err != nil {
		t.Fatalf("write dirty file: %v", err)
	}
	dirty, err := Describe(repo)
	if err != nil {
		t.Fatalf("describe dirty: %v", err)
	}
	if !strings.Contains(dirty, "dirty") {
		t.Fatalf("expected dirty describe output, got %q", dirty)
	}
}

func initRepo(t *testing.T) string {
	t.Helper()
	repo := t.TempDir()
	runGitCmd(t, "", "init", "-b", "main", repo)
	configUser(t, repo)
	return repo
}

func initBareRepo(t *testing.T) string {
	t.Helper()
	bare := filepath.Join(t.TempDir(), "remote.git")
	runGitCmd(t, "", "init", "--bare", bare)
	return bare
}

func cloneRepo(t *testing.T, remote, name string) string {
	t.Helper()
	base := t.TempDir()
	dst := filepath.Join(base, name)
	runGitCmd(t, "", "clone", "-b", "main", remote, dst)
	return dst
}

func configUser(t *testing.T, repo string) {
	t.Helper()
	runGitCmd(t, repo, "config", "user.name", "Orca Test")
	runGitCmd(t, repo, "config", "user.email", "orca-test@example.com")
}

func writeAndCommit(t *testing.T, repo, rel, content, msg string) {
	t.Helper()
	full := filepath.Join(repo, rel)
	mkdir(t, filepath.Dir(full))
	if err := os.WriteFile(full, []byte(content), 0o644); err != nil {
		t.Fatalf("write %s: %v", rel, err)
	}
	runGitCmd(t, repo, "add", rel)
	runGitCmd(t, repo, "commit", "-m", msg)
}

func mkdir(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(path, 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", path, err)
	}
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

func TestParseWorktreePorcelain(t *testing.T) {
	raw := strings.TrimSpace(`
worktree /repo
HEAD deadbeef
branch refs/heads/main

worktree /repo/worktrees/agent-1
HEAD cafebabe
branch refs/heads/swarm/agent-1
locked
prunable
`)

	items := parseWorktreePorcelain(raw)
	if len(items) != 2 {
		t.Fatalf("expected 2 worktrees, got %d", len(items))
	}

	if items[0].Path != "/repo" || items[0].Branch != "main" {
		t.Fatalf("unexpected first worktree: %#v", items[0])
	}
	if items[1].Path != "/repo/worktrees/agent-1" || items[1].Branch != "swarm/agent-1" {
		t.Fatalf("unexpected second worktree: %#v", items[1])
	}
	if !items[1].Locked || !items[1].Prunable {
		t.Fatalf("expected lock/prunable flags on second worktree: %#v", items[1])
	}
}

func TestAheadBehindValidation(t *testing.T) {
	if _, _, err := AheadBehind(".", "", "origin/main"); err == nil {
		t.Fatal("expected validation error for missing local ref")
	}
	if _, _, err := AheadBehind(".", "main", ""); err == nil {
		t.Fatal("expected validation error for missing remote ref")
	}
}

func TestAddWorktreeValidation(t *testing.T) {
	repo := initRepo(t)
	if err := AddWorktree(repo, "", "branch", "main"); err == nil {
		t.Fatal("expected error for empty worktree path")
	}
	if err := AddWorktree(repo, filepath.Join(t.TempDir(), "wt"), "", "main"); err == nil {
		t.Fatal("expected error for empty branch")
	}
}

func TestHasBeadsChangesValidation(t *testing.T) {
	repo := initRepo(t)
	if _, err := HasBeadsChanges(repo, ""); err == nil {
		t.Fatal("expected error for empty base ref")
	}
}

func TestCreateBranchValidation(t *testing.T) {
	repo := initRepo(t)
	if err := CreateBranch(repo, "", "main"); err == nil {
		t.Fatal("expected empty branch name error")
	}
	if err := CreateBranch(repo, "feature", ""); err == nil {
		t.Fatal("expected empty base error")
	}
}

func TestPushValidationDetachedHead(t *testing.T) {
	repo := initRepo(t)
	writeAndCommit(t, repo, "a.txt", "a\n", "a")
	runGitCmd(t, repo, "checkout", "--detach")
	if err := Push(repo); err == nil || !strings.Contains(err.Error(), "detached") {
		t.Fatalf("expected detached head push error, got %v", err)
	}
}

func TestFetchPullValidationDetachedHead(t *testing.T) {
	repo := initRepo(t)
	writeAndCommit(t, repo, "a.txt", "a\n", "a")
	runGitCmd(t, repo, "checkout", "--detach")
	if err := FetchAndPull(repo); err == nil || !strings.Contains(err.Error(), "detached") {
		t.Fatalf("expected detached head fetch/pull error, got %v", err)
	}
}

func ExampleAheadBehind() {
	fmt.Println("ahead and behind counts are computed from local...remote")
	// Output: ahead and behind counts are computed from local...remote
}
