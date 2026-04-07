// Package worktree manages orca agent worktree setup.
package worktree

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	gitops "github.com/soenderby/orca/internal/git"
)

// SetupConfig configures agent worktree creation.
type SetupConfig struct {
	RepoPath         string
	Count            int
	BaseRefOverride  string
	AgentNamePattern string // default: agent-%d
	BranchPattern    string // default: swarm/agent-%d
}

// SetupResult summarizes setup-worktrees execution.
type SetupResult struct {
	BaseRef  string
	Created  []string
	Existing []string
	Warnings []string
}

// Setup creates or reuses worktrees/agent-N branches from a base ref.
func Setup(cfg SetupConfig) (*SetupResult, error) {
	if strings.TrimSpace(cfg.RepoPath) == "" {
		return nil, errors.New("repo path is required")
	}
	if cfg.Count <= 0 {
		return nil, fmt.Errorf("count must be a positive integer: %d", cfg.Count)
	}

	agentNamePattern := cfg.AgentNamePattern
	if agentNamePattern == "" {
		agentNamePattern = "agent-%d"
	}
	branchPattern := cfg.BranchPattern
	if branchPattern == "" {
		branchPattern = "swarm/agent-%d"
	}

	result := &SetupResult{}
	if err := os.MkdirAll(filepath.Join(cfg.RepoPath, "worktrees"), 0o755); err != nil {
		return nil, fmt.Errorf("create worktrees directory: %w", err)
	}

	baseRef, warnings, err := resolveBaseRef(cfg.RepoPath, cfg.BaseRefOverride)
	if err != nil {
		return nil, err
	}
	result.BaseRef = baseRef
	result.Warnings = append(result.Warnings, warnings...)

	originAvailable := remoteExists(cfg.RepoPath, "origin")
	if !originAvailable {
		result.Warnings = append(result.Warnings, "no origin remote configured; remote branch checks skipped")
	}

	for i := 1; i <= cfg.Count; i++ {
		name := fmt.Sprintf(agentNamePattern, i)
		relPath := filepath.Join("worktrees", name)
		absPath := filepath.Join(cfg.RepoPath, relPath)
		branch := fmt.Sprintf(branchPattern, i)

		worktrees, err := gitops.Worktrees(cfg.RepoPath)
		if err != nil {
			return nil, fmt.Errorf("list worktrees: %w", err)
		}
		if pathInWorktrees(absPath, worktrees) {
			result.Existing = append(result.Existing, relPath)
			continue
		}

		if originAvailable && remoteHeadExists(cfg.RepoPath, "origin", branch) {
			result.Warnings = append(result.Warnings,
				fmt.Sprintf("remote branch origin/%s exists but is ignored (agent branches are local transport state)", branch),
			)
		}

		branchExists, err := localBranchExists(cfg.RepoPath, branch)
		if err != nil {
			return nil, fmt.Errorf("check local branch %q: %w", branch, err)
		}

		if branchExists {
			if branchInWorktrees(branch, worktrees) {
				return nil, fmt.Errorf("branch %s is already checked out in another worktree", branch)
			}
			if err := forceBranchToBase(cfg.RepoPath, branch, baseRef); err != nil {
				return nil, err
			}
			if err := gitops.AddWorktree(cfg.RepoPath, absPath, branch, ""); err != nil {
				return nil, fmt.Errorf("add worktree %s using existing branch %s: %w", relPath, branch, err)
			}
			result.Created = append(result.Created, relPath)
			continue
		}

		if err := gitops.AddWorktree(cfg.RepoPath, absPath, branch, baseRef); err != nil {
			return nil, fmt.Errorf("add worktree %s with new branch %s from %s: %w", relPath, branch, baseRef, err)
		}
		_ = unsetUpstream(absPath, branch)
		result.Created = append(result.Created, relPath)
	}

	return result, nil
}

