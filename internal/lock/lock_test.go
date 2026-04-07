package lock

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestWithLock_AcquiresAndReleases(t *testing.T) {
	commonDir := t.TempDir()
	locker := testLocker(commonDir)

	called := false
	err := locker.WithLock("merge", 2*time.Second, func() error {
		called = true
		return nil
	})
	if err != nil {
		t.Fatalf("with lock failed: %v", err)
	}
	if !called {
		t.Fatal("lock callback was not called")
	}

	if _, err := os.Stat(filepath.Join(commonDir, "orca-global.lock")); err != nil {
		t.Fatalf("expected merge lock file to exist: %v", err)
	}

	if err := locker.WithLock("merge", 2*time.Second, func() error { return nil }); err != nil {
		t.Fatalf("second lock attempt should succeed after release: %v", err)
	}
}

func TestWithLock_ConcurrentAttemptsBlock(t *testing.T) {
	commonDir := t.TempDir()
	lockFile := filepath.Join(commonDir, "orca-global.lock")
	readyFile := filepath.Join(commonDir, "ready")

	cmd := startHelperLockProcess(t, lockFile, readyFile, 350*time.Millisecond)
	waitForFile(t, readyFile, 2*time.Second)

	locker := testLocker(commonDir)
	start := time.Now()
	err := locker.WithLock("merge", 2*time.Second, func() error { return nil })
	elapsed := time.Since(start)
	if err != nil {
		t.Fatalf("with lock failed: %v", err)
	}
	if elapsed < 250*time.Millisecond {
		t.Fatalf("expected second lock to block, elapsed=%s", elapsed)
	}

	if err := cmd.Wait(); err != nil {
		t.Fatalf("helper process failed: %v", err)
	}
}

func TestWithLock_Timeout(t *testing.T) {
	commonDir := t.TempDir()
	lockFile := filepath.Join(commonDir, "orca-global.lock")
	readyFile := filepath.Join(commonDir, "ready")

	cmd := startHelperLockProcess(t, lockFile, readyFile, 800*time.Millisecond)
	waitForFile(t, readyFile, 2*time.Second)

	locker := testLocker(commonDir)
	err := locker.WithLock("merge", 100*time.Millisecond, func() error { return nil })
	if err == nil {
		t.Fatal("expected timeout error, got nil")
	}
	if !errors.Is(err, ErrLockTimeout) {
		t.Fatalf("expected ErrLockTimeout, got %v", err)
	}

	if err := cmd.Wait(); err != nil {
		t.Fatalf("helper process failed: %v", err)
	}
}

func TestWithLock_ScopeDeterminesLockPath(t *testing.T) {
	commonDir := t.TempDir()
	locker := testLocker(commonDir)

	if err := locker.WithLock("merge", time.Second, func() error { return nil }); err != nil {
		t.Fatalf("merge scope lock failed: %v", err)
	}
	if err := locker.WithLock("queue", time.Second, func() error { return nil }); err != nil {
		t.Fatalf("queue scope lock failed: %v", err)
	}

	if _, err := os.Stat(filepath.Join(commonDir, "orca-global.lock")); err != nil {
		t.Fatalf("expected merge lock file: %v", err)
	}
	if _, err := os.Stat(filepath.Join(commonDir, "orca-global-queue.lock")); err != nil {
		t.Fatalf("expected queue lock file: %v", err)
	}
}

func TestWithLock_ValidationAndCallbackError(t *testing.T) {
	commonDir := t.TempDir()
	locker := testLocker(commonDir)

	if err := locker.WithLock("bad scope", time.Second, func() error { return nil }); err == nil {
		t.Fatal("expected invalid scope error")
	}

	if err := locker.WithLock("merge", time.Second, nil); err == nil {
		t.Fatal("expected nil callback error")
	}

	want := errors.New("fn failed")
	err := locker.WithLock("merge", time.Second, func() error { return want })
	if !errors.Is(err, want) {
		t.Fatalf("callback error should be returned unchanged, got: %v", err)
	}
}

func TestHelperProcessHoldLock(t *testing.T) {
	if os.Getenv("GO_WANT_LOCK_HELPER") != "1" {
		return
	}

	lockFile := os.Getenv("LOCK_FILE")
	readyFile := os.Getenv("LOCK_READY_FILE")
	hold := os.Getenv("LOCK_HOLD_MS")
	if lockFile == "" || readyFile == "" || hold == "" {
		fmt.Fprintln(os.Stderr, "missing helper env")
		os.Exit(2)
	}

	dur, err := time.ParseDuration(hold + "ms")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}

	file, err := os.OpenFile(lockFile, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	defer file.Close()

	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	defer func() { _ = syscall.Flock(int(file.Fd()), syscall.LOCK_UN) }()

	if err := os.WriteFile(readyFile, []byte("ready"), 0o644); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}

	time.Sleep(dur)
	os.Exit(0)
}

func testLocker(commonDir string) *FileLocker {
	l := NewFileLocker(".")
	l.resolveCommonDir = func(string) (string, error) { return commonDir, nil }
	return l
}

func startHelperLockProcess(t *testing.T, lockFile, readyFile string, hold time.Duration) *exec.Cmd {
	t.Helper()
	cmd := exec.Command(os.Args[0], "-test.run=TestHelperProcessHoldLock")
	cmd.Env = append(os.Environ(),
		"GO_WANT_LOCK_HELPER=1",
		"LOCK_FILE="+lockFile,
		"LOCK_READY_FILE="+readyFile,
		fmt.Sprintf("LOCK_HOLD_MS=%d", hold.Milliseconds()),
	)
	if err := cmd.Start(); err != nil {
		t.Fatalf("start helper process: %v", err)
	}
	return cmd
}

func waitForFile(t *testing.T, path string, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for {
		if _, err := os.Stat(path); err == nil {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("timeout waiting for file: %s", path)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestGitCommonDir(t *testing.T) {
	repo := t.TempDir()

	if out, err := exec.Command("git", "init", repo).CombinedOutput(); err != nil {
		t.Fatalf("git init: %v (%s)", err, strings.TrimSpace(string(out)))
	}

	got, err := gitCommonDir(repo)
	if err != nil {
		t.Fatalf("git common dir: %v", err)
	}
	if !filepath.IsAbs(got) {
		t.Fatalf("expected absolute path, got %q", got)
	}
	if _, err := os.Stat(got); err != nil {
		t.Fatalf("common dir should exist: %v", err)
	}
}
