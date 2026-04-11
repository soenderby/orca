package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	bootstrappkg "github.com/soenderby/orca/internal/bootstrap"
	"github.com/soenderby/orca/internal/depsanity"
	doctorpkg "github.com/soenderby/orca/internal/doctor"
	gitops "github.com/soenderby/orca/internal/git"
	"github.com/soenderby/orca/internal/lock"
	"github.com/soenderby/orca/internal/loop"
	"github.com/soenderby/orca/internal/merge"
	"github.com/soenderby/orca/internal/model"
	"github.com/soenderby/orca/internal/plan"
	"github.com/soenderby/orca/internal/prompt"
	"github.com/soenderby/orca/internal/queue"
	startpkg "github.com/soenderby/orca/internal/start"
	statuspkg "github.com/soenderby/orca/internal/status"
	"github.com/soenderby/orca/internal/tmux"
	"github.com/soenderby/orca/internal/worktree"
)

var version = "dev"

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout io.Writer, stderr io.Writer) int {
	if len(args) == 0 {
		printUsage(stdout)
		return 0
	}

	cmd := args[0]
	rest := args[1:]

	var err error
	switch cmd {
	case "help", "-h", "--help":
		printUsage(stdout)
		return 0
	case "version":
		fmt.Fprintln(stdout, version)
		return 0
	case "plan":
		err = runPlan(rest, stdout, stderr)
	case "dep-sanity":
		err = runDepSanity(rest, stdout, stderr)
	case "setup-worktrees", "setup":
		err = runSetupWorktrees(rest, stdout, stderr)
	case "merge-main", "merge":
		err = runMergeMain(rest)
	case "with-lock", "lock":
		err = runWithLock(rest)
	case "queue-read-main", "queue-read":
		err = runQueueReadMain(rest, stdout, stderr)
	case "queue-write-main", "queue-write":
		err = runQueueWriteMain(rest, stdout, stderr)
	case "loop-run":
		err = runLoopRun(rest, stdout, stderr)

	case "start":
		err = runStart(rest, stdout, stderr)
	case "doctor":
		err = runDoctor(rest, stdout, stderr)
	case "bootstrap":
		err = runBootstrap(rest, stdout, stderr)
	case "stop":
		err = runStop(rest, stdout, stderr)
	case "status":
		err = runStatus(rest, stdout, stderr)
	case "gc-run-branches", "gc":
		err = runGCRunBranches(rest, stdout, stderr)
	case "queue-mutate", "queue":
		err = runQueueMutate(rest, stdout, stderr)
	default:
		fmt.Fprintf(stderr, "Unknown orca command: %s\n", cmd)
		printUsage(stderr)
		return 1
	}

	if err == nil {
		return 0
	}
	var ec *exitCodeError
	if errors.As(err, &ec) {
		return ec.Code
	}
	fmt.Fprintln(stderr, err)
	return 1
}

func printUsage(w io.Writer) {
	fmt.Fprintln(w, "Usage:")
	fmt.Fprintln(w, "  orca <command> [args]")
	fmt.Fprintln(w, "")
	fmt.Fprintln(w, "Commands:")
	fmt.Fprintln(w, "  bootstrap [--yes] [--dry-run]")
	fmt.Fprintln(w, "  doctor [--json]")
	fmt.Fprintln(w, "  start [count] [--runs N|--continuous(self-select only)] [--drain|--watch] [--no-work-retries N] [--reasoning-level LEVEL]")
	fmt.Fprintln(w, "  stop")
	fmt.Fprintln(w, "  status [--json]")
	fmt.Fprintln(w, "  plan [--slots N] [--output PATH] [--ready-json PATH] [--issues-jsonl PATH]")
	fmt.Fprintln(w, "  dep-sanity [--issues-jsonl PATH] [--output PATH] [--strict]")
	fmt.Fprintln(w, "  gc-run-branches [--apply] [--base REF]")
	fmt.Fprintln(w, "  setup-worktrees [count]")
	fmt.Fprintln(w, "  with-lock [--scope NAME] [--timeout SECONDS] -- <command> [args...]")
	fmt.Fprintln(w, "  queue-read-main [options] -- <queue-read-command> [args...]")
	fmt.Fprintln(w, "  queue-write-main [options] -- <queue-command> [args...]")
	fmt.Fprintln(w, "  queue-mutate [options] <mutation> [args...]")
	fmt.Fprintln(w, "  merge-main [--source BRANCH] [options]")
	fmt.Fprintln(w, "  version")
}

func runPlan(args []string, stdout io.Writer, stderr io.Writer) error {
	fs := flag.NewFlagSet("plan", flag.ContinueOnError)
	fs.SetOutput(stderr)

	slots := fs.Int("slots", 1, "max assignments")
	outputPath := fs.String("output", "", "write plan json to path")
	readyJSONPath := fs.String("ready-json", "", "ready issues json path")
	issuesJSONLPath := fs.String("issues-jsonl", "", "issues snapshot jsonl path")

	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return fmt.Errorf("plan: unexpected positional args: %v", fs.Args())
	}
	if *slots < 0 {
		return fmt.Errorf("plan: --slots must be a non-negative integer: %d", *slots)
	}

	repoRoot, err := gitops.RepoRoot(".")
	if err != nil {
		return fmt.Errorf("plan: resolve repo root: %w", err)
	}

	issuesPath := *issuesJSONLPath
	if strings.TrimSpace(issuesPath) == "" {
		issuesPath = filepath.Join(repoRoot, ".beads", "issues.jsonl")
	}

	labelMap, err := loadIssueLabels(issuesPath)
	if err != nil {
		return fmt.Errorf("plan: load issue labels: %w", err)
	}

	ready, err := loadReadyIssues(repoRoot, *readyJSONPath)
	if err != nil {
		return fmt.Errorf("plan: load ready issues: %w", err)
	}

	plannerInput := make([]plan.Issue, 0, len(ready))
	for _, issue := range ready {
		plannerInput = append(plannerInput, plan.Issue{
			ID:        issue.ID,
			Priority:  issue.Priority,
			CreatedAt: issue.CreatedAt,
			Labels:    append([]string(nil), labelMap[issue.ID]...),
		})
	}

	result := plan.Build(plannerInput, *slots)
	data, err := json.Marshal(result)
	if err != nil {
		return fmt.Errorf("plan: marshal output: %w", err)
	}

	if strings.TrimSpace(*outputPath) != "" {
		if err := os.MkdirAll(filepath.Dir(*outputPath), 0o755); err != nil {
			return fmt.Errorf("plan: create output directory: %w", err)
		}
		if err := os.WriteFile(*outputPath, append(data, '\n'), 0o644); err != nil {
			return fmt.Errorf("plan: write output file: %w", err)
		}
	}

	_, _ = stdout.Write(append(data, '\n'))
	return nil
}

func runDepSanity(args []string, stdout io.Writer, stderr io.Writer) error {
	fs := flag.NewFlagSet("dep-sanity", flag.ContinueOnError)
	fs.SetOutput(stderr)

	issuesJSONLPath := fs.String("issues-jsonl", "", "issues snapshot jsonl path")
	outputPath := fs.String("output", "", "write report json to path")
	strict := fs.Bool("strict", false, "exit non-zero when hazards found")

	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return fmt.Errorf("dep-sanity: unexpected positional args: %v", fs.Args())
	}

	repoRoot, err := gitops.RepoRoot(".")
	if err != nil {
		return fmt.Errorf("dep-sanity: resolve repo root: %w", err)
	}

	issuesPath := *issuesJSONLPath
	if strings.TrimSpace(issuesPath) == "" {
		issuesPath = filepath.Join(repoRoot, ".beads", "issues.jsonl")
	}

	issues, issueCount, depCount, err := loadDepIssues(issuesPath)
	if err != nil {
		return fmt.Errorf("dep-sanity: load issues: %w", err)
	}

	report := depsanity.Check(issues)
	report.Input.IssuesJSONL = issuesPath
	report.Input.IssueCount = issueCount
	report.Input.DependencyCount = depCount
	report.Summary.StrictMode = *strict

	data, err := json.Marshal(report)
	if err != nil {
		return fmt.Errorf("dep-sanity: marshal report: %w", err)
	}

	if strings.TrimSpace(*outputPath) != "" {
		if err := os.MkdirAll(filepath.Dir(*outputPath), 0o755); err != nil {
			return fmt.Errorf("dep-sanity: create output directory: %w", err)
		}
		if err := os.WriteFile(*outputPath, append(data, '\n'), 0o644); err != nil {
			return fmt.Errorf("dep-sanity: write output: %w", err)
		}
	}

	_, _ = stdout.Write(append(data, '\n'))

	if *strict && report.Summary.HazardCount > 0 {
		return &exitCodeError{Code: 2}
	}
	return nil
}

func runSetupWorktrees(args []string, stdout io.Writer, stderr io.Writer) error {
	count := 2
	if len(args) > 1 {
		return fmt.Errorf("setup-worktrees: expected at most one positional count argument")
	}
	if len(args) == 1 {
		v, err := strconv.Atoi(args[0])
		if err != nil || v <= 0 {
			return fmt.Errorf("setup-worktrees: count must be a positive integer: %s", args[0])
		}
		count = v
	}

	repoRoot, err := gitops.RepoRoot(".")
	if err != nil {
		return fmt.Errorf("setup-worktrees: resolve repo root: %w", err)
	}

	baseOverride := strings.TrimSpace(os.Getenv("ORCA_BASE_REF"))
	result, err := worktree.Setup(worktree.SetupConfig{
		RepoPath:        repoRoot,
		Count:           count,
		BaseRefOverride: baseOverride,
	})
	if err != nil {
		return fmt.Errorf("setup-worktrees: %w", err)
	}

	fmt.Fprintf(stdout, "[setup] base ref for new worktrees: %s\n", result.BaseRef)
	for _, warning := range result.Warnings {
		fmt.Fprintf(stderr, "[setup] warning: %s\n", warning)
	}
	for _, rel := range result.Existing {
		fmt.Fprintf(stdout, "[setup] %s already exists\n", rel)
	}
	for _, rel := range result.Created {
		fmt.Fprintf(stdout, "[setup] created %s\n", rel)
	}
	fmt.Fprintln(stdout, "[setup] done")
	return nil
}

