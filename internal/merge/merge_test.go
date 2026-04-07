package merge

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	gitops "github.com/soenderby/orca/internal/git"
)

type countingLocker struct {
	calls int
}

func (l *countingLocker) WithLock(_ string, _ time.Duration, fn func() error) error {
	l.calls++
	return fn()
}

func TestMergeToMain_Success(t *testing.T) {
	remote, primary := seedRemoteAndClone(t)
	_ = remote
	observer := cloneRepo(t, remote, "observer")
	configUser(t, observer)

	runGitCmd(t, primary, "checkout", "-b", "feature/success", "main")
	writeAndCommit(t, primary, "feature.txt", "hello\n", "feature work")
	runGitCmd(t, primary, "checkout", "main")

	locker := &countingLocker{}
	err := MergeToMain(MergeConfig{
		PrimaryRepo: primary,
		Source:      "feature/success",
		Locker:      locker,
		LockScope:   "merge",
		LockTimeout: time.Second,
	})
	if err != nil {
		t.Fatalf("merge to main failed: %v", err)
	}
	if locker.calls != 1 {
		t.Fatalf("expected one lock call, got %d", locker.calls)
	}

	if _, err := os.Stat(filepath.Join(primary, "feature.txt")); err != nil {
		t.Fatalf("expected merged file in primary: %v", err)
	}

	localMainHead := runGitOutput(t, primary, "rev-parse", "main")
	runGitCmd(t, observer, "fetch", "origin", "main")
	remoteMainHead := runGitOutput(t, observer, "rev-parse", "origin/main")
	if localMainHead != remoteMainHead {
		t.Fatalf("remote main head mismatch: local=%q remote=%q", localMainHead, remoteMainHead)
	}
}

func TestMergeToMain_RejectsBeadsChangesInSource(t *testing.T) {
	_, primary := seedRemoteAndClone(t)

	runGitCmd(t, primary, "checkout", "-b", "feature/beads", "main")
	writeAndCommit(t, primary, ".beads/issues.jsonl", "{}\n", "beads update")
	runGitCmd(t, primary, "checkout", "main")

	err := MergeToMain(MergeConfig{
		PrimaryRepo: primary,
		Source:      "feature/beads",
		LockScope:   "merge",
		LockTimeout: time.Second,
	})
	if err == nil {
		t.Fatal("expected .beads rejection error")
	}
	if !strings.Contains(err.Error(), ".beads") {
		t.Fatalf("expected .beads error, got: %v", err)
	}

	if _, err := os.Stat(filepath.Join(primary, ".beads", "issues.jsonl")); !os.IsNotExist(err) {
		t.Fatalf(".beads file should not be merged onto main, stat err=%v", err)
	}
}

func TestMergeToMain_RejectsDirtyPrimaryRepo(t *testing.T) {
	_, primary := seedRemoteAndClone(t)

	if err := os.WriteFile(filepath.Join(primary, "dirty.txt"), []byte("dirty\n"), 0o644); err != nil {
		t.Fatalf("write dirty file: %v", err)
	}

	err := MergeToMain(MergeConfig{
		PrimaryRepo: primary,
		Source:      "main",
		LockScope:   "merge",
		LockTimeout: time.Second,
	})
	if err == nil {
		t.Fatal("expected dirty repo rejection")
	}
	if !strings.Contains(err.Error(), "uncommitted changes") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestMergeToMain_MergeConflictCleanup(t *testing.T) {
	_, primary := seedRemoteAndClone(t)
	writeAndCommit(t, primary, "conflict.txt", "base\n", "base")
	runGitCmd(t, primary, "push", "origin", "main")

	runGitCmd(t, primary, "checkout", "-b", "feature/conflict", "main")
	writeAndCommit(t, primary, "conflict.txt", "feature\n", "feature conflict")

	runGitCmd(t, primary, "checkout", "main")
	writeAndCommit(t, primary, "conflict.txt", "main\n", "main conflict")

	err := MergeToMain(MergeConfig{
		PrimaryRepo: primary,
		Source:      "feature/conflict",
		LockScope:   "merge",
		LockTimeout: time.Second,
	})
	if err == nil {
		t.Fatal("expected merge conflict error")
	}

	if _, err := runGit(primary, "rev-parse", "-q", "--verify", "MERGE_HEAD"); err == nil {
		t.Fatal("merge cleanup failed: MERGE_HEAD still exists")
	}

	clean, err := gitops.IsClean(primary)
	if err != nil {
		t.Fatalf("check repo clean after conflict: %v", err)
	}
	if !clean {
		t.Fatal("repo should be clean after merge conflict cleanup")
	}
}

func TestMergeToMain_Validation(t *testing.T) {
	if err := MergeToMain(MergeConfig{}); err == nil {
		t.Fatal("expected validation error for empty config")
	}

	if err := MergeToMain(MergeConfig{PrimaryRepo: "."}); err == nil {
		t.Fatal("expected validation error for empty source branch")
	}
}

func seedRemoteAndClone(t *testing.T) (remote string, primary string) {
	t.Helper()

	remote = initBareRepo(t)
	seed := initRepo(t)
	runGitCmd(t, seed, "remote", "add", "origin", remote)
	writeAndCommit(t, seed, "README.md", "seed\n", "seed")
	runGitCmd(t, seed, "push", "-u", "origin", "main")

	primary = cloneRepo(t, remote, "primary")
	configUser(t, primary)
	return remote, primary
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
	dir := filepath.Join(t.TempDir(), "remote.git")
	runGitCmd(t, "", "init", "--bare", dir)
	return dir
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

func writeAndCommit(t *testing.T, repo, rel, content, msg string) {
	t.Helper()
	full := filepath.Join(repo, rel)
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		t.Fatalf("mkdir parent: %v", err)
	}
	if err := os.WriteFile(full, []byte(content), 0o644); err != nil {
		t.Fatalf("write file: %v", err)
	}
	runGitCmd(t, repo, "add", rel)
	runGitCmd(t, repo, "commit", "-m", msg)
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

func runGitOutput(t *testing.T, dir string, args ...string) string {
	t.Helper()
	out, err := runGit(dir, args...)
	if err != nil {
		t.Fatalf("git %s failed: %v", strings.Join(args, " "), err)
	}
	return strings.TrimSpace(out)
}

func runGit(dir string, args ...string) (string, error) {
	cmd := exec.Command("git", args...)
	if dir != "" {
		cmd.Dir = dir
	}
	out, err := cmd.CombinedOutput()
	if err != nil {
		trimmed := strings.TrimSpace(string(out))
		if trimmed == "" {
			return "", err
		}
		return "", errors.New(trimmed)
	}
	return strings.TrimSpace(string(out)), nil
}
