// Package queue provides safe, lock-guarded queue read and mutation operations.
package queue

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	gitops "github.com/soenderby/orca/internal/git"
	"github.com/soenderby/orca/internal/lock"
)

// Issue is the subset of queue issue fields used by orca planning and routing.
type Issue struct {
	ID        string   `json:"id"`
	Title     string   `json:"title,omitempty"`
	Status    string   `json:"status,omitempty"`
	Priority  *int     `json:"priority,omitempty"`
	CreatedAt *string  `json:"created_at,omitempty"`
	Labels    []string `json:"labels,omitempty"`
}

// Dep is one queue dependency record.
type Dep struct {
	IssueID     string `json:"issue_id"`
	DependsOnID string `json:"depends_on_id"`
	Type        string `json:"type"`
}

// CreateOpts configures issue creation.
type CreateOpts struct {
	Title       string
	Description string
	Priority    *int
	Labels      []string
	Actor       string
}

// Config configures a queue client.
type Config struct {
	RepoPath string
	Locker   lock.Locker
	Scope    string
	Timeout  time.Duration
	BRBinary string

	// Testing/injection hooks.
	Git gitOperations
	Run commandRunner
}

// Client is a safe queue access facade.
type Client struct {
	repoPath string
	locker   lock.Locker
	scope    string
	timeout  time.Duration
	brBinary string

	git gitOperations
	run commandRunner
}

type gitOperations interface {
	CurrentBranch(path string) (string, error)
	IsClean(path string) (bool, error)
	FetchAndPull(path string) error
	Push(path string) error
}

type commandRunner func(dir, name string, args ...string) (stdout string, exitCode int, err error)

type defaultGitOps struct{}

func (defaultGitOps) CurrentBranch(path string) (string, error) { return gitops.CurrentBranch(path) }
func (defaultGitOps) IsClean(path string) (bool, error)         { return gitops.IsClean(path) }
func (defaultGitOps) FetchAndPull(path string) error            { return gitops.FetchAndPull(path) }
func (defaultGitOps) Push(path string) error                    { return gitops.Push(path) }

// New builds a queue client.
func New(cfg Config) (*Client, error) {
	if strings.TrimSpace(cfg.RepoPath) == "" {
		return nil, errors.New("queue repo path is required")
	}

	lockerImpl := cfg.Locker
	if lockerImpl == nil {
		lockerImpl = lock.NewFileLocker(cfg.RepoPath)
	}

	scope := cfg.Scope
	if scope == "" {
		scope = lock.DefaultScope
	}

	timeout := cfg.Timeout
	if timeout <= 0 {
		timeout = lock.DefaultTimeout
	}

	brBinary := cfg.BRBinary
	if brBinary == "" {
		brBinary = "br"
	}

	gitImpl := cfg.Git
	if gitImpl == nil {
		gitImpl = defaultGitOps{}
	}

	runner := cfg.Run
	if runner == nil {
		runner = defaultRunner
	}

	return &Client{
		repoPath: cfg.RepoPath,
		locker:   lockerImpl,
		scope:    scope,
		timeout:  timeout,
		brBinary: brBinary,
		git:      gitImpl,
		run:      runner,
	}, nil
}

// ReadReady returns ready issues from primary repo main under lock.
func (c *Client) ReadReady() ([]Issue, error) {
	output, err := c.read(func() (string, error) {
		return c.runBR("ready", "--json")
	})
	if err != nil {
		return nil, err
	}

	var issues []Issue
	if err := json.Unmarshal([]byte(output), &issues); err != nil {
		return nil, fmt.Errorf("parse br ready json: %w", err)
	}
	return issues, nil
}

// Show returns one issue by ID.
func (c *Client) Show(issueID string) (*Issue, error) {
	if strings.TrimSpace(issueID) == "" {
		return nil, errors.New("issue id is required")
	}

	output, err := c.read(func() (string, error) {
		return c.runBR("show", issueID, "--json")
	})
	if err != nil {
		return nil, err
	}

	issue, err := parseSingleIssue(output)
	if err != nil {
		return nil, err
	}
	return issue, nil
}

// Claim claims an issue as actor.
func (c *Client) Claim(issueID, actor string) error {
	if strings.TrimSpace(issueID) == "" {
		return errors.New("issue id is required")
	}
	if strings.TrimSpace(actor) == "" {
		return errors.New("actor is required")
	}

	_, err := c.mutate(
		fmt.Sprintf("queue: claim %s by %s", issueID, actor),
		[]string{"update", issueID, "--claim", "--actor", actor, "--json"},
	)
	return err
}