func runMergeMain(args []string) error {
	fs := flag.NewFlagSet("merge-main", flag.ContinueOnError)
	fs.SetOutput(io.Discard)

	source := fs.String("source", "", "source branch")
	repo := fs.String("repo", strings.TrimSpace(os.Getenv("ORCA_PRIMARY_REPO")), "primary repo")
	scope := fs.String("scope", envOrDefault("ORCA_LOCK_SCOPE", "merge"), "lock scope")
	timeoutSec := fs.Int("timeout", envIntOrDefault("ORCA_LOCK_TIMEOUT_SECONDS", 120), "lock timeout in seconds")

	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return fmt.Errorf("merge-main: unexpected positional args: %v", fs.Args())
	}

	primaryRepo := *repo
	if strings.TrimSpace(primaryRepo) == "" {
		var err error
		primaryRepo, err = gitops.RepoRoot(".")
		if err != nil {
			return fmt.Errorf("merge-main: resolve repo root: %w", err)
		}
	}

	src := strings.TrimSpace(*source)
	if src == "" {
		branch, err := gitops.CurrentBranch(primaryRepo)
		if err != nil {
			return fmt.Errorf("merge-main: resolve source branch: %w", err)
		}
		src = strings.TrimSpace(branch)
	}
	if src == "" || src == "HEAD" {
		return errors.New("merge-main: unable to determine source branch; pass --source <branch>")
	}

	return merge.MergeToMain(merge.MergeConfig{
		PrimaryRepo: primaryRepo,
		Source:      src,
		LockScope:   *scope,
		LockTimeout: time.Duration(*timeoutSec) * time.Second,
	})
}

func runWithLock(args []string) error {
	scope := envOrDefault("ORCA_LOCK_SCOPE", "merge")
	timeout := time.Duration(envIntOrDefault("ORCA_LOCK_TIMEOUT_SECONDS", 120)) * time.Second

	i := 0
	for i < len(args) {
		token := args[i]
		switch token {
		case "--scope":
			if i+1 >= len(args) {
				return errors.New("with-lock: --scope requires an argument")
			}
			scope = args[i+1]
			i += 2
		case "--timeout", "--lock-timeout":
			if i+1 >= len(args) {
				return errors.New("with-lock: --timeout requires an argument")
			}
			v, err := strconv.Atoi(args[i+1])
			if err != nil || v <= 0 {
				return fmt.Errorf("with-lock: timeout must be a positive integer: %s", args[i+1])
			}
			timeout = time.Duration(v) * time.Second
			i += 2
		case "--":
			i++
			goto run
		case "-h", "--help":
			return errors.New("usage: with-lock [--scope NAME] [--timeout SECONDS] -- <command> [args...]")
		default:
			goto run
		}
	}

run:
	if i >= len(args) {
		return errors.New("with-lock: command is required after --")
	}

	cmdArgs := args[i:]
	locker := lock.NewFileLocker(".")
	return locker.WithLock(scope, timeout, func() error {
		return runPassthrough(cmdArgs)
	})
}

func runStart(args []string, stdout io.Writer, stderr io.Writer) error {
	count := 2
	maxRuns := envNonNegativeIntOrDefault("MAX_RUNS", 0)
	runSleepSeconds := envNonNegativeIntOrDefault("RUN_SLEEP_SECONDS", 2)
	noWorkDrainMode := envOrDefault("ORCA_NO_WORK_DRAIN_MODE", "drain")
	noWorkRetryLimit := envNonNegativeIntOrDefault("ORCA_NO_WORK_RETRY_LIMIT", 1)
	reasoningLevel := strings.TrimSpace(os.Getenv("AGENT_REASONING_LEVEL"))

	parsedCount := false
	i := 0
	for i < len(args) {
		token := args[i]
		switch token {
		case "--runs":
			if i+1 >= len(args) {
				return errors.New("start: --runs requires a numeric argument")
			}
			v, err := strconv.Atoi(args[i+1])
			if err != nil || v < 0 {
				return fmt.Errorf("start: runs must be a non-negative integer: %s", args[i+1])
			}
			maxRuns = v
			i += 2
		case "--continuous":
			maxRuns = 0
			i++
		case "--drain":
			noWorkDrainMode = "drain"
			i++
		case "--watch":
			noWorkDrainMode = "watch"
			i++
		case "--no-work-retries":
			if i+1 >= len(args) {
				return errors.New("start: --no-work-retries requires a non-negative integer argument")
			}
			v, err := strconv.Atoi(args[i+1])
			if err != nil || v < 0 {
				return fmt.Errorf("start: ORCA_NO_WORK_RETRY_LIMIT must be a non-negative integer: %s", args[i+1])
			}
			noWorkRetryLimit = v
			i += 2
		case "--reasoning-level":
			if i+1 >= len(args) {
				return errors.New("start: --reasoning-level requires an argument")
			}
			reasoningLevel = args[i+1]
			i += 2
		case "-h", "--help":
			return errors.New("usage: start [count] [--runs N|--continuous] [--drain|--watch] [--no-work-retries N] [--reasoning-level LEVEL]")
		default:
			if strings.HasPrefix(token, "-") {
				return fmt.Errorf("start: unexpected argument: %s", token)
			}
			if parsedCount {
				return fmt.Errorf("start: unexpected argument: %s", token)
			}
			v, err := strconv.Atoi(token)
			if err != nil || v <= 0 {
				return fmt.Errorf("start: count must be a positive integer: %s", token)
			}
			count = v
			parsedCount = true
			i++
		}
	}

	repoPath := strings.TrimSpace(os.Getenv("ORCA_PRIMARY_REPO"))
	if repoPath == "" {
		var err error
		repoPath, err = gitops.RepoRoot(".")
		if err != nil {
			return fmt.Errorf("start: resolve repo root: %w", err)
		}
	}

	orcaHome, err := orcaHome()
	if err != nil {
		return err
	}

	promptTemplate := strings.TrimSpace(os.Getenv("PROMPT_TEMPLATE"))
	if promptTemplate == "" {
		localPrompt := filepath.Join(repoPath, "ORCA_PROMPT.md")
		if _, err := os.Stat(localPrompt); err == nil {
			promptTemplate = localPrompt
		} else {
			promptTemplate = filepath.Join(orcaHome, "ORCA_PROMPT.md")
		}
	}

	agentModel := envOrDefault("AGENT_MODEL", "gpt-5.3-codex")
	agentCommandWasSet := false
	if _, ok := os.LookupEnv("AGENT_COMMAND"); ok {
		agentCommandWasSet = true
	}
	agentCommand := strings.TrimSpace(os.Getenv("AGENT_COMMAND"))
	if agentCommand == "" {
		agentCommand = fmt.Sprintf("codex exec --dangerously-bypass-approvals-and-sandbox --model %s", agentModel)
	}
	if strings.TrimSpace(reasoningLevel) != "" {
		if agentCommandWasSet {
			fmt.Fprintln(stderr, "[start] AGENT_COMMAND override detected; --reasoning-level will not modify AGENT_COMMAND")
		} else {
			agentCommand = fmt.Sprintf("%s -c model_reasoning_effort=%s", agentCommand, reasoningLevel)
		}
	}

	assignmentMode := envOrDefault("ORCA_ASSIGNMENT_MODE", "assigned")
	depSanityMode := envOrDefault("ORCA_DEP_SANITY_MODE", "enforce")
	sessionPrefix := envOrDefault("SESSION_PREFIX", "orca-agent")
	lockScope := envOrDefault("ORCA_LOCK_SCOPE", "merge")
	lockTimeout := time.Duration(envIntOrDefault("ORCA_LOCK_TIMEOUT_SECONDS", 120)) * time.Second
	baseRefOverride := strings.TrimSpace(os.Getenv("ORCA_BASE_REF"))
	forceCount := envIntOrDefault("ORCA_FORCE_COUNT", 0) == 1
	orcaBin, err := os.Executable()
	if err != nil {
		return fmt.Errorf("start: resolve orca executable: %w", err)
	}
	withLockPath := envOrDefault("ORCA_WITH_LOCK_PATH", filepath.Join(orcaHome, "with-lock.sh"))
	queueReadPath := envOrDefault("ORCA_QUEUE_READ_MAIN_PATH", filepath.Join(orcaHome, "queue-read-main.sh"))
	queueWritePath := envOrDefault("ORCA_QUEUE_WRITE_MAIN_PATH", filepath.Join(orcaHome, "queue-write-main.sh"))
	mergeMainPath := envOrDefault("ORCA_MERGE_MAIN_PATH", filepath.Join(orcaHome, "merge-main.sh"))
	brGuardPath := envOrDefault("ORCA_BR_GUARD_PATH", filepath.Join(orcaHome, "br-guard.sh"))

	_, err = startpkg.Run(startpkg.Config{
		RepoPath:           repoPath,
		Count:              count,
		SessionPrefix:      sessionPrefix,
		AssignmentMode:     assignmentMode,
		MaxRuns:            maxRuns,
		ForceCount:         forceCount,
		DepSanityMode:      depSanityMode,
		PromptTemplatePath: promptTemplate,
		AgentCommand:       agentCommand,
		NoWorkDrainMode:    noWorkDrainMode,
		NoWorkRetryLimit:   noWorkRetryLimit,
		RunSleepSeconds:    runSleepSeconds,
		ModeID:             strings.TrimSpace(os.Getenv("ORCA_MODE_ID")),
		ApproachFile:       strings.TrimSpace(os.Getenv("ORCA_WORK_APPROACH_FILE")),
		LockScope:          lockScope,
		LockTimeout:        lockTimeout,
		BaseRefOverride:    baseRefOverride,
		OrcaHome:           orcaHome,
		OrcaBin:            orcaBin,
		WithLockPath:       withLockPath,
		QueueReadMainPath:  queueReadPath,
		QueueWriteMainPath: queueWritePath,
		MergeMainPath:      mergeMainPath,
		BrGuardPath:        brGuardPath,
		Stdout:             stdout,
		Stderr:             stderr,
	})
	return err
}

