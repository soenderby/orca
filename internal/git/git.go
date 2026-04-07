// Package git provides the repository operations needed by orca.
package git

import (
	"errors"
	"fmt"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

// WorktreeInfo describes one entry from git worktree list.
type WorktreeInfo struct {
	Path     string
	Head     string
	Branch   string
	Detached bool
	Bare     bool
	Locked   bool
	Prunable bool
}

// RepoRoot returns the absolute path to the repository root.
func RepoRoot(path string) (string, error) {
	out, err := runGit(path, "rev-parse", "--show-toplevel")
	if err != nil {
		return "", fmt.Errorf("git repo root: %w", err)
	}
	return out, nil
}

// CommonDir returns the absolute path to the git common dir.
func CommonDir(path string) (string, error) {
	out, err := runGit(path, "rev-parse", "--git-common-dir")
	if err != nil {
		return "", fmt.Errorf("git common dir: %w", err)
	}
	if filepath.IsAbs(out) {
		return out, nil
	}
	return filepath.Abs(filepath.Join(path, out))
}

// CurrentBranch returns the checked-out branch name.
func CurrentBranch(path string) (string, error) {
	out, err := runGit(path, "branch", "--show-current")
	if err != nil {
		return "", fmt.Errorf("git current branch: %w", err)
	}
	return out, nil
}

// IsClean returns true when git status --porcelain is empty.
func IsClean(path string) (bool, error) {
	out, err := runGit(path, "status", "--porcelain")
	if err != nil {
		return false, fmt.Errorf("git status porcelain: %w", err)
	}
	return strings.TrimSpace(out) == "", nil
}

// HasBeadsChanges returns true if .beads differs between base and HEAD.
func HasBeadsChanges(path, base string) (bool, error) {
	return HasBeadsChangesBetween(path, base, "HEAD")
}

// HasBeadsChangesBetween returns true if .beads differs between two refs.
func HasBeadsChangesBetween(path, leftRef, rightRef string) (bool, error) {
	if strings.TrimSpace(leftRef) == "" {
		return false, errors.New("left ref is required")
	}
	if strings.TrimSpace(rightRef) == "" {
		return false, errors.New("right ref is required")
	}
	out, err := runGit(path, "diff", "--name-only", leftRef+"..."+rightRef, "--", ".beads")
	if err != nil {
		return false, fmt.Errorf("git beads diff: %w", err)
	}
	return strings.TrimSpace(out) != "", nil
}

// FetchAndPull fetches from origin and ff-only pulls the current branch.
func FetchAndPull(path string) error {
	branch, err := CurrentBranch(path)
	if err != nil {
		return err
	}
	if branch == "" {
		return errors.New("cannot fetch/pull on detached head")
	}
	if _, err := runGit(path, "fetch", "origin", branch); err != nil {
		return fmt.Errorf("git fetch origin %s: %w", branch, err)
	}
	if _, err := runGit(path, "pull", "--ff-only", "origin", branch); err != nil {
		return fmt.Errorf("git pull --ff-only origin %s: %w", branch, err)
	}
	return nil
}

// CreateBranch creates or resets a branch from base and checks it out.
func CreateBranch(path, name, base string) error {
	if name == "" {
		return errors.New("branch name is required")
	}
	if base == "" {
		return errors.New("base ref is required")
	}
	if _, err := runGit(path, "checkout", "-B", name, base); err != nil {
		return fmt.Errorf("git checkout -B %s %s: %w", name, base, err)
	}
	return nil
}

// Merge merges source into the current branch with a merge commit.
func Merge(path, source string) error {
	if source == "" {
		return errors.New("merge source is required")
	}
	if _, err := runGit(path, "merge", "--no-ff", source); err != nil {
		return fmt.Errorf("git merge --no-ff %s: %w", source, err)
	}
	return nil
}

// MergeAbort aborts an in-progress merge.
func MergeAbort(path string) error {
	if _, err := runGit(path, "merge", "--abort"); err != nil {
		return fmt.Errorf("git merge --abort: %w", err)
	}
	return nil
}

// Push pushes the current branch to origin.
func Push(path string) error {
	branch, err := CurrentBranch(path)
	if err != nil {
		return err
	}
	if branch == "" {
		return errors.New("cannot push detached head")
	}
	if _, err := runGit(path, "push", "origin", branch); err != nil {
		return fmt.Errorf("git push origin %s: %w", branch, err)
	}
	return nil
}

// Worktrees lists configured worktrees.
func Worktrees(path string) ([]WorktreeInfo, error) {
	out, err := runGit(path, "worktree", "list", "--porcelain")
	if err != nil {
		return nil, fmt.Errorf("git worktree list: %w", err)
	}
	return parseWorktreePorcelain(out), nil
}

// AddWorktree adds a worktree at worktreePath.
//
// If branch does not exist, it is created from base.
func AddWorktree(path, worktreePath, branch, base string) error {
	if worktreePath == "" {
		return errors.New("worktree path is required")
	}
	if branch == "" {
		return errors.New("branch is required")
	}

	exists := false
	if _, err := runGit(path, "show-ref", "--verify", "--quiet", "refs/heads/"+branch); err == nil {
		exists = true
	}

	if exists {
		if _, err := runGit(path, "worktree", "add", worktreePath, branch); err != nil {
			return fmt.Errorf("git worktree add %s %s: %w", worktreePath, branch, err)
		}
		return nil
	}

	args := []string{"worktree", "add", "-b", branch, worktreePath}
	if base != "" {
		args = append(args, base)
	}
	if _, err := runGit(path, args...); err != nil {
		return fmt.Errorf("git worktree add -b %s %s %s: %w", branch, worktreePath, base, err)
	}
	return nil
}

// AheadBehind returns commits ahead/behind from local...remote.
func AheadBehind(path, local, remote string) (int, int, error) {
	if local == "" || remote == "" {
		return 0, 0, errors.New("local and remote refs are required")
	}
	out, err := runGit(path, "rev-list", "--left-right", "--count", local+"..."+remote)
	if err != nil {
		return 0, 0, fmt.Errorf("git rev-list ahead/behind: %w", err)
	}
	fields := strings.Fields(out)
	if len(fields) != 2 {
		return 0, 0, fmt.Errorf("unexpected ahead/behind output: %q", out)
	}
	ahead, err := strconv.Atoi(fields[0])
	if err != nil {
		return 0, 0, fmt.Errorf("parse ahead count: %w", err)
	}
	behind, err := strconv.Atoi(fields[1])
	if err != nil {
		return 0, 0, fmt.Errorf("parse behind count: %w", err)
	}
	return ahead, behind, nil
}

// Describe returns git describe --always --dirty output.
func Describe(path string) (string, error) {
	out, err := runGit(path, "describe", "--always", "--dirty")
	if err != nil {
		return "", fmt.Errorf("git describe: %w", err)
	}
	return out, nil
}

func runGit(dir string, args ...string) (string, error) {
	cmd := exec.Command("git", args...)
	if dir != "" {
		cmd.Dir = dir
	}
	out, err := cmd.CombinedOutput()
	trimmed := strings.TrimSpace(string(out))
	if err != nil {
		if trimmed == "" {
			return "", err
		}
		return "", fmt.Errorf("%w: %s", err, trimmed)
	}
	return trimmed, nil
}

func parseWorktreePorcelain(raw string) []WorktreeInfo {
	blocks := strings.Split(strings.TrimSpace(raw), "\n\n")
	items := make([]WorktreeInfo, 0, len(blocks))
	for _, block := range blocks {
		if strings.TrimSpace(block) == "" {
			continue
		}
		var info WorktreeInfo
		for _, line := range strings.Split(block, "\n") {
			line = strings.TrimSpace(line)
			switch {
			case strings.HasPrefix(line, "worktree "):
				info.Path = strings.TrimPrefix(line, "worktree ")
			case strings.HasPrefix(line, "HEAD "):
				info.Head = strings.TrimPrefix(line, "HEAD ")
			case strings.HasPrefix(line, "branch "):
				ref := strings.TrimPrefix(line, "branch ")
				info.Branch = strings.TrimPrefix(ref, "refs/heads/")
			case line == "detached":
				info.Detached = true
			case line == "bare":
				info.Bare = true
			case strings.HasPrefix(line, "locked"):
				info.Locked = true
			case strings.HasPrefix(line, "prunable"):
				info.Prunable = true
			}
		}
		items = append(items, info)
	}
	return items
}
