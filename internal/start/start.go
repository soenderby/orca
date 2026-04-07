// Package start orchestrates session launch planning and tmux startup.
package start

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/soenderby/orca/internal/depsanity"
	gitops "github.com/soenderby/orca/internal/git"
	"github.com/soenderby/orca/internal/model"
	"github.com/soenderby/orca/internal/plan"
	"github.com/soenderby/orca/internal/prompt"
	"github.com/soenderby/orca/internal/queue"
	"github.com/soenderby/orca/internal/tmux"
	"github.com/soenderby/orca/internal/worktree"
)

// Config configures the start orchestration.
type Config struct {
	RepoPath               string
	Count                  int
	SessionPrefix          string
	AssignmentMode         string // assigned | self-select
	MaxRuns                int
	ForceCount             bool
	DepSanityMode          string // enforce | warn | off
	PromptTemplatePath     string
	AgentCommand           string
	NoWorkDrainMode        string
	NoWorkRetryLimit       int
	RunSleepSeconds        int
	ModeID                 string
	ApproachFile           string
	LockScope              string
	LockTimeout            time.Duration
	BaseRefOverride        string
	QueueReadFallback      string
	QueueReadWorktree      string
	SkipWorktreeValidation bool
	OrcaHome               string
	OrcaBin                string
	WithLockPath           string
	QueueReadMainPath      string
	QueueWriteMainPath     string
	MergeMainPath          string
	BrGuardPath            string

	Stdout io.Writer
	Stderr io.Writer
	Now    func() time.Time

	Tmux  TmuxClient
	Queue QueueReader

	SetupWorktrees func(cfg worktree.SetupConfig) (*worktree.SetupResult, error)
}

// Result summarizes launch planning and launch execution.
type Result struct {
	ReadyCount       int
	RunningSessions  int
	LaunchCandidates int
	LaunchLimit      int
	LaunchedCount    int
	AssignedCount    int
	HeldCount        int
	PlanPath         string
	DepSanityPath    string
}

// TmuxClient is the tmux dependency needed by start orchestration.
type TmuxClient interface {
	HasSession(name string) (bool, error)
	NewSession(name, command string) error
	ListSessions() ([]tmux.SessionInfo, error)
}

// QueueReader is the queue dependency needed by start orchestration.
type QueueReader interface {
	ReadReady() ([]queue.Issue, error)
}