func runLoopRun(args []string, _ io.Writer, stderr io.Writer) error {
	fs := flag.NewFlagSet("loop-run", flag.ContinueOnError)
	fs.SetOutput(stderr)

	agentName := fs.String("agent-name", "", "agent name")
	sessionID := fs.String("session-id", "", "session id")
	worktreePath := fs.String("worktree", "", "worktree path")
	primaryRepo := fs.String("primary-repo", "", "primary repo path")
	promptTemplate := fs.String("prompt-template", "", "prompt template path")
	agentCommand := fs.String("agent-command", "", "agent command")
	assignmentMode := fs.String("assignment-mode", "self-select", "assignment mode")
	assignedIssueID := fs.String("assigned-issue-id", "", "assigned issue id")
	maxRuns := fs.Int("max-runs", 0, "max runs (0=unbounded)")
	runSleepSeconds := fs.Int("run-sleep-seconds", 2, "sleep seconds between runs")
	noWorkDrainMode := fs.String("no-work-drain-mode", "drain", "drain mode")
	noWorkRetryLimit := fs.Int("no-work-retry-limit", 1, "no_work retry limit")
	modeID := fs.String("mode-id", "", "mode id")
	approachFile := fs.String("approach-file", "", "approach file")
	orcaHomePath := fs.String("orca-home", "", "orca home")
	withLockPath := fs.String("with-lock-path", "", "with-lock helper path")
	queueReadMainPath := fs.String("queue-read-main-path", "", "queue-read helper path")
	queueWriteMainPath := fs.String("queue-write-main-path", "", "queue-write helper path")
	mergeMainPath := fs.String("merge-main-path", "", "merge helper path")
	brGuardPath := fs.String("br-guard-path", "", "br guard path")
	lockScope := fs.String("lock-scope", envOrDefault("ORCA_LOCK_SCOPE", "merge"), "lock scope")
	lockTimeoutSeconds := fs.Int("lock-timeout-seconds", envIntOrDefault("ORCA_LOCK_TIMEOUT_SECONDS", 120), "lock timeout seconds")

	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return fmt.Errorf("loop-run: unexpected positional args: %v", fs.Args())
	}

	if strings.TrimSpace(*agentName) == "" {
		return errors.New("loop-run: --agent-name is required")
	}
	if strings.TrimSpace(*sessionID) == "" {
		return errors.New("loop-run: --session-id is required")
	}
	if strings.TrimSpace(*primaryRepo) == "" {
		return errors.New("loop-run: --primary-repo is required")
	}
	if strings.TrimSpace(*worktreePath) == "" {
		*worktreePath = *primaryRepo
	}
	if strings.TrimSpace(*promptTemplate) == "" {
		return errors.New("loop-run: --prompt-template is required")
	}
	if strings.TrimSpace(*agentCommand) == "" {
		return errors.New("loop-run: --agent-command is required")
	}
	if *maxRuns < 0 {
		return fmt.Errorf("loop-run: --max-runs must be non-negative: %d", *maxRuns)
	}
	if *runSleepSeconds < 0 {
		return fmt.Errorf("loop-run: --run-sleep-seconds must be non-negative: %d", *runSleepSeconds)
	}

	promptTextRaw, err := os.ReadFile(*promptTemplate)
	if err != nil {
		return fmt.Errorf("loop-run: read prompt template: %w", err)
	}
	promptText := string(promptTextRaw)

	if strings.TrimSpace(*orcaHomePath) == "" {
		*orcaHomePath = *primaryRepo
	}
	if strings.TrimSpace(*withLockPath) == "" {
		*withLockPath = filepath.Join(*orcaHomePath, "with-lock.sh")
	}
	if strings.TrimSpace(*queueReadMainPath) == "" {
		*queueReadMainPath = filepath.Join(*orcaHomePath, "queue-read-main.sh")
	}
	if strings.TrimSpace(*queueWriteMainPath) == "" {
		*queueWriteMainPath = filepath.Join(*orcaHomePath, "queue-write-main.sh")
	}
	if strings.TrimSpace(*mergeMainPath) == "" {
		*mergeMainPath = filepath.Join(*orcaHomePath, "merge-main.sh")
	}
	if strings.TrimSpace(*brGuardPath) == "" {
		*brGuardPath = filepath.Join(*orcaHomePath, "br-guard.sh")
	}

	harnessVersion := ""
	if v, err := gitops.Describe(*orcaHomePath); err == nil {
		harnessVersion = v
	}

	approachSource := ""
	approachSHA := ""
	if strings.TrimSpace(*approachFile) != "" {
		approachSource = *approachFile
		if raw, err := os.ReadFile(*approachFile); err == nil {
			sum := sha256.Sum256(raw)
			approachSHA = hex.EncodeToString(sum[:])
		}
	}

	sessionLogPath := filepath.Join(*primaryRepo, "agent-logs", "sessions", sessionDatePath(*sessionID, time.Now()), *sessionID, "session.log")
	_ = appendSessionLogLine(sessionLogPath, fmt.Sprintf("configured mode attribution: mode_id=%s approach_source=%s approach_sha256=%s",
		valueOrDefault(*modeID, "none"),
		valueOrDefault(approachSource, "none"),
		valueOrDefault(approachSHA, "none"),
	))

	metricsPath := filepath.Join(*primaryRepo, "agent-logs", "metrics.jsonl")
	runSleep := time.Duration(*runSleepSeconds) * time.Second

	guardBinDir := ""
	if strings.TrimSpace(*brGuardPath) != "" {
		d, err := os.MkdirTemp("", "orca-br-guard-bin-")
		if err == nil {
			if err := os.Symlink(*brGuardPath, filepath.Join(d, "br")); err == nil {
				guardBinDir = d
				defer os.RemoveAll(d)
			} else {
				_ = os.RemoveAll(d)
			}
		}
	}

	now := time.Now
	loopConfig := loop.LoopConfig{
		AgentName:        *agentName,
		SessionID:        *sessionID,
		HarnessVersion:   harnessVersion,
		AssignmentMode:   *assignmentMode,
		AssignedIssueID:  *assignedIssueID,
		ModeID:           *modeID,
		ApproachSource:   approachSource,
		ApproachSHA256:   approachSHA,
		MaxRuns:          *maxRuns,
		RunSleep:         runSleep,
		NoWorkDrainMode:  *noWorkDrainMode,
		NoWorkRetryLimit: *noWorkRetryLimit,
		MetricsPath:      metricsPath,
		Now:              now,
		Executor: loop.ExecutorFunc(func(inv loop.RunInvocation) (loop.ExecutionResult, error) {
			vars := map[string]string{
				"AGENT_NAME":                 *agentName,
				"ISSUE_ID":                   issuePlaceholder(*assignedIssueID),
				"ASSIGNED_ISSUE_ID":          *assignedIssueID,
				"ASSIGNMENT_MODE":            *assignmentMode,
				"WORKTREE":                   *worktreePath,
				"RUN_SUMMARY_PATH":           inv.Paths.SummaryJSON,
				"RUN_SUMMARY_JSON":           inv.Paths.SummaryJSON,
				"SUMMARY_JSON_PATH":          inv.Paths.SummaryJSON,
				"PRIMARY_REPO":               *primaryRepo,
				"ORCA_PRIMARY_REPO":          *primaryRepo,
				"WITH_LOCK_PATH":             *withLockPath,
				"ORCA_WITH_LOCK_PATH":        *withLockPath,
				"QUEUE_READ_MAIN_PATH":       *queueReadMainPath,
				"ORCA_QUEUE_READ_MAIN_PATH":  *queueReadMainPath,
				"QUEUE_WRITE_MAIN_PATH":      *queueWriteMainPath,
				"ORCA_QUEUE_WRITE_MAIN_PATH": *queueWriteMainPath,
				"MERGE_MAIN_PATH":            *mergeMainPath,
				"ORCA_MERGE_MAIN_PATH":       *mergeMainPath,
			}
			renderedPrompt, err := prompt.Render(promptText, vars)
			if err != nil {
				return loop.ExecutionResult{}, fmt.Errorf("render prompt: %w", err)
			}

			if err := os.MkdirAll(filepath.Dir(inv.Paths.RunLog), 0o755); err != nil {
				return loop.ExecutionResult{}, fmt.Errorf("create run log directory: %w", err)
			}
			logFile, err := os.OpenFile(inv.Paths.RunLog, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
			if err != nil {
				return loop.ExecutionResult{}, fmt.Errorf("open run log: %w", err)
			}
			defer logFile.Close()

			startTime := time.Now()
			exitCode := 0
			runTimestamp := runTimestamp(now())
			branchName, err := prepareRunBranch(*worktreePath, *agentName, *sessionID, inv.RunNumber, runTimestamp, strings.TrimSpace(os.Getenv("ORCA_BASE_REF")), logFile)
			if err != nil {
				dur := int(time.Since(startTime).Seconds())
				if dur < 0 {
					dur = 0
				}
				return loop.ExecutionResult{ExitCode: 1, DurationSeconds: dur, FailureReason: "run-branch-setup-failed", StopRequested: true}, nil
			}
			_ = branchName

			cmd := exec.Command("bash", "-lc", *agentCommand)
			cmd.Dir = *worktreePath
			cmd.Stdin = strings.NewReader(renderedPrompt)
			cmd.Stdout = logFile
			cmd.Stderr = logFile
			cmd.Env = buildLoopEnv(inv, *agentName, *sessionID, *worktreePath, *assignmentMode, *assignedIssueID, *primaryRepo, *withLockPath, *queueReadMainPath, *queueWriteMainPath, *mergeMainPath, *brGuardPath, *lockScope, *lockTimeoutSeconds, guardBinDir)

			if err := cmd.Run(); err != nil {
				if ee, ok := err.(*exec.ExitError); ok {
					exitCode = ee.ExitCode()
				} else {
					return loop.ExecutionResult{}, err
				}
			}

			failureReason := ""
			stopRequested := false
			if err := restoreWorktreeQueueArtifacts(*worktreePath); err != nil {
				failureReason = "worktree-queue-restore-failed"
				stopRequested = true
				exitCode = 1
			}

			dur := int(time.Since(startTime).Seconds())
			if dur < 0 {
				dur = 0
			}
			return loop.ExecutionResult{ExitCode: exitCode, DurationSeconds: dur, FailureReason: failureReason, StopRequested: stopRequested}, nil
		}),
		PathsForRun: func(runNumber int) loop.RunPaths {
			n := now().UTC()
			runID := fmt.Sprintf("%04d-%s", runNumber, n.Format("20060102T150405000000000Z"))
			runDir := filepath.Join(*primaryRepo, "agent-logs", "sessions", sessionDatePath(*sessionID, n), *sessionID, "runs", runID)
			return loop.RunPaths{
				SummaryJSON:      filepath.Join(runDir, "summary.json"),
				RunLog:           filepath.Join(runDir, "run.log"),
				SummaryMarkdown:  filepath.Join(runDir, "summary.md"),
				AgentLastMessage: filepath.Join(runDir, "last-message.md"),
			}
		},
		OnRunComplete: func(outcome loop.RunOutcome, metrics model.MetricsRow) {
			if envIntOrDefault("ORCA_COMPACT_SUMMARY", 1) != 1 {
				return
			}
			var summaryResult *string
			var summaryIssueStatus *string
			var summaryMerged *bool
			var summaryDiscoveryCount *int
			var summaryDiscoveryIDs []string
			if outcome.SummaryResult != nil && outcome.SummaryResult.Summary != nil {
				s := outcome.SummaryResult.Summary
				summaryResult = &s.Result
				summaryIssueStatus = &s.IssueStatus
				summaryMerged = &s.Merged
				summaryDiscoveryCount = s.DiscoveryCount
				summaryDiscoveryIDs = append([]string(nil), s.DiscoveryIDs...)
			}

			_ = loop.WriteRunSummaryMarkdown(metrics.Files.SummaryMarkdown, loop.SummaryMarkdownInput{
				Timestamp:                now(),
				AgentName:                metrics.AgentName,
				SessionID:                metrics.SessionID,
				RunNumber:                metrics.RunNumber,
				ExitCode:                 metrics.ExitCode,
				DurationSeconds:          metrics.DurationsSeconds.IterationTotal,
				Result:                   metrics.Result,
				Reason:                   metrics.Reason,
				SummaryParseStatus:       metrics.SummaryParseStatus,
				SummarySchemaStatus:      metrics.SummarySchemaStatus,
				SummarySchemaReasonCodes: metrics.SummarySchemaReasonCodes,
				LoopAction:               outcome.LoopAction,
				LoopActionReason:         outcome.LoopActionReason,
				IssueID:                  outcome.IssueID,
				AssignedIssueID:          *assignedIssueID,
				AssignmentMatch:          outcome.AssignmentMatch,
				PlannedAssignedIssue:     outcome.PlannedAssignedIssue,
				AssignmentSource:         outcome.AssignmentSource,
				AssignmentOutcome:        outcome.AssignmentOutcome,
				SummaryResult:            summaryResult,
				SummaryIssueStatus:       summaryIssueStatus,
				SummaryMerged:            summaryMerged,
				SummaryDiscoveryCount:    summaryDiscoveryCount,
				SummaryDiscoveryIDs:      summaryDiscoveryIDs,
				TokensUsed:               outcome.TokensUsed,
				TokensParseStatus:        outcome.TokensParseStatus,
				ModeID:                   metrics.ModeID,
				ApproachSource:           metrics.ApproachSource,
				ApproachSHA256:           metrics.ApproachSHA256,
				RunLogPath:               metrics.Files.RunLog,
				SummaryJSONPath:          metrics.Files.SummaryJSON,
				SummaryMarkdownPath:      metrics.Files.SummaryMarkdown,
				LastMessagePath:          metrics.Files.AgentLastMessage,
			})
		},
	}

	return loop.Loop(loopConfig)
}

