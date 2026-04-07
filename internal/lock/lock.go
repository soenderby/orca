// Package lock provides scoped file locking for serialized repository writes.
package lock

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"
)

const (
	DefaultScope   = "merge"
	DefaultTimeout = 120 * time.Second
)

var (
	// ErrLockTimeout indicates lock acquisition timed out.
	ErrLockTimeout = errors.New("lock timeout")

	scopePattern = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)
)

// Locker executes a function while holding a scoped lock.
type Locker interface {
	WithLock(scope string, timeout time.Duration, fn func() error) error
}

// FileLocker acquires process-level file locks rooted in a git common dir.
type FileLocker struct {
	repoPath         string
	resolveCommonDir func(string) (string, error)
	now              func() time.Time
	sleep            func(time.Duration)
}

// NewFileLocker returns a locker for repoPath.
func NewFileLocker(repoPath string) *FileLocker {
	if repoPath == "" {
		repoPath = "."
	}
	return &FileLocker{
		repoPath:         repoPath,
		resolveCommonDir: gitCommonDir,
		now:              time.Now,
		sleep:            time.Sleep,
	}
}

// WithLock acquires a scoped lock, runs fn, and releases the lock.
func (l *FileLocker) WithLock(scope string, timeout time.Duration, fn func() error) error {
	if fn == nil {
		return errors.New("lock callback is required")
	}
	if scope == "" {
		scope = DefaultScope
	}
	if !scopePattern.MatchString(scope) {
		return fmt.Errorf("invalid lock scope %q", scope)
	}
	if timeout <= 0 {
		timeout = DefaultTimeout
	}

	commonDir, err := l.resolveCommonDir(l.repoPath)
	if err != nil {
		return fmt.Errorf("resolve git common dir: %w", err)
	}

	lockFile := lockFilePath(commonDir, scope)
	file, err := os.OpenFile(lockFile, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return fmt.Errorf("open lock file %q: %w", lockFile, err)
	}
	defer file.Close()

	if err := l.acquire(file, scope, timeout, lockFile); err != nil {
		return err
	}
	defer func() {
		_ = syscall.Flock(int(file.Fd()), syscall.LOCK_UN)
	}()

	if err := fn(); err != nil {
		return err
	}
	return nil
}

func (l *FileLocker) acquire(file *os.File, scope string, timeout time.Duration, lockFile string) error {
	deadline := l.now().Add(timeout)
	for {
		err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			return nil
		}
		if !errors.Is(err, syscall.EWOULDBLOCK) && !errors.Is(err, syscall.EAGAIN) {
			return fmt.Errorf("acquire %q lock: %w", scope, err)
		}
		if !l.now().Before(deadline) {
			return fmt.Errorf("%w waiting for %q after %s (%s)", ErrLockTimeout, scope, timeout.String(), lockFile)
		}
		l.sleep(10 * time.Millisecond)
	}
}

func lockFilePath(commonDir, scope string) string {
	if scope == DefaultScope {
		return filepath.Join(commonDir, "orca-global.lock")
	}
	return filepath.Join(commonDir, "orca-global-"+scope+".lock")
}

func gitCommonDir(repoPath string) (string, error) {
	cmd := exec.Command("git", "rev-parse", "--git-common-dir")
	cmd.Dir = repoPath
	output, err := cmd.Output()
	if err != nil {
		return "", err
	}

	raw := strings.TrimSpace(string(output))
	if raw == "" {
		return "", errors.New("empty git common dir")
	}

	path := raw
	if !filepath.IsAbs(path) {
		path = filepath.Join(repoPath, path)
	}

	abs, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	return abs, nil
}