// Run executes start orchestration and launches sessions.
func Run(cfg Config) (*Result, error) {
	now := cfg.Now
	if now == nil {
		now = time.Now
	}
	out := cfg.Stdout
	if out == nil {
		out = os.Stdout
	}
	errOut := cfg.Stderr
	if errOut == nil {
		errOut = os.Stderr
	}

	if cfg.Count <= 0 {
		return nil, fmt.Errorf("count must be a positive integer: %d", cfg.Count)
	}
	if cfg.SessionPrefix == "" {
		cfg.SessionPrefix = "orca-agent"
	}
	if cfg.AssignmentMode == "" {
		cfg.AssignmentMode = "assigned"
	}
	if cfg.AssignmentMode != "assigned" && cfg.AssignmentMode != "self-select" {
		return nil, fmt.Errorf("ORCA_ASSIGNMENT_MODE must be 'assigned' or 'self-select': %s", cfg.AssignmentMode)
	}
	if cfg.RunSleepSeconds < 0 {
		return nil, fmt.Errorf("RUN_SLEEP_SECONDS must be a non-negative integer: %d", cfg.RunSleepSeconds)
	}
	if cfg.RunSleepSeconds == 0 {
		cfg.RunSleepSeconds = 2
	}
	if cfg.AssignmentMode == "assigned" && cfg.MaxRuns == 0 {
		return nil, errors.New("--continuous is not supported when ORCA_ASSIGNMENT_MODE=assigned")
	}
	if cfg.DepSanityMode == "" {
		cfg.DepSanityMode = "enforce"
	}
	if cfg.DepSanityMode != "enforce" && cfg.DepSanityMode != "warn" && cfg.DepSanityMode != "off" {
		return nil, fmt.Errorf("ORCA_DEP_SANITY_MODE must be 'enforce', 'warn', or 'off': %s", cfg.DepSanityMode)
	}
	if cfg.PromptTemplatePath == "" {
		cfg.PromptTemplatePath = filepath.Join(cfg.RepoPath, "ORCA_PROMPT.md")
	}
	if strings.TrimSpace(cfg.RepoPath) == "" {
		root, err := gitops.RepoRoot(".")
		if err != nil {
			return nil, fmt.Errorf("resolve repo root: %w", err)
		}
		cfg.RepoPath = root
	}
	if cfg.QueueReadWorktree == "" {
		cfg.QueueReadWorktree = cfg.RepoPath
	}
	if cfg.QueueReadFallback == "" {
		cfg.QueueReadFallback = "error"
	}
	if strings.TrimSpace(cfg.OrcaHome) == "" {
		cfg.OrcaHome = cfg.RepoPath
	}
	if strings.TrimSpace(cfg.OrcaBin) == "" {
		cfg.OrcaBin = filepath.Join(cfg.OrcaHome, "orca-go")
	}
	if strings.TrimSpace(cfg.WithLockPath) == "" {
		cfg.WithLockPath = filepath.Join(cfg.OrcaHome, "with-lock.sh")
	}
	if strings.TrimSpace(cfg.QueueReadMainPath) == "" {
		cfg.QueueReadMainPath = filepath.Join(cfg.OrcaHome, "queue-read-main.sh")
	}
	if strings.TrimSpace(cfg.QueueWriteMainPath) == "" {
		cfg.QueueWriteMainPath = filepath.Join(cfg.OrcaHome, "queue-write-main.sh")
	}
	if strings.TrimSpace(cfg.MergeMainPath) == "" {
		cfg.MergeMainPath = filepath.Join(cfg.OrcaHome, "merge-main.sh")
	}
	if strings.TrimSpace(cfg.BrGuardPath) == "" {
		cfg.BrGuardPath = filepath.Join(cfg.OrcaHome, "br-guard.sh")
	}

	promptText, err := os.ReadFile(cfg.PromptTemplatePath)
	if err != nil {
		return nil, fmt.Errorf("missing prompt template: %w", err)
	}
	if err := prompt.ValidateTemplate(string(promptText)); err != nil {
		return nil, fmt.Errorf("prompt template validation failed: %w", err)
	}

	tmuxClient := cfg.Tmux
	if tmuxClient == nil {
		tmuxClient = defaultTmuxClient{}
	}

	queueClient := cfg.Queue
	if queueClient == nil {
		qc, err := queue.New(queue.Config{
			RepoPath: cfg.RepoPath,
			Scope:    cfg.LockScope,
			Timeout:  cfg.LockTimeout,
		})
		if err != nil {
			return nil, fmt.Errorf("initialize queue client: %w", err)
		}
		queueClient = qc
	}

	setup := cfg.SetupWorktrees
	if setup == nil {
		setup = worktree.Setup
	}

	if _, err := setup(worktree.SetupConfig{
		RepoPath:        cfg.RepoPath,
		Count:           cfg.Count,
		BaseRefOverride: cfg.BaseRefOverride,
	}); err != nil {
		return nil, fmt.Errorf("setup worktrees: %w", err)
	}

	if !cfg.SkipWorktreeValidation {
		if err := validateWorktrees(cfg, tmuxClient); err != nil {
			return nil, err
		}
	}

	result := &Result{}
	if err := runDepSanity(cfg, now, out, errOut, result); err != nil {
		return nil, err
	}

	running, launchable, err := sessionAvailability(cfg, tmuxClient)
	if err != nil {
		return nil, err
	}
	result.RunningSessions = running
	result.LaunchCandidates = launchable

	readyIssues, err := queueClient.ReadReady()
	if err != nil {
		return nil, fmt.Errorf("failed to query ready issues via queue reader: %w", err)
	}
	result.ReadyCount = len(readyIssues)

	launchLimit := launchLimit(cfg, len(readyIssues), launchable)
	result.LaunchLimit = launchLimit

	fmt.Fprintf(out,
		"[start] launch planning: requested=%d running=%d ready=%d launchable=%d launching=%d force_count=%d assignment_mode=%s\n",
		cfg.Count,
		running,
		len(readyIssues),
		launchable,
		launchLimit,
		boolToInt(cfg.ForceCount),
		cfg.AssignmentMode,
	)

	assignedIDs := make([]string, 0)
	if cfg.AssignmentMode == "assigned" && launchLimit > 0 {
		planPath, planOut, err := buildPlan(cfg, now, readyIssues, launchLimit)
		if err != nil {
			return nil, err
		}
		result.PlanPath = planPath
		result.AssignedCount = len(planOut.Assignments)
		result.HeldCount = len(planOut.Held)
		assignedIDs = extractAssignedIDs(planOut)

		fmt.Fprintf(out,
			"[start] assignment plan: artifact=%s requested_slots=%d assigned=%d held=%d\n",
			planPath,
			launchLimit,
			len(planOut.Assignments),
			len(planOut.Held),
		)
		for _, item := range planOut.Assignments {
			priority := "null"
			if item.Priority != nil {
				priority = strconv.Itoa(*item.Priority)
			}
			fmt.Fprintf(out, "[start] assignment plan: slot=%d issue=%s priority=%s\n", item.Slot, item.IssueID, priority)
		}
		for _, held := range planOut.Held {
			line := fmt.Sprintf("[start] assignment held: issue=%s reason=%s", held.IssueID, held.ReasonCode)
			if held.ConflictKey != nil {
				line += fmt.Sprintf(" conflict_key=%s", *held.ConflictKey)
			}
			fmt.Fprintln(out, line)
		}
		for _, decision := range planOut.Decisions {
			line := fmt.Sprintf("[start] assignment decision: issue=%s action=%s reason=%s", decision.IssueID, decision.Action, decision.ReasonCode)
			if decision.ConflictKey != nil {
				line += fmt.Sprintf(" conflict_key=%s", *decision.ConflictKey)
			}
			fmt.Fprintln(out, line)
		}
		if len(planOut.Assignments) < launchLimit {
			fmt.Fprintf(
				out,
				"[start] assignment plan: assigned fewer sessions than requested_slots=%d; held_reason_counts=%s\n",
				launchLimit,
				heldReasonSummary(planOut.Held),
			)
		}
		launchLimit = len(planOut.Assignments)
		result.LaunchLimit = launchLimit
	}

	launched := 0
	for i := 1; i <= cfg.Count; i++ {
		session := fmt.Sprintf("%s-%d", cfg.SessionPrefix, i)
		alreadyRunning, err := tmuxClient.HasSession(session)
		if err != nil {
			return nil, fmt.Errorf("check tmux session %s: %w", session, err)
		}
		if alreadyRunning {
			fmt.Fprintf(out, "[start] session %s already running\n", session)
			continue
		}
		if launched >= launchLimit {
			fmt.Fprintf(out, "[start] skipping %s: launch cap reached\n", session)
			continue
		}

		assignedIssue := ""
		if cfg.AssignmentMode == "assigned" {
			if launched >= len(assignedIDs) || strings.TrimSpace(assignedIDs[launched]) == "" {
				fmt.Fprintf(errOut, "[start] skipping %s: no assigned issue available under assignment mode\n", session)
				continue
			}
			assignedIssue = assignedIDs[launched]
		}

		worktreePath := filepath.Join(cfg.RepoPath, "worktrees", fmt.Sprintf("agent-%d", i))
		sessionID := fmt.Sprintf("%s-%s", session, now().UTC().Format("20060102T150405Z"))
		command := buildTmuxCommand(cfg, i, sessionID, worktreePath, assignedIssue)
		fmt.Fprintf(out, "[start] launching %s in %s\n", session, worktreePath)
		if err := tmuxClient.NewSession(session, command); err != nil {
			return nil, fmt.Errorf("launch tmux session %s: %w", session, err)
		}
		launched++
	}

	result.LaunchedCount = launched
	fmt.Fprintf(
		out,
		"[start] launch summary: requested=%d running=%d ready=%d launched=%d\n",
		cfg.Count,
		running,
		len(readyIssues),
		launched,
	)

	fmt.Fprintln(out, "[start] running sessions:")
	sessions, err := tmuxClient.ListSessions()
	if err == nil {
		for _, s := range sessions {
			if strings.HasPrefix(s.Name, cfg.SessionPrefix+"-") {
				fmt.Fprintln(out, s.Name)
			}
		}
	}

	return result, nil
}