func runQueueReadMain(args []string, stdout io.Writer, _ io.Writer) error {
	repo := strings.TrimSpace(os.Getenv("ORCA_PRIMARY_REPO"))
	scope := envOrDefault("ORCA_LOCK_SCOPE", "merge")
	timeout := time.Duration(envIntOrDefault("ORCA_LOCK_TIMEOUT_SECONDS", 120)) * time.Second

	i := 0
	for i < len(args) {
		token := args[i]
		switch token {
		case "--repo":
			if i+1 >= len(args) {
				return errors.New("queue-read-main: --repo requires an argument")
			}
			repo = args[i+1]
			i += 2
		case "--lock-helper":
			if i+1 >= len(args) {
				return errors.New("queue-read-main: --lock-helper requires an argument")
			}
			return errors.New("queue-read-main: --lock-helper is not supported by go implementation yet")
		case "--scope":
			if i+1 >= len(args) {
				return errors.New("queue-read-main: --scope requires an argument")
			}
			scope = args[i+1]
			i += 2
		case "--timeout", "--lock-timeout":
			if i+1 >= len(args) {
				return errors.New("queue-read-main: --timeout requires an argument")
			}
			v, err := strconv.Atoi(args[i+1])
			if err != nil || v <= 0 {
				return fmt.Errorf("queue-read-main: lock timeout must be a positive integer: %s", args[i+1])
			}
			timeout = time.Duration(v) * time.Second
			i += 2
		case "--fallback":
			if i+1 >= len(args) {
				return errors.New("queue-read-main: --fallback requires an argument")
			}
			return errors.New("queue-read-main: --fallback is not supported by go implementation yet")
		case "--worktree":
			if i+1 >= len(args) {
				return errors.New("queue-read-main: --worktree requires an argument")
			}
			return errors.New("queue-read-main: --worktree is not supported by go implementation yet")
		case "--":
			i++
			goto run
		case "-h", "--help":
			return errors.New("usage: queue-read-main [options] -- <queue-read-command> [args...]")
		default:
			goto run
		}
	}

run:
	if strings.TrimSpace(repo) == "" {
		root, err := gitops.RepoRoot(".")
		if err != nil {
			return fmt.Errorf("queue-read-main: resolve repo root: %w", err)
		}
		repo = root
	}

	if i >= len(args) {
		return errors.New("queue-read-main: queue read command is required after --")
	}
	cmdArgs := args[i:]
	if len(cmdArgs) < 2 || cmdArgs[0] != "br" {
		return fmt.Errorf("queue-read-main: unsupported command: %s (expected: br ...)", cmdArgs[0])
	}

	if classifyBRCommand(cmdArgs[1:]) != "read_only" {
		return fmt.Errorf("queue-read-main: command is not a queue read command: %s", strings.Join(cmdArgs, " "))
	}

	client, err := queue.New(queue.Config{
		RepoPath: repo,
		Scope:    scope,
		Timeout:  timeout,
		BRBinary: resolveBRBinary(),
	})
	if err != nil {
		return fmt.Errorf("queue-read-main: initialize queue client: %w", err)
	}

	sub := cmdArgs[1]
	switch sub {
	case "ready":
		issues, err := client.ReadReady()
		if err != nil {
			return err
		}
		return writeJSON(stdout, issues)
	case "show":
		if len(cmdArgs) < 3 {
			return errors.New("queue-read-main: br show requires issue id")
		}
		issue, err := client.Show(cmdArgs[2])
		if err != nil {
			return err
		}
		return writeJSON(stdout, issue)
	case "dep":
		if len(cmdArgs) < 4 || cmdArgs[2] != "list" {
			return errors.New("queue-read-main: unsupported dep read command")
		}
		deps, err := client.DepList(cmdArgs[3])
		if err != nil {
			return err
		}
		return writeJSON(stdout, deps)
	default:
		return fmt.Errorf("queue-read-main: unsupported read command: %s", strings.Join(cmdArgs, " "))
	}
}

