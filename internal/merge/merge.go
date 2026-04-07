// Package merge provides lock-guarded merge-to-main operations.
package merge

import (
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"time"

	gitops "github.com/soenderby/orca/internal/git"
	"github.com/soenderby/orca/internal/lock"
)

// MergeConfig configures MergeToMain.
type MergeConfig struct {
	PrimaryRepo string
	Source      string
	Locker      lock.Locker
	LockScope   string
	LockTimeout time.Duration
}

// MergeToMain merges Source into PrimaryRepo/main under a shared writer lock.
func MergeToMain(cfg MergeConfig) error {
	if strings.TrimSpace(cfg.PrimaryRepo) == "" {
		return errors.New("primary repo is required")
	}
	if strings.TrimSpace(cfg.Source) == "" {
		return errors.New("merge source branch is required")
	}

	lockerImpl := cfg.Locker
	if lockerImpl == nil {
		lockerImpl = lock.NewFileLocker(cfg.PrimaryRepo)
	}

	scope := cfg.LockScope
	if scope == "" {
		scope = lock.DefaultScope
	}
	lockTimeout := cfg.LockTimeout
	if lockTimeout <= 0 {
		lockTimeout = lock.DefaultTimeout
	}

	return lockerImpl.WithLock(scope, lockTimeout, func() error {
		branch, err := gitops.CurrentBranch(cfg.PrimaryRepo)
		if err != nil {
			return fmt.Errorf("resolve primary branch: %w", err)
		}
		if branch != "main" {
			return fmt.Errorf("expected primary repo on main, found %q", branch)
		}

		clean, err := gitops.IsClean(cfg.PrimaryRepo)
		if err != nil {
			return fmt.Errorf("check primary repo cleanliness: %w", err)
		}
		if !clean {
			return errors.New("primary repo has uncommitted changes")
		}

		if err := gitops.FetchAndPull(cfg.PrimaryRepo); err != nil {
			return fmt.Errorf("fetch and pull primary repo main: %w", err)
		}

		beadsChanged, err := gitops.HasBeadsChangesBetween(cfg.PrimaryRepo, "main", cfg.Source)
		if err != nil {
			return fmt.Errorf("check source branch .beads changes: %w", err)
		}
		if beadsChanged {
			return errors.New("source branch carries .beads changes; queue writes must go through queue helpers on main")
		}

		if err := gitops.Merge(cfg.PrimaryRepo, cfg.Source); err != nil {
			cleanupErr := cleanupAfterFailedMerge(cfg.PrimaryRepo)
			if cleanupErr != nil {
				return fmt.Errorf("merge source branch %q into main: %v; cleanup failed: %w", cfg.Source, err, cleanupErr)
			}
			return fmt.Errorf("merge source branch %q into main: %w", cfg.Source, err)
		}

		if err := gitops.Push(cfg.PrimaryRepo); err != nil {
			return fmt.Errorf("push main: %w", err)
		}

		return nil
	})
}

func cleanupAfterFailedMerge(repo string) error {
	var errs []string

	if err := gitops.MergeAbort(repo); err != nil {
		errs = append(errs, fmt.Sprintf("merge abort: %v", err))
	}

	if err := resetHard(repo); err != nil {
		errs = append(errs, fmt.Sprintf("reset --hard: %v", err))
	}

	if len(errs) == 0 {
		return nil
	}
	return errors.New(strings.Join(errs, "; "))
}

func resetHard(repo string) error {
	cmd := exec.Command("git", "reset", "--hard", "HEAD")
	cmd.Dir = repo
	out, err := cmd.CombinedOutput()
	if err != nil {
		trimmed := strings.TrimSpace(string(out))
		if trimmed == "" {
			return err
		}
		return fmt.Errorf("%w: %s", err, trimmed)
	}
	return nil
}