type defaultTmuxClient struct{}

func (defaultTmuxClient) HasSession(name string) (bool, error) { return tmux.HasSession(name) }
func (defaultTmuxClient) NewSession(name, command string) error {
	return tmux.NewSession(name, command)
}
func (defaultTmuxClient) ListSessions() ([]tmux.SessionInfo, error) { return tmux.ListSessions() }

func validateWorktrees(cfg Config, tmuxClient TmuxClient) error {
	for i := 1; i <= cfg.Count; i++ {
		session := fmt.Sprintf("%s-%d", cfg.SessionPrefix, i)
		running, err := tmuxClient.HasSession(session)
		if err != nil {
			return err
		}
		if running {
			continue
		}
		worktreePath := filepath.Join(cfg.RepoPath, "worktrees", fmt.Sprintf("agent-%d", i))
		if !isGitWorktree(worktreePath) {
			return fmt.Errorf("expected git worktree is missing or invalid: %s", worktreePath)
		}
		clean, err := gitops.IsClean(worktreePath)
		if err != nil {
			return fmt.Errorf("check worktree cleanliness: %w", err)
		}
		if !clean {
			return fmt.Errorf("worktree is not clean and cannot safely create run branches: %s", worktreePath)
		}
	}
	return nil
}

func runDepSanity(cfg Config, now func() time.Time, out io.Writer, errOut io.Writer, result *Result) error {
	if cfg.DepSanityMode == "off" {
		fmt.Fprintln(out, "[start] dependency sanity check: skipped (mode=off)")
		return nil
	}

	issuesPath := filepath.Join(cfg.RepoPath, ".beads", "issues.jsonl")
	issues, issueCount, depCount, err := loadDepIssues(issuesPath)
	if err != nil {
		return fmt.Errorf("dependency sanity check failed to run: %w", err)
	}

	report := depsanity.Check(issues)
	report.Input.IssuesJSONL = issuesPath
	report.Input.IssueCount = issueCount
	report.Input.DependencyCount = depCount
	report.Summary.StrictMode = cfg.DepSanityMode == "enforce"

	reportDir := filepath.Join(cfg.RepoPath, "agent-logs", "plans", now().UTC().Format("2006/01/02"))
	if err := os.MkdirAll(reportDir, 0o755); err != nil {
		return err
	}
	reportPath := filepath.Join(reportDir, fmt.Sprintf("dep-sanity-%s.json", now().UTC().Format("20060102T150405Z")))
	raw, err := json.Marshal(report)
	if err != nil {
		return err
	}
	if err := os.WriteFile(reportPath, append(raw, '\n'), 0o644); err != nil {
		return err
	}
	result.DepSanityPath = reportPath

	fmt.Fprintf(out, "[start] dependency sanity: artifact=%s hazards=%d mode=%s\n", reportPath, report.Summary.HazardCount, cfg.DepSanityMode)
	if report.Summary.HazardCount > 0 {
		for _, h := range report.Hazards {
			rawDetails, _ := json.Marshal(h.Details)
			fmt.Fprintf(errOut, "[start] dependency hazard: code=%s details=%s\n", h.Code, string(rawDetails))
		}
		if cfg.DepSanityMode == "enforce" {
			return errors.New("refusing to launch: dependency graph hazards detected")
		}
	}
	return nil
}