func runQueueWriteMain(args []string, stdout io.Writer, _ io.Writer) error {
	repo := strings.TrimSpace(os.Getenv("ORCA_PRIMARY_REPO"))
	scope := envOrDefault("ORCA_LOCK_SCOPE", "merge")
	timeout := time.Duration(envIntOrDefault("ORCA_LOCK_TIMEOUT_SECONDS", 120)) * time.Second
	actor := ""
	actorExplicit := false

	i := 0
	for i < len(args) {
		token := args[i]
		switch token {
		case "--repo":
			if i+1 >= len(args) {
				return errors.New("queue-write-main: --repo requires an argument")
			}
			repo = args[i+1]
			i += 2
		case "--lock-helper":
			if i+1 >= len(args) {
				return errors.New("queue-write-main: --lock-helper requires an argument")
			}
			return errors.New("queue-write-main: --lock-helper is not supported by go implementation yet")
		case "--scope":
			if i+1 >= len(args) {
				return errors.New("queue-write-main: --scope requires an argument")
			}
			scope = args[i+1]
			i += 2
		case "--timeout", "--lock-timeout":
			if i+1 >= len(args) {
				return errors.New("queue-write-main: --timeout requires an argument")
			}
			v, err := strconv.Atoi(args[i+1])
			if err != nil || v <= 0 {
				return fmt.Errorf("queue-write-main: lock timeout must be a positive integer: %s", args[i+1])
			}
			timeout = time.Duration(v) * time.Second
			i += 2
		case "--actor":
			if i+1 >= len(args) {
				return errors.New("queue-write-main: --actor requires an argument")
			}
			actor = args[i+1]
			actorExplicit = true
			i += 2
		case "--message":
			if i+1 >= len(args) {
				return errors.New("queue-write-main: --message requires an argument")
			}
			return errors.New("queue-write-main: --message is not supported by go implementation yet")
		case "--":
			i++
			goto run
		case "-h", "--help":
			return errors.New("usage: queue-write-main [options] -- <queue-command> [args...]")
		default:
			goto run
		}
	}

run:
	if strings.TrimSpace(repo) == "" {
		root, err := gitops.RepoRoot(".")
		if err != nil {
			return fmt.Errorf("queue-write-main: resolve repo root: %w", err)
		}
		repo = root
	}

	if !actorExplicit {
		return errors.New("queue-write-main: --actor is required and must be provided explicitly")
	}
	if strings.TrimSpace(actor) == "" {
		return errors.New("queue-write-main: --actor cannot be empty")
	}
	if i >= len(args) {
		return errors.New("queue-write-main: queue command is required after --")
	}
	cmdArgs := args[i:]
	if len(cmdArgs) < 2 || cmdArgs[0] != "br" {
		return fmt.Errorf("queue-write-main: unsupported queue command: %s (expected: br ...)", cmdArgs[0])
	}

	commandActor := extractActorFlag(cmdArgs[1:])
	if commandActor == "" {
		return fmt.Errorf("queue-write-main: queue command must include --actor %s", actor)
	}
	if commandActor != actor {
		return fmt.Errorf("queue-write-main: actor mismatch: helper=%s, command=%s", actor, commandActor)
	}

	if isCommentsAdd(cmdArgs[1:]) {
		if !hasFlag(cmdArgs[1:], "--file", "-f") {
			return errors.New("queue-write-main: unsafe comments mutation: require --file")
		}
		if hasFlag(cmdArgs[1:], "--message") {
			return errors.New("queue-write-main: unsupported comments payload form: --message is disallowed; use --file/stdin")
		}
	}

	client, err := queue.New(queue.Config{
		RepoPath: repo,
		Scope:    scope,
		Timeout:  timeout,
		BRBinary: resolveBRBinary(),
	})
	if err != nil {
		return fmt.Errorf("queue-write-main: initialize queue client: %w", err)
	}

	sub := cmdArgs[1]
	switch sub {
	case "update":
		if len(cmdArgs) < 3 {
			return errors.New("queue-write-main: br update requires issue id")
		}
		if !hasArg(cmdArgs[1:], "--claim") {
			return errors.New("queue-write-main: unsupported br update form (only --claim is supported)")
		}
		if err := client.Claim(cmdArgs[2], actor); err != nil {
			return err
		}
		_, _ = io.WriteString(stdout, "{}\n")
		return nil
	case "comments":
		if !isCommentsAdd(cmdArgs[1:]) || len(cmdArgs) < 4 {
			return errors.New("queue-write-main: unsupported comments mutation form")
		}
		issueID := cmdArgs[3]
		commentPath := valueAfterFlag(cmdArgs[1:], "--file", "-f")
		if strings.TrimSpace(commentPath) == "" {
			return errors.New("queue-write-main: comment file path is required")
		}
		payload, err := os.ReadFile(commentPath)
		if err != nil {
			return fmt.Errorf("queue-write-main: read comment file: %w", err)
		}
		if err := client.Comment(issueID, actor, string(payload)); err != nil {
			return err
		}
		_, _ = io.WriteString(stdout, "{}\n")
		return nil
	case "close":
		if len(cmdArgs) < 3 {
			return errors.New("queue-write-main: br close requires issue id")
		}
		if err := client.Close(cmdArgs[2], actor); err != nil {
			return err
		}
		_, _ = io.WriteString(stdout, "{}\n")
		return nil
	case "dep":
		if len(cmdArgs) < 5 || cmdArgs[2] != "add" {
			return errors.New("queue-write-main: unsupported dep mutation form")
		}
		fromID := cmdArgs[3]
		toID := cmdArgs[4]
		depType := valueAfterFlag(cmdArgs[1:], "--type")
		if err := client.DepAdd(fromID, toID, depType, actor); err != nil {
			return err
		}
		_, _ = io.WriteString(stdout, "{}\n")
		return nil
	case "sync":
		if err := client.Sync(); err != nil {
			return err
		}
		_, _ = io.WriteString(stdout, "{}\n")
		return nil
	default:
		return fmt.Errorf("queue-write-main: unsupported queue mutation command: %s", strings.Join(cmdArgs, " "))
	}
}

func runQueueMutate(args []string, stdout io.Writer, _ io.Writer) error {
	actor := ""
	helperPath := envOrDefault("ORCA_QUEUE_WRITE_MAIN_PATH", "")
	helperExplicit := false
	repo := ""
	lockHelper := ""
	scope := ""
	timeout := ""
	includeJSON := true

	i := 0
	for i < len(args) {
		tok := args[i]
		switch tok {
		case "--actor":
			if i+1 >= len(args) {
				return errors.New("queue-mutate: --actor requires an argument")
			}
			actor = args[i+1]
			i += 2
		case "--queue-write-helper":
			if i+1 >= len(args) {
				return errors.New("queue-mutate: --queue-write-helper requires an argument")
			}
			helperPath = args[i+1]
			helperExplicit = true
			i += 2
		case "--repo":
			if i+1 >= len(args) {
				return errors.New("queue-mutate: --repo requires an argument")
			}
			repo = args[i+1]
			i += 2
		case "--lock-helper":
			if i+1 >= len(args) {
				return errors.New("queue-mutate: --lock-helper requires an argument")
			}
			lockHelper = args[i+1]
			i += 2
		case "--scope":
			if i+1 >= len(args) {
				return errors.New("queue-mutate: --scope requires an argument")
			}
			scope = args[i+1]
			i += 2
		case "--timeout", "--lock-timeout":
			if i+1 >= len(args) {
				return errors.New("queue-mutate: --timeout requires an argument")
			}
			timeout = args[i+1]
			i += 2
		case "--no-json":
			includeJSON = false
			i++
		case "-h", "--help":
			return errors.New("usage: queue-mutate [--actor NAME] <claim|comment|close|dep-add> ...")
		default:
			goto parseMutation
		}
	}

parseMutation:
	if strings.TrimSpace(actor) == "" {
		return errors.New("queue-mutate: --actor is required")
	}
	if i >= len(args) {
		return errors.New("queue-mutate: mutation command is required")
	}
	mutation := args[i]
	rest := args[i+1:]

	jsonArgs := []string{}
	if includeJSON {
		jsonArgs = append(jsonArgs, "--json")
	}

	buildQueueWriteArgs := func(message string, brArgs []string) []string {
		qargs := make([]string, 0)
		if strings.TrimSpace(repo) != "" {
			qargs = append(qargs, "--repo", repo)
		}
		if strings.TrimSpace(scope) != "" {
			qargs = append(qargs, "--scope", scope)
		}
		if strings.TrimSpace(timeout) != "" {
			qargs = append(qargs, "--timeout", timeout)
		}
		if strings.TrimSpace(lockHelper) != "" {
			qargs = append(qargs, "--lock-helper", lockHelper)
		}
		qargs = append(qargs, "--actor", actor)
		if helperExplicit {
			qargs = append(qargs, "--message", message)
		}
		qargs = append(qargs, "--")
		qargs = append(qargs, brArgs...)
		return qargs
	}

	runMutation := func(message string, brArgs []string) error {
		qargs := buildQueueWriteArgs(message, brArgs)
		if helperExplicit {
			if strings.TrimSpace(helperPath) == "" {
				return errors.New("queue-mutate: queue-write helper path is empty")
			}
			if _, err := os.Stat(helperPath); err != nil {
				return fmt.Errorf("queue-mutate: queue-write helper is not executable: %s", helperPath)
			}
			return runPassthrough(append([]string{helperPath}, qargs...))
		}
		if strings.TrimSpace(lockHelper) != "" {
			return errors.New("queue-mutate: --lock-helper is not supported by go implementation yet")
		}
		return runQueueWriteMain(qargs, stdout, io.Discard)
	}

	switch mutation {
	case "claim":
		if len(rest) != 1 {
			return errors.New("queue-mutate: claim requires: claim <issue-id>")
		}
		issueID := rest[0]
		message := fmt.Sprintf("queue: claim %s by %s", issueID, actor)
		brArgs := append([]string{"br", "update", issueID, "--claim", "--actor", actor}, jsonArgs...)
		return runMutation(message, brArgs)
	case "comment":
		if len(rest) < 2 {
			return errors.New("queue-mutate: comment requires: comment <issue-id> (--file <path> | --stdin)")
		}
		issueID := rest[0]
		opts := rest[1:]
		commentFile := ""
		readStdin := false
		for j := 0; j < len(opts); j++ {
			t := opts[j]
			switch t {
			case "--file":
				if j+1 >= len(opts) {
					return errors.New("queue-mutate: --file requires an argument")
				}
				commentFile = opts[j+1]
				j++
			case "--stdin":
				readStdin = true
			default:
				return fmt.Errorf("queue-mutate: unsupported comment option: %s", t)
			}
		}
		if strings.TrimSpace(commentFile) != "" && readStdin {
			return errors.New("queue-mutate: choose exactly one of --file or --stdin")
		}
		tempFile := ""
		if readStdin {
			f, err := os.CreateTemp("", "orca-queue-mutate-comment-*.md")
			if err != nil {
				return fmt.Errorf("queue-mutate: create temp comment file: %w", err)
			}
			if _, err := io.Copy(f, os.Stdin); err != nil {
				_ = f.Close()
				_ = os.Remove(f.Name())
				return fmt.Errorf("queue-mutate: read stdin comment payload: %w", err)
			}
			_ = f.Close()
			tempFile = f.Name()
			commentFile = tempFile
			defer os.Remove(tempFile)
		}
		if strings.TrimSpace(commentFile) == "" {
			return errors.New("queue-mutate: comment payload is required via --file or --stdin")
		}
		if st, err := os.Stat(commentFile); err != nil || st.IsDir() {
			return fmt.Errorf("queue-mutate: comment file not found: %s", commentFile)
		}
		message := fmt.Sprintf("queue: comment %s by %s", issueID, actor)
		brArgs := append([]string{"br", "comments", "add", issueID, "--file", commentFile, "--author", actor, "--actor", actor}, jsonArgs...)
		return runMutation(message, brArgs)
	case "close":
		if len(rest) < 1 {
			return errors.New("queue-mutate: close requires: close <issue-id> [--reason <text>]")
		}
		issueID := rest[0]
		closeOpts := rest[1:]
		for j := 0; j < len(closeOpts); j++ {
			t := closeOpts[j]
			switch t {
			case "--reason":
				if j+1 >= len(closeOpts) {
					return errors.New("queue-mutate: --reason requires an argument")
				}
				return errors.New("queue-mutate: --reason is not supported by go implementation yet")
			default:
				return fmt.Errorf("queue-mutate: unsupported close option: %s", t)
			}
		}
		message := fmt.Sprintf("queue: close %s by %s", issueID, actor)
		brArgs := append([]string{"br", "close", issueID, "--actor", actor}, jsonArgs...)
		return runMutation(message, brArgs)
	case "dep-add":
		if len(rest) < 2 {
			return errors.New("queue-mutate: dep-add requires: dep-add <issue-id> <depends-on-id> [--type <dep-type>]")
		}
		issueID := rest[0]
		dependsOn := rest[1]
		depType := "blocks"
		depOpts := rest[2:]
		for j := 0; j < len(depOpts); j++ {
			t := depOpts[j]
			switch t {
			case "--type":
				if j+1 >= len(depOpts) {
					return errors.New("queue-mutate: --type requires an argument")
				}
				depType = depOpts[j+1]
				j++
			default:
				return fmt.Errorf("queue-mutate: unsupported dep-add option: %s", t)
			}
		}
		message := fmt.Sprintf("queue: dep-add %s -> %s by %s", issueID, dependsOn, actor)
		brArgs := append([]string{"br", "dep", "add", issueID, dependsOn, "--type", depType, "--actor", actor}, jsonArgs...)
		return runMutation(message, brArgs)
	default:
		return fmt.Errorf("queue-mutate: unsupported mutation form: %s", mutation)
	}
}