func resolveBaseRef(repoPath, explicit string) (string, []string, error) {
	warnings := make([]string, 0)

	if strings.TrimSpace(explicit) != "" {
		exists, err := refExists(repoPath, explicit)
		if err != nil {
			return "", warnings, fmt.Errorf("resolve explicit base ref %q: %w", explicit, err)
		}
		if !exists {
			return "", warnings, fmt.Errorf("ORCA_BASE_REF does not resolve to a commit: %s", explicit)
		}
		return explicit, warnings, nil
	}

	diverged, ahead, behind, err := mainRefsDiverged(repoPath)
	if err == nil && diverged {
		warnings = append(warnings,
			fmt.Sprintf("local main and origin/main differ (local ahead %d, behind %d); defaulting to local main", ahead, behind),
		)
	}

	if ok, _ := refExists(repoPath, "main"); ok {
		return "main", warnings, nil
	}
	if ok, _ := refExists(repoPath, "origin/main"); ok {
		return "origin/main", warnings, nil
	}

	branch, err := gitops.CurrentBranch(repoPath)
	if err == nil && strings.TrimSpace(branch) != "" {
		return branch, warnings, nil
	}

	return "", warnings, errors.New("unable to determine a base ref for new worktrees")
}

func mainRefsDiverged(repoPath string) (diverged bool, ahead int, behind int, err error) {
	if ok, _ := refExists(repoPath, "main"); !ok {
		return false, 0, 0, nil
	}
	if ok, _ := refExists(repoPath, "origin/main"); !ok {
		return false, 0, 0, nil
	}
	ahead, behind, err = gitops.AheadBehind(repoPath, "main", "origin/main")
	if err != nil {
		return false, 0, 0, err
	}
	return ahead != 0 || behind != 0, ahead, behind, nil
}

func refExists(repoPath, ref string) (bool, error) {
	if strings.TrimSpace(ref) == "" {
		return false, errors.New("ref is required")
	}
	cmd := exec.Command("git", "rev-parse", "--verify", "--quiet", ref+"^{commit}")
	cmd.Dir = repoPath
	if err := cmd.Run(); err != nil {
		if ee, ok := err.(*exec.ExitError); ok && ee.ExitCode() == 1 {
			return false, nil
		}
		return false, err
	}
	return true, nil
}

func localBranchExists(repoPath, branch string) (bool, error) {
	cmd := exec.Command("git", "show-ref", "--verify", "--quiet", "refs/heads/"+branch)
	cmd.Dir = repoPath
	if err := cmd.Run(); err != nil {
		if ee, ok := err.(*exec.ExitError); ok && ee.ExitCode() == 1 {
			return false, nil
		}
		return false, err
	}
	return true, nil
}

func forceBranchToBase(repoPath, branch, baseRef string) error {
	cmd := exec.Command("git", "branch", "-f", branch, baseRef)
	cmd.Dir = repoPath
	if out, err := cmd.CombinedOutput(); err != nil {
		trimmed := strings.TrimSpace(string(out))
		if trimmed == "" {
			return fmt.Errorf("reset branch %s to %s: %w", branch, baseRef, err)
		}
		return fmt.Errorf("reset branch %s to %s: %w: %s", branch, baseRef, err, trimmed)
	}
	_ = unsetUpstream(repoPath, branch)
	return nil
}

func unsetUpstream(repoPath, branch string) error {
	cmd := exec.Command("git", "branch", "--unset-upstream", branch)
	cmd.Dir = repoPath
	_ = cmd.Run()
	return nil
}

func pathInWorktrees(path string, worktrees []gitops.WorktreeInfo) bool {
	abs, _ := filepath.Abs(path)
	for _, wt := range worktrees {
		wtAbs, _ := filepath.Abs(wt.Path)
		if wtAbs == abs {
			return true
		}
	}
	return false
}

func branchInWorktrees(branch string, worktrees []gitops.WorktreeInfo) bool {
	for _, wt := range worktrees {
		if wt.Branch == branch {
			return true
		}
	}
	return false
}

func remoteExists(repoPath, remote string) bool {
	cmd := exec.Command("git", "remote", "get-url", remote)
	cmd.Dir = repoPath
	return cmd.Run() == nil
}

func remoteHeadExists(repoPath, remote, branch string) bool {
	cmd := exec.Command("git", "ls-remote", "--exit-code", "--heads", remote, branch)
	cmd.Dir = repoPath
	return cmd.Run() == nil
}