func sessionAvailability(cfg Config, tmuxClient TmuxClient) (running int, launchable int, err error) {
	for i := 1; i <= cfg.Count; i++ {
		session := fmt.Sprintf("%s-%d", cfg.SessionPrefix, i)
		has, e := tmuxClient.HasSession(session)
		if e != nil {
			return 0, 0, e
		}
		if has {
			running++
		} else {
			launchable++
		}
	}
	return running, launchable, nil
}

func launchLimit(cfg Config, readyCount int, launchable int) int {
	if cfg.AssignmentMode == "assigned" {
		if readyCount < launchable {
			return readyCount
		}
		return launchable
	}
	if cfg.ForceCount {
		return launchable
	}
	if readyCount < launchable {
		return readyCount
	}
	return launchable
}

func buildPlan(cfg Config, now func() time.Time, ready []queue.Issue, slots int) (string, model.PlanOutput, error) {
	labels, err := loadIssueLabels(filepath.Join(cfg.RepoPath, ".beads", "issues.jsonl"))
	if err != nil {
		return "", model.PlanOutput{}, err
	}

	plannerInput := make([]plan.Issue, 0, len(ready))
	for _, item := range ready {
		plannerInput = append(plannerInput, plan.Issue{
			ID:        item.ID,
			Priority:  item.Priority,
			CreatedAt: item.CreatedAt,
			Labels:    append([]string(nil), labels[item.ID]...),
		})
	}

	planOut := plan.Build(plannerInput, slots)
	planDir := filepath.Join(cfg.RepoPath, "agent-logs", "plans", now().UTC().Format("2006/01/02"))
	if err := os.MkdirAll(planDir, 0o755); err != nil {
		return "", model.PlanOutput{}, err
	}
	path := filepath.Join(planDir, fmt.Sprintf("start-plan-%s.json", now().UTC().Format("20060102T150405Z")))
	raw, err := json.Marshal(planOut)
	if err != nil {
		return "", model.PlanOutput{}, err
	}
	if err := os.WriteFile(path, append(raw, '\n'), 0o644); err != nil {
		return "", model.PlanOutput{}, err
	}

	return path, planOut, nil
}