func runStop(args []string, stdout io.Writer, _ io.Writer) error {
	if len(args) > 0 {
		for _, arg := range args {
			switch arg {
			case "-h", "--help":
				_, _ = io.WriteString(stdout, "Usage:\n  stop\n")
				return nil
			default:
				return fmt.Errorf("stop: unknown option: %s", arg)
			}
		}
	}

	sessionPrefix := envOrDefault("SESSION_PREFIX", "orca-agent")
	sessions, err := tmux.ListSessions()
	if err != nil {
		return fmt.Errorf("stop: list tmux sessions: %w", err)
	}

	matched := make([]string, 0)
	for _, s := range sessions {
		if strings.HasPrefix(s.Name, sessionPrefix+"-") {
			matched = append(matched, s.Name)
		}
	}
	sort.Strings(matched)

	if len(matched) == 0 {
		fmt.Fprintf(stdout, "[stop] no sessions with prefix %s\n", sessionPrefix)
		fmt.Fprintln(stdout, "[stop] done")
		return nil
	}

	for _, name := range matched {
		fmt.Fprintf(stdout, "[stop] killing %s\n", name)
		if err := tmux.KillSession(name); err != nil {
			return fmt.Errorf("stop: kill %s: %w", name, err)
		}
	}
	fmt.Fprintln(stdout, "[stop] done")
	return nil
}

func runGCRunBranches(args []string, stdout io.Writer, _ io.Writer) error {
	apply := false
	baseRef := "main"
	repoPath := ""
	sessionPrefix := envOrDefault("SESSION_PREFIX", "orca-agent")

	for i := 0; i < len(args); i++ {
		tok := args[i]
		switch tok {
		case "--apply":
			apply = true
		case "--dry-run":
			apply = false
		case "--base":
			if i+1 >= len(args) {
				return errors.New("gc-run-branches: --base requires an argument")
			}
			baseRef = args[i+1]
			i++
		case "--repo":
			if i+1 >= len(args) {
				return errors.New("gc-run-branches: --repo requires an argument")
			}
			repoPath = args[i+1]
			i++
		case "-h", "--help":
			_, _ = io.WriteString(stdout, "Usage:\n  gc-run-branches [--apply] [--base REF] [--repo PATH]\n")
			return nil
		default:
			return fmt.Errorf("gc-run-branches: unknown argument: %s", tok)
		}
	}

	if strings.TrimSpace(repoPath) == "" {
		root, err := gitops.RepoRoot(".")
		if err != nil {
			return fmt.Errorf("gc-run-branches: resolve repo root: %w", err)
		}
		repoPath = root
	}

	if _, err := runGitOutput(repoPath, "rev-parse", "--is-inside-work-tree"); err != nil {
		return fmt.Errorf("gc-run-branches: --repo is not a git worktree: %s", repoPath)
	}
	if _, err := runGitOutput(repoPath, "rev-parse", "--verify", "--quiet", baseRef+"^{commit}"); err != nil {
		return fmt.Errorf("gc-run-branches: base ref does not resolve to a commit: %s", baseRef)
	}

	branchesRaw, err := runGitOutput(repoPath, "for-each-ref", "--format=%(refname:short)", "refs/heads/swarm/*-run-*")
	if err != nil {
		return fmt.Errorf("gc-run-branches: list run branches: %w", err)
	}
	runBranches := splitNonEmptyLines(branchesRaw)
	sort.Strings(runBranches)
	if len(runBranches) == 0 {
		fmt.Fprintln(stdout, "[gc-run-branches] no local run branches found (pattern: swarm/*-run-*)")
		return nil
	}

	worktreeBranchSet := map[string]struct{}{}
	if worktreeRaw, err := runGitOutput(repoPath, "worktree", "list", "--porcelain"); err == nil {
		for _, line := range splitNonEmptyLines(worktreeRaw) {
			if strings.HasPrefix(line, "branch ") {
				b := strings.TrimPrefix(line, "branch ")
				b = strings.TrimPrefix(b, "refs/heads/")
				if strings.TrimSpace(b) != "" {
					worktreeBranchSet[b] = struct{}{}
				}
			}
		}
	}

	activeAgentSet := map[string]struct{}{}
	activeSessionIDSet := map[string]struct{}{}
	if _, err := exec.LookPath("tmux"); err == nil {
		if tmuxRaw, _, err := runCommandWithExitCode("", "tmux", "ls", "-F", "#S"); err == nil {
			for _, sessionName := range splitNonEmptyLines(tmuxRaw) {
				prefix := sessionPrefix + "-"
				if !strings.HasPrefix(sessionName, prefix) {
					continue
				}
				suffix := strings.TrimPrefix(sessionName, prefix)
				if n, err := strconv.Atoi(suffix); err == nil {
					activeAgentSet[fmt.Sprintf("agent-%d", n)] = struct{}{}
					if envLine, _, err := runCommandWithExitCode("", "tmux", "show-environment", "-t", sessionName, "ORCA_SESSION_ID"); err == nil {
						if strings.HasPrefix(envLine, "ORCA_SESSION_ID=") {
							sid := strings.TrimPrefix(envLine, "ORCA_SESSION_ID=")
							if strings.TrimSpace(sid) != "" {
								activeSessionIDSet[sid] = struct{}{}
							}
						}
					}
				}
			}
		}
	}

	prunable := make([]string, 0)
	protected := make([]string, 0)
	unmerged := make([]string, 0)

	for _, branch := range runBranches {
		if _, ok := worktreeBranchSet[branch]; ok {
			protected = append(protected, branch+" :: active worktree checkout")
			continue
		}
		sessionProtected := false
		for sid := range activeSessionIDSet {
			if strings.Contains(branch, "-"+sid+"-") {
				protected = append(protected, branch+" :: active session "+sid)
				sessionProtected = true
				break
			}
		}
		if sessionProtected {
			continue
		}
		if strings.HasPrefix(branch, "swarm/agent-") {
			trimmed := strings.TrimPrefix(branch, "swarm/")
			idx := strings.Index(trimmed, "-run-")
			if idx > 0 {
				agentName := trimmed[:idx]
				if _, ok := activeAgentSet[agentName]; ok {
					protected = append(protected, branch+" :: active tmux session for "+agentName)
					continue
				}
			}
		}

		_, code, err := runCommandWithExitCode(repoPath, "git", "merge-base", "--is-ancestor", branch, baseRef)
		if err == nil && code == 0 {
			prunable = append(prunable, branch)
			continue
		}
		if code == 1 {
			unmerged = append(unmerged, branch+" :: not merged into "+baseRef)
			continue
		}
		if err != nil {
			return fmt.Errorf("gc-run-branches: merge-base check for %s: %w", branch, err)
		}
	}

	mode := "dry-run"
	if apply {
		mode = "apply"
	}
	fmt.Fprintf(stdout, "[gc-run-branches] mode: %s\n", mode)
	fmt.Fprintf(stdout, "[gc-run-branches] repo: %s\n", repoPath)
	fmt.Fprintf(stdout, "[gc-run-branches] base ref: %s\n", baseRef)
	fmt.Fprintf(stdout, "[gc-run-branches] scanned: %d\n", len(runBranches))
	fmt.Fprintf(stdout, "[gc-run-branches] prunable: %d\n", len(prunable))
	fmt.Fprintf(stdout, "[gc-run-branches] protected: %d\n", len(protected))
	fmt.Fprintf(stdout, "[gc-run-branches] unmerged: %d\n", len(unmerged))

	if len(prunable) > 0 {
		if apply {
			fmt.Fprintln(stdout, "[gc-run-branches] deleting prunable branches:")
			for _, branch := range prunable {
				if _, err := runGitOutput(repoPath, "branch", "-d", branch); err != nil {
					return fmt.Errorf("gc-run-branches: delete %s: %w", branch, err)
				}
				fmt.Fprintf(stdout, "  deleted %s\n", branch)
			}
		} else {
			fmt.Fprintln(stdout, "[gc-run-branches] branches that would be deleted:")
			for _, branch := range prunable {
				fmt.Fprintf(stdout, "  %s\n", branch)
			}
			fmt.Fprintln(stdout, "[gc-run-branches] rerun with --apply to delete.")
		}
	}
	if len(protected) > 0 {
		fmt.Fprintln(stdout, "[gc-run-branches] protected branches:")
		for _, line := range protected {
			fmt.Fprintf(stdout, "  %s\n", line)
		}
	}
	if len(unmerged) > 0 {
		fmt.Fprintln(stdout, "[gc-run-branches] skipped unmerged branches:")
		for _, line := range unmerged {
			fmt.Fprintf(stdout, "  %s\n", line)
		}
	}
	return nil
}