// Comment posts a comment with safe file payload routing.
func (c *Client) Comment(issueID, actor, comment string) error {
	if strings.TrimSpace(issueID) == "" {
		return errors.New("issue id is required")
	}
	if strings.TrimSpace(actor) == "" {
		return errors.New("actor is required")
	}
	if strings.TrimSpace(comment) == "" {
		return errors.New("comment payload is required")
	}

	tmp, err := os.CreateTemp("", "orca-queue-comment-*.md")
	if err != nil {
		return fmt.Errorf("create temp comment file: %w", err)
	}
	path := tmp.Name()
	defer os.Remove(path)
	defer tmp.Close()

	if _, err := tmp.WriteString(comment); err != nil {
		return fmt.Errorf("write comment payload: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("close comment payload file: %w", err)
	}

	_, err = c.mutate(
		fmt.Sprintf("queue: comment %s by %s", issueID, actor),
		[]string{"comments", "add", issueID, "--file", path, "--author", actor, "--actor", actor, "--json"},
	)
	return err
}

// Close closes an issue as actor.
func (c *Client) Close(issueID, actor string) error {
	if strings.TrimSpace(issueID) == "" {
		return errors.New("issue id is required")
	}
	if strings.TrimSpace(actor) == "" {
		return errors.New("actor is required")
	}

	_, err := c.mutate(
		fmt.Sprintf("queue: close %s by %s", issueID, actor),
		[]string{"close", issueID, "--actor", actor, "--json"},
	)
	return err
}

// Create creates a new issue and returns its ID.
func (c *Client) Create(opts CreateOpts) (string, error) {
	if strings.TrimSpace(opts.Title) == "" {
		return "", errors.New("title is required")
	}
	if strings.TrimSpace(opts.Actor) == "" {
		return "", errors.New("actor is required")
	}

	args := []string{"create", opts.Title}
	if strings.TrimSpace(opts.Description) != "" {
		args = append(args, "--description", opts.Description)
	}
	if opts.Priority != nil {
		args = append(args, "--priority", strconv.Itoa(*opts.Priority))
	}
	for _, label := range opts.Labels {
		if strings.TrimSpace(label) == "" {
			continue
		}
		args = append(args, "--label", label)
	}
	args = append(args, "--actor", opts.Actor, "--json")

	output, err := c.mutate(fmt.Sprintf("queue: create by %s", opts.Actor), args)
	if err != nil {
		return "", err
	}

	id, err := parseCreatedIssueID(output)
	if err != nil {
		return "", err
	}
	return id, nil
}

// DepAdd adds a dependency between two issues.
func (c *Client) DepAdd(fromID, toID, depType, actor string) error {
	if strings.TrimSpace(fromID) == "" {
		return errors.New("from issue id is required")
	}
	if strings.TrimSpace(toID) == "" {
		return errors.New("to issue id is required")
	}
	if strings.TrimSpace(actor) == "" {
		return errors.New("actor is required")
	}
	if strings.TrimSpace(depType) == "" {
		depType = "blocks"
	}

	_, err := c.mutate(
		fmt.Sprintf("queue: dep-add %s -> %s by %s", fromID, toID, actor),
		[]string{"dep", "add", fromID, toID, "--type", depType, "--actor", actor, "--json"},
	)
	return err
}

// DepList lists dependencies for an issue.
func (c *Client) DepList(issueID string) ([]Dep, error) {
	if strings.TrimSpace(issueID) == "" {
		return nil, errors.New("issue id is required")
	}

	output, err := c.read(func() (string, error) {
		return c.runBR("dep", "list", issueID, "--json")
	})
	if err != nil {
		return nil, err
	}

	var deps []Dep
	if err := json.Unmarshal([]byte(output), &deps); err != nil {
		return nil, fmt.Errorf("parse br dep list json: %w", err)
	}
	return deps, nil
}

// Sync performs a lock-guarded queue sync transaction.
func (c *Client) Sync() error {
	_, err := c.mutate("queue: sync", []string{"sync"})
	return err
}

func (c *Client) read(fn func() (string, error)) (string, error) {
	var output string
	err := c.locker.WithLock(c.scope, c.timeout, func() error {
		if err := c.ensureOnMain(); err != nil {
			return err
		}
		if err := c.git.FetchAndPull(c.repoPath); err != nil {
			return fmt.Errorf("fetch and pull primary repo: %w", err)
		}
		if _, err := c.runBR("sync", "--import-only"); err != nil {
			return fmt.Errorf("queue import sync: %w", err)
		}

		out, err := fn()
		if err != nil {
			return err
		}
		output = out
		return nil
	})
	if err != nil {
		return "", err
	}
	return output, nil
}

func (c *Client) mutate(commitMessage string, brArgs []string) (string, error) {
	if strings.TrimSpace(commitMessage) == "" {
		return "", errors.New("commit message is required")
	}
	if len(brArgs) == 0 {
		return "", errors.New("mutation command is required")
	}

	var output string
	err := c.locker.WithLock(c.scope, c.timeout, func() error {
		if err := c.ensureOnMain(); err != nil {
			return err
		}
		clean, err := c.git.IsClean(c.repoPath)
		if err != nil {
			return fmt.Errorf("check primary repo cleanliness: %w", err)
		}
		if !clean {
			return errors.New("primary repo has uncommitted changes")
		}

		if err := c.git.FetchAndPull(c.repoPath); err != nil {
			return fmt.Errorf("fetch and pull primary repo: %w", err)
		}
		if _, err := c.runBR("sync", "--import-only"); err != nil {
			return fmt.Errorf("queue import sync: %w", err)
		}

		out, err := c.runBR(brArgs...)
		if err != nil {
			return err
		}
		output = out

		if _, err := c.runBR("sync", "--flush-only"); err != nil {
			return fmt.Errorf("queue flush sync: %w", err)
		}

		if err := c.stageAndCommit(commitMessage); err != nil {
			return err
		}
		return nil
	})
	if err != nil {
		return "", err
	}

	return output, nil
}

func (c *Client) ensureOnMain() error {
	branch, err := c.git.CurrentBranch(c.repoPath)
	if err != nil {
		return fmt.Errorf("resolve primary branch: %w", err)
	}
	if branch != "main" {
		return fmt.Errorf("expected primary repo on main, found %q", branch)
	}
	return nil
}

func (c *Client) stageAndCommit(message string) error {
	if _, _, err := c.run(c.repoPath, "git", "add", ".beads/"); err != nil {
		return fmt.Errorf("stage .beads changes: %w", err)
	}

	hasChanges, err := c.hasStagedChanges()
	if err != nil {
		return err
	}
	if !hasChanges {
		return nil
	}

	if _, _, err := c.run(c.repoPath, "git", "commit", "-m", message); err != nil {
		return fmt.Errorf("commit .beads changes: %w", err)
	}
	if err := c.git.Push(c.repoPath); err != nil {
		return fmt.Errorf("push primary repo main: %w", err)
	}
	return nil
}

func (c *Client) hasStagedChanges() (bool, error) {
	_, code, err := c.run(c.repoPath, "git", "diff", "--cached", "--quiet")
	if err == nil {
		return false, nil
	}
	if code == 1 {
		return true, nil
	}
	return false, fmt.Errorf("check staged changes: %w", err)
}

func (c *Client) runBR(args ...string) (string, error) {
	out, _, err := c.run(c.repoPath, c.brBinary, args...)
	if err != nil {
		return "", fmt.Errorf("run %s %s: %w", c.brBinary, strings.Join(args, " "), err)
	}
	return out, nil
}

func defaultRunner(dir, name string, args ...string) (string, int, error) {
	cmd := exec.Command(name, args...)
	if dir != "" {
		cmd.Dir = dir
	}
	out, err := cmd.CombinedOutput()
	trimmed := strings.TrimSpace(string(out))
	if err == nil {
		return trimmed, 0, nil
	}

	exitCode := 1
	if ee, ok := err.(*exec.ExitError); ok {
		exitCode = ee.ExitCode()
	}

	if trimmed == "" {
		return "", exitCode, err
	}
	return "", exitCode, fmt.Errorf("%w: %s", err, trimmed)
}

func parseSingleIssue(raw string) (*Issue, error) {
	var issue Issue
	if err := json.Unmarshal([]byte(raw), &issue); err == nil {
		if issue.ID != "" {
			return &issue, nil
		}
	}

	var list []Issue
	if err := json.Unmarshal([]byte(raw), &list); err == nil {
		if len(list) > 0 {
			return &list[0], nil
		}
	}

	return nil, errors.New("unable to parse issue json")
}

func parseCreatedIssueID(raw string) (string, error) {
	issue, err := parseSingleIssue(raw)
	if err == nil && issue.ID != "" {
		return issue.ID, nil
	}

	var obj map[string]any
	if err := json.Unmarshal([]byte(raw), &obj); err == nil {
		if id, ok := obj["id"].(string); ok && strings.TrimSpace(id) != "" {
			return id, nil
		}
	}

	return "", errors.New("create response did not include issue id")
}