func loadIssueLabels(path string) (map[string][]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	labels := map[string][]string{}
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		var row struct {
			ID     string   `json:"id"`
			Labels []string `json:"labels"`
		}
		if err := json.Unmarshal([]byte(line), &row); err != nil {
			return nil, err
		}
		if strings.TrimSpace(row.ID) == "" {
			continue
		}
		labels[row.ID] = append([]string(nil), row.Labels...)
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return labels, nil
}

func loadDepIssues(path string) ([]depsanity.Issue, int, int, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, 0, 0, err
	}
	defer f.Close()

	issues := make([]depsanity.Issue, 0)
	issueCount := 0
	depCount := 0

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		issueCount++

		var row struct {
			ID           string `json:"id"`
			Status       string `json:"status"`
			Dependencies []struct {
				IssueID     string `json:"issue_id"`
				DependsOnID string `json:"depends_on_id"`
				Type        string `json:"type"`
			} `json:"dependencies"`
		}
		if err := json.Unmarshal([]byte(line), &row); err != nil {
			return nil, 0, 0, err
		}

		deps := make([]depsanity.Dependency, 0, len(row.Dependencies))
		for _, dep := range row.Dependencies {
			deps = append(deps, depsanity.Dependency{IssueID: dep.IssueID, DependsOnID: dep.DependsOnID, Type: dep.Type})
			depCount++
		}
		issues = append(issues, depsanity.Issue{ID: row.ID, Status: row.Status, Dependencies: deps})
	}
	if err := scanner.Err(); err != nil {
		return nil, 0, 0, err
	}
	return issues, issueCount, depCount, nil
}

func heldReasonSummary(held []model.PlanHeldIssue) string {
	if len(held) == 0 {
		return "none"
	}
	counts := map[string]int{}
	for _, item := range held {
		counts[item.ReasonCode]++
	}
	keys := make([]string, 0, len(counts))
	for k := range counts {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, fmt.Sprintf("%s=%d", k, counts[k]))
	}
	return strings.Join(parts, ",")
}

func extractAssignedIDs(planOut model.PlanOutput) []string {
	ids := make([]string, 0, len(planOut.Assignments))
	for _, item := range planOut.Assignments {
		if strings.TrimSpace(item.IssueID) == "" {
			continue
		}
		ids = append(ids, item.IssueID)
	}
	return ids
}

func buildTmuxCommand(cfg Config, index int, sessionID, worktreePath, assignedIssueID string) string {
	agentName := fmt.Sprintf("agent-%d", index)
	agentCommand := cfg.AgentCommand
	if strings.TrimSpace(agentCommand) == "" {
		agentCommand = "codex exec --dangerously-bypass-approvals-and-sandbox"
	}

	args := []string{
		cfg.OrcaBin,
		"loop-run",
		"--agent-name", agentName,
		"--session-id", sessionID,
		"--worktree", worktreePath,
		"--primary-repo", cfg.RepoPath,
		"--prompt-template", cfg.PromptTemplatePath,
		"--agent-command", agentCommand,
		"--assignment-mode", cfg.AssignmentMode,
		"--assigned-issue-id", assignedIssueID,
		"--max-runs", strconv.Itoa(cfg.MaxRuns),
		"--run-sleep-seconds", strconv.Itoa(cfg.RunSleepSeconds),
		"--no-work-drain-mode", cfg.NoWorkDrainMode,
		"--no-work-retry-limit", strconv.Itoa(cfg.NoWorkRetryLimit),
		"--mode-id", cfg.ModeID,
		"--approach-file", cfg.ApproachFile,
		"--orca-home", cfg.OrcaHome,
		"--with-lock-path", cfg.WithLockPath,
		"--queue-read-main-path", cfg.QueueReadMainPath,
		"--queue-write-main-path", cfg.QueueWriteMainPath,
		"--merge-main-path", cfg.MergeMainPath,
		"--br-guard-path", cfg.BrGuardPath,
		"--lock-scope", cfg.LockScope,
		"--lock-timeout-seconds", strconv.Itoa(int(cfg.LockTimeout.Seconds())),
	}
	return fmt.Sprintf("cd %q && %s", cfg.RepoPath, shellJoin(args))
}

func isGitWorktree(path string) bool {
	cmd := exec.Command("git", "-C", path, "rev-parse", "--is-inside-work-tree")
	return cmd.Run() == nil
}

func shellJoin(args []string) string {
	parts := make([]string, 0, len(args))
	for _, arg := range args {
		parts = append(parts, fmt.Sprintf("%q", arg))
	}
	return strings.Join(parts, " ")
}

func boolToInt(v bool) int {
	if v {
		return 1
	}
	return 0
}