func runBootstrap(args []string, stdout io.Writer, stderr io.Writer) error {
	yes := false
	dryRun := false
	for _, arg := range args {
		switch arg {
		case "--yes":
			yes = true
		case "--dry-run":
			dryRun = true
		case "-h", "--help":
			_, _ = io.WriteString(stdout, "Usage:\n  bootstrap [--yes] [--dry-run]\n")
			return nil
		default:
			return fmt.Errorf("bootstrap: unexpected argument: %s", arg)
		}
	}

	cwd, err := os.Getwd()
	if err != nil {
		return fmt.Errorf("[bootstrap] error: resolve cwd: %w", err)
	}
	orcaHomePath, err := orcaHome()
	if err != nil {
		return fmt.Errorf("[bootstrap] error: %w", err)
	}

	if err := bootstrappkg.Run(bootstrappkg.Config{
		Yes:      yes,
		DryRun:   dryRun,
		Cwd:      cwd,
		OrcaHome: orcaHomePath,
		Stdout:   stdout,
		Stderr:   stderr,
	}); err != nil {
		return fmt.Errorf("[bootstrap] error: %s", err.Error())
	}
	return nil
}

func runDoctor(args []string, stdout io.Writer, stderr io.Writer) error {
	jsonOut := false
	for _, arg := range args {
		switch arg {
		case "--json":
			jsonOut = true
		case "-h", "--help":
			_, _ = io.WriteString(stdout, "Usage:\n  doctor [--json]\n")
			return nil
		default:
			return fmt.Errorf("doctor: unexpected argument: %s", arg)
		}
	}

	cwd, err := os.Getwd()
	if err != nil {
		return fmt.Errorf("doctor: resolve cwd: %w", err)
	}
	orcaHomePath, err := orcaHome()
	if err != nil {
		return err
	}

	res := doctorpkg.Run(doctorpkg.Config{Cwd: cwd, OrcaHome: orcaHomePath})
	if jsonOut {
		data, err := json.Marshal(res)
		if err != nil {
			return fmt.Errorf("doctor: marshal json: %w", err)
		}
		_, _ = stdout.Write(append(data, '\n'))
	} else {
		_, _ = io.WriteString(stdout, doctorpkg.RenderHuman(res))
	}
	_ = stderr
	if !res.OK {
		return &exitCodeError{Code: 1}
	}
	return nil
}

func runStatus(args []string, stdout io.Writer, stderr io.Writer) error {
	jsonOut := false
	for _, arg := range args {
		switch arg {
		case "--json":
			jsonOut = true
		case "-h", "--help":
			_, _ = io.WriteString(stdout, "Usage:\n  status [--json]\n")
			return nil
		default:
			return fmt.Errorf("status: unknown option: %s", arg)
		}
	}

	repoRoot, err := gitops.RepoRoot(".")
	if err != nil {
		return fmt.Errorf("status: resolve repo root: %w", err)
	}

	out, err := statuspkg.Collect(statuspkg.Config{
		RepoPath:      repoRoot,
		SessionPrefix: envOrDefault("SESSION_PREFIX", "orca-agent"),
	})
	if err != nil {
		return fmt.Errorf("status: %w", err)
	}

	if jsonOut {
		data, err := json.Marshal(out)
		if err != nil {
			return fmt.Errorf("status: marshal json: %w", err)
		}
		_, _ = stdout.Write(append(data, '\n'))
		return nil
	}

	_, _ = io.WriteString(stdout, statuspkg.RenderHuman(out))
	_ = stderr
	return nil
}

func runScript(script string, args []string) error {
	home, err := orcaHome()
	if err != nil {
		return err
	}
	path := filepath.Join(home, script)
	if _, err := os.Stat(path); err != nil {
		return fmt.Errorf("script not found for delegated command: %s", path)
	}
	return runPassthrough(append([]string{path}, args...))
}

func runPassthrough(args []string) error {
	if len(args) == 0 {
		return errors.New("missing command")
	}
	cmd := exec.Command(args[0], args[1:]...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			return &exitCodeError{Code: ee.ExitCode()}
		}
		return err
	}
	return nil
}

func loadReadyIssues(repoRoot string, readyJSONPath string) ([]queue.Issue, error) {
	if strings.TrimSpace(readyJSONPath) != "" {
		data, err := os.ReadFile(readyJSONPath)
		if err != nil {
			return nil, err
		}
		var issues []queue.Issue
		if err := json.Unmarshal(data, &issues); err != nil {
			return nil, err
		}
		return issues, nil
	}

	primaryRepo := strings.TrimSpace(os.Getenv("ORCA_PRIMARY_REPO"))
	if primaryRepo == "" {
		primaryRepo = repoRoot
	}

	client, err := queue.New(queue.Config{RepoPath: primaryRepo})
	if err != nil {
		return nil, err
	}
	return client.ReadReady()
}

func loadIssueLabels(path string) (map[string][]string, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	labelsByID := map[string][]string{}
	scanner := bufio.NewScanner(file)
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
			return nil, fmt.Errorf("parse issues jsonl line: %w", err)
		}
		if strings.TrimSpace(row.ID) == "" {
			continue
		}
		labels := make([]string, 0, len(row.Labels))
		for _, label := range row.Labels {
			if strings.TrimSpace(label) == "" {
				continue
			}
			labels = append(labels, label)
		}
		labelsByID[row.ID] = labels
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return labelsByID, nil
}

func loadDepIssues(path string) ([]depsanity.Issue, int, int, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, 0, 0, err
	}
	defer file.Close()

	issues := make([]depsanity.Issue, 0)
	issueCount := 0
	depCount := 0

	scanner := bufio.NewScanner(file)
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
			return nil, 0, 0, fmt.Errorf("parse issues jsonl line: %w", err)
		}

		deps := make([]depsanity.Dependency, 0, len(row.Dependencies))
		for _, dep := range row.Dependencies {
			deps = append(deps, depsanity.Dependency{
				IssueID:     dep.IssueID,
				DependsOnID: dep.DependsOnID,
				Type:        dep.Type,
			})
			depCount++
		}

		issues = append(issues, depsanity.Issue{
			ID:           row.ID,
			Status:       row.Status,
			Dependencies: deps,
		})
	}
	if err := scanner.Err(); err != nil {
		return nil, 0, 0, err
	}

	return issues, issueCount, depCount, nil
}

func resolveBRBinary() string {
	if configured := strings.TrimSpace(os.Getenv("ORCA_BR_REAL_BIN")); configured != "" {
		return configured
	}
	return "br"
}

func writeJSON(w io.Writer, value any) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	_, err = w.Write(append(data, '\n'))
	return err
}

func classifyBRCommand(args []string) string {
	if len(args) == 0 {
		return "invalid"
	}
	primary := args[0]
	secondary := ""
	if len(args) >= 2 {
		secondary = args[1]
	}

	switch primary {
	case "-h", "--help", "help", "--version", "version":
		return "read_only"
	case "ready", "list", "show", "doctor":
		return "read_only"
	case "dep":
		if secondary == "list" {
			return "read_only"
		}
		return "mutation"
	case "comments":
		if secondary == "list" {
			return "read_only"
		}
		return "mutation"
	case "config":
		if secondary == "get" {
			return "read_only"
		}
		return "mutation"
	case "sync":
		for _, token := range args[1:] {
			if token == "--status" {
				return "read_only"
			}
		}
		return "mutation"
	default:
		return "mutation"
	}
}

func extractActorFlag(args []string) string {
	for i := 0; i < len(args); i++ {
		token := args[i]
		if token == "--actor" {
			if i+1 < len(args) {
				return args[i+1]
			}
			return ""
		}
		if strings.HasPrefix(token, "--actor=") {
			return strings.TrimPrefix(token, "--actor=")
		}
	}
	return ""
}

func hasFlag(args []string, flags ...string) bool {
	for _, token := range args {
		for _, flagName := range flags {
			if token == flagName || strings.HasPrefix(token, flagName+"=") {
				return true
			}
		}
	}
	return false
}

func hasArg(args []string, want string) bool {
	for _, token := range args {
		if token == want {
			return true
		}
	}
	return false
}

func valueAfterFlag(args []string, flags ...string) string {
	for i := 0; i < len(args); i++ {
		token := args[i]
		for _, flagName := range flags {
			if token == flagName {
				if i+1 < len(args) {
					return args[i+1]
				}
				return ""
			}
			if strings.HasPrefix(token, flagName+"=") {
				return strings.TrimPrefix(token, flagName+"=")
			}
		}
	}
	return ""
}

func isCommentsAdd(args []string) bool {
	return len(args) >= 2 && args[0] == "comments" && args[1] == "add"
}

func valueOrDefault(v, fallback string) string {
	if strings.TrimSpace(v) == "" {
		return fallback
	}
	return v
}

func appendSessionLogLine(path string, line string) error {
	if strings.TrimSpace(path) == "" {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = fmt.Fprintf(f, "[%s] %s\n", time.Now().Format(time.RFC3339), line)
	return err
}

func runTimestamp(t time.Time) string {
	utc := t.UTC()
	return fmt.Sprintf("%s%09dZ", utc.Format("20060102T150405"), utc.Nanosecond())
}

func prepareRunBranch(worktreePath, agentName, sessionID string, runNumber int, ts string, baseRefOverride string, logWriter io.Writer) (string, error) {
	_ = runGitQuiet(worktreePath, "fetch", "origin", "main")

	baseRef, err := selectRunBaseRef(worktreePath, baseRefOverride)
	if err != nil {
		return "", err
	}

	statusOut, err := runGitOutput(worktreePath, "status", "--short")
	if err != nil {
		return "", err
	}
	if strings.TrimSpace(statusOut) != "" {
		if logWriter != nil {
			_, _ = fmt.Fprintln(logWriter, "worktree has uncommitted changes and cannot switch base ref")
		}
		return "", errors.New("worktree has uncommitted changes")
	}

	branchName := fmt.Sprintf("swarm/%s-run-%s-%04d-%s", agentName, sessionID, runNumber, ts)
	if !isValidBranchName(branchName) {
		return "", fmt.Errorf("generated invalid run branch name: %s", branchName)
	}

	if refExists(worktreePath, "refs/heads/"+branchName) {
		return "", fmt.Errorf("run branch already exists locally: %s", branchName)
	}
	if refExists(worktreePath, "refs/remotes/origin/"+branchName) {
		return "", fmt.Errorf("run branch already exists on origin: %s", branchName)
	}

	if _, err := runGitOutput(worktreePath, "checkout", "-b", branchName, baseRef); err != nil {
		return "", err
	}
	return branchName, nil
}

func restoreWorktreeQueueArtifacts(worktreePath string) error {
	statusOut, err := runGitOutput(worktreePath, "status", "--short", "--", ".beads/")
	if err != nil {
		return err
	}
	if strings.TrimSpace(statusOut) == "" {
		return nil
	}

	if _, err := runGitOutput(worktreePath, "restore", "--staged", "--worktree", ".beads/"); err != nil {
		return err
	}
	post, err := runGitOutput(worktreePath, "status", "--short", "--", ".beads/")
	if err != nil {
		return err
	}
	if strings.TrimSpace(post) != "" {
		return errors.New(".beads remained dirty after restore")
	}
	return nil
}

func selectRunBaseRef(worktreePath, override string) (string, error) {
	if strings.TrimSpace(override) != "" {
		if !refExists(worktreePath, override+"^{commit}") {
			return "", fmt.Errorf("ORCA_BASE_REF does not resolve to a commit: %s", override)
		}
		return override, nil
	}

	_, _ = warnIfMainRefsDiverge(worktreePath)

	if refExists(worktreePath, "refs/heads/main") {
		return "main", nil
	}
	if refExists(worktreePath, "refs/remotes/origin/main") {
		return "origin/main", nil
	}
	branch, err := gitops.CurrentBranch(worktreePath)
	if err == nil && strings.TrimSpace(branch) != "" {
		return branch, nil
	}
	return "", errors.New("unable to determine run base ref")
}

func warnIfMainRefsDiverge(worktreePath string) (string, error) {
	if !refExists(worktreePath, "refs/heads/main") || !refExists(worktreePath, "refs/remotes/origin/main") {
		return "", nil
	}
	ahead, behind, err := gitops.AheadBehind(worktreePath, "main", "origin/main")
	if err != nil {
		return "", err
	}
	if ahead == 0 && behind == 0 {
		return "", nil
	}
	return fmt.Sprintf("local main and origin/main differ (local ahead %d, behind %d); defaulting to main", ahead, behind), nil
}

func refExists(worktreePath, ref string) bool {
	cmd := exec.Command("git", "rev-parse", "--verify", "--quiet", ref)
	cmd.Dir = worktreePath
	return cmd.Run() == nil
}

func isValidBranchName(branch string) bool {
	if branch == "" {
		return false
	}
	for _, r := range branch {
		if (r >= 'A' && r <= 'Z') || (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			continue
		}
		switch r {
		case '.', '_', '/', '-':
			continue
		default:
			return false
		}
	}
	return true
}

func runCommandWithExitCode(dir, name string, args ...string) (string, int, error) {
	cmd := exec.Command(name, args...)
	if strings.TrimSpace(dir) != "" {
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
	return trimmed, exitCode, fmt.Errorf("%w: %s", err, trimmed)
}

func splitNonEmptyLines(raw string) []string {
	parts := strings.Split(raw, "\n")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		v := strings.TrimSpace(p)
		if v == "" {
			continue
		}
		out = append(out, v)
	}
	return out
}

func runGitOutput(dir string, args ...string) (string, error) {
	out, _, err := runCommandWithExitCode(dir, "git", args...)
	if err != nil {
		return "", err
	}
	return out, nil
}

func runGitQuiet(dir string, args ...string) error {
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	return cmd.Run()
}

func buildLoopEnv(
	inv loop.RunInvocation,
	agentName string,
	sessionID string,
	worktreePath string,
	assignmentMode string,
	assignedIssueID string,
	primaryRepo string,
	withLockPath string,
	queueReadMainPath string,
	queueWriteMainPath string,
	mergeMainPath string,
	brGuardPath string,
	lockScope string,
	lockTimeoutSeconds int,
	guardBinDir string,
) []string {
	env := append([]string(nil), os.Environ()...)
	env = append(env,
		"AGENT_NAME="+agentName,
		"AGENT_SESSION_ID="+sessionID,
		"WORKTREE="+worktreePath,
		"ORCA_RUN_SUMMARY_PATH="+inv.Paths.SummaryJSON,
		"ORCA_RUN_LOG_PATH="+inv.Paths.RunLog,
		"ORCA_RUN_NUMBER="+strconv.Itoa(inv.RunNumber),
		"ORCA_SESSION_ID="+sessionID,
		"ORCA_AGENT_NAME="+agentName,
		"ORCA_ASSIGNMENT_MODE="+assignmentMode,
		"ORCA_ASSIGNED_ISSUE_ID="+assignedIssueID,
		"ORCA_PRIMARY_REPO="+primaryRepo,
		"ORCA_WITH_LOCK_PATH="+withLockPath,
		"ORCA_QUEUE_READ_MAIN_PATH="+queueReadMainPath,
		"ORCA_QUEUE_WRITE_MAIN_PATH="+queueWriteMainPath,
		"ORCA_MERGE_MAIN_PATH="+mergeMainPath,
		"ORCA_BR_GUARD_PATH="+brGuardPath,
		"ORCA_LOCK_SCOPE="+lockScope,
		"ORCA_LOCK_TIMEOUT_SECONDS="+strconv.Itoa(lockTimeoutSeconds),
		"ORCA_BR_GUARD_MODE="+envOrDefault("ORCA_BR_GUARD_MODE", "enforce"),
		"ORCA_ALLOW_UNSAFE_BR_MUTATIONS="+envOrDefault("ORCA_ALLOW_UNSAFE_BR_MUTATIONS", "0"),
	)

	if brReal := strings.TrimSpace(os.Getenv("ORCA_BR_REAL_BIN")); brReal != "" {
		env = append(env, "ORCA_BR_REAL_BIN="+brReal)
	}

	if strings.TrimSpace(guardBinDir) != "" {
		env = append(env, "PATH="+guardBinDir+string(os.PathListSeparator)+os.Getenv("PATH"))
	}
	return env
}

func issuePlaceholder(assigned string) string {
	if strings.TrimSpace(assigned) == "" {
		return "agent-selected"
	}
	return assigned
}

func sessionDatePath(sessionID string, fallback time.Time) string {
	idx := strings.LastIndex(sessionID, "-")
	stamp := ""
	if idx >= 0 && idx+1 < len(sessionID) {
		stamp = sessionID[idx+1:]
	} else {
		stamp = sessionID
	}
	if len(stamp) >= 8 {
		prefix := stamp[:8]
		allDigits := true
		for _, r := range prefix {
			if r < '0' || r > '9' {
				allDigits = false
				break
			}
		}
		if allDigits {
			return fmt.Sprintf("%s/%s/%s", prefix[0:4], prefix[4:6], prefix[6:8])
		}
	}
	return fallback.UTC().Format("2006/01/02")
}

func envOrDefault(key, fallback string) string {
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		return fallback
	}
	return v
}

func envIntOrDefault(key string, fallback int) int {
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		return fallback
	}
	n, err := strconv.Atoi(v)
	if err != nil || n <= 0 {
		return fallback
	}
	return n
}

func envNonNegativeIntOrDefault(key string, fallback int) int {
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		return fallback
	}
	n, err := strconv.Atoi(v)
	if err != nil || n < 0 {
		return fallback
	}
	return n
}

func orcaHome() (string, error) {
	if home := strings.TrimSpace(os.Getenv("ORCA_HOME")); home != "" {
		return home, nil
	}
	exe, err := os.Executable()
	if err != nil {
		return "", fmt.Errorf("resolve executable path: %w", err)
	}
	return filepath.Dir(exe), nil
}

type exitCodeError struct {
	Code int
}

func (e *exitCodeError) Error() string {
	return fmt.Sprintf("exit code %d", e.Code)
}
