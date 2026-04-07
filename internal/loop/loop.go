// Package loop contains core agent-loop behaviors and pure helpers.
package loop

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/soenderby/orca/internal/model"
)

const (
	SummaryParseParsed      = "parsed"
	SummaryParseMissing     = "missing"
	SummaryParseInvalidJSON = "invalid_json"

	SummarySchemaValid      = "valid"
	SummarySchemaInvalid    = "invalid"
	SummarySchemaNotChecked = "not_checked"
)

// SummaryResult captures parsed + validated summary metadata.
type SummaryResult struct {
	Summary           *model.Summary
	ParseStatus       string
	SchemaStatus      string
	SchemaReasonCodes []string
	LoopAction        string
	LoopActionReason  string
}

// DrainDecision captures no-work drain policy outcome.
type DrainDecision struct {
	ConsecutiveNoWork int
	Stop              bool
	LoopAction        string
	LoopActionReason  string
	Reason            string
}

// RunPaths are per-run artifact paths.
type RunPaths struct {
	SummaryJSON      string
	RunLog           string
	SummaryMarkdown  string
	AgentLastMessage string
}

// RunInvocation is the request to execute one agent run.
type RunInvocation struct {
	RunNumber int
	Paths     RunPaths
}

// ExecutionResult describes one executor run outcome.
type ExecutionResult struct {
	ExitCode        int
	DurationSeconds int
	FailureReason   string
	StopRequested   bool
}

// Executor executes one agent run.
type Executor interface {
	Execute(invocation RunInvocation) (ExecutionResult, error)
}

// ExecutorFunc is a functional adapter for Executor.
type ExecutorFunc func(invocation RunInvocation) (ExecutionResult, error)

// Execute implements Executor.
func (f ExecutorFunc) Execute(invocation RunInvocation) (ExecutionResult, error) {
	return f(invocation)
}

// RunConfig configures one RunOnce iteration.
type RunConfig struct {
	AgentName       string
	SessionID       string
	RunNumber       int
	HarnessVersion  string
	AssignmentMode  string // assigned | self-select
	AssignedIssueID string
	ModeID          string
	ApproachSource  string
	ApproachSHA256  string
	Paths           RunPaths
	Executor        Executor
	Now             func() time.Time
}

// RunOutcome is the interpreted result of one RunOnce iteration.
type RunOutcome struct {
	SummaryResult *SummaryResult
	ExitCode      int
	DurationSecs  int
	Result        string
	Reason        string
	IssueID       string

	LoopAction       string
	LoopActionReason string
	StopRequested    bool

	PlannedAssignedIssue *string
	AssignmentSource     string
	AssignmentOutcome    string
	AssignmentMatch      *bool

	TokensUsed        *int
	TokensParseStatus string
}

// LoopConfig configures the high-level loop behavior.
type LoopConfig struct {
	AgentName       string
	SessionID       string
	HarnessVersion  string
	AssignmentMode  string // assigned | self-select
	AssignedIssueID string
	ModeID          string
	ApproachSource  string
	ApproachSHA256  string

	MaxRuns          int // 0 = unbounded
	RunSleep         time.Duration
	NoWorkDrainMode  string // drain | watch
	NoWorkRetryLimit int

	MetricsPath string
	PathsForRun func(runNumber int) RunPaths
	Executor    Executor

	Now   func() time.Time
	Sleep func(time.Duration)

	OnRunComplete func(outcome RunOutcome, metrics model.MetricsRow)
}

// ParseAndValidateSummary parses summary JSON and validates schema rules.
func ParseAndValidateSummary(path string, assignedIssueID string) (*SummaryResult, error) {
	res := &SummaryResult{
		ParseStatus:      SummaryParseMissing,
		SchemaStatus:     SummarySchemaNotChecked,
		LoopAction:       model.SummaryLoopActionContinue,
		LoopActionReason: "",
	}

	info, err := os.Stat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return res, nil
		}
		return nil, fmt.Errorf("stat summary file: %w", err)
	}
	if info.Size() == 0 {
		return res, nil
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read summary file: %w", err)
	}

	var summary model.Summary
	if err := json.Unmarshal(raw, &summary); err != nil {
		res.ParseStatus = SummaryParseInvalidJSON
		return res, nil
	}

	res.ParseStatus = SummaryParseParsed
	res.Summary = &summary
	res.LoopAction = model.SummaryLoopActionContinue
	if summary.LoopAction == model.SummaryLoopActionContinue || summary.LoopAction == model.SummaryLoopActionStop {
		res.LoopAction = summary.LoopAction
	}
	res.LoopActionReason = summary.LoopActionReason

	codes := model.ValidateSummaryForAssignment(&summary, assignedIssueID)
	if len(codes) > 0 {
		res.SchemaStatus = SummarySchemaInvalid
		res.SchemaReasonCodes = append([]string(nil), codes...)
		// Fail-closed: invalid schema cannot request loop stop.
		res.LoopAction = model.SummaryLoopActionContinue
		res.LoopActionReason = ""
		return res, nil
	}

	res.SchemaStatus = SummarySchemaValid
	return res, nil
}

// AppendMetrics appends one metrics row to a JSONL file.
func AppendMetrics(path string, row model.MetricsRow) error {
	if strings.TrimSpace(path) == "" {
		return fmt.Errorf("metrics path is required")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("create metrics directory: %w", err)
	}

	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return fmt.Errorf("open metrics file: %w", err)
	}
	defer f.Close()

	data, err := json.Marshal(row)
	if err != nil {
		return fmt.Errorf("marshal metrics row: %w", err)
	}

	w := bufio.NewWriter(f)
	if _, err := w.Write(data); err != nil {
		return fmt.Errorf("write metrics row: %w", err)
	}
	if err := w.WriteByte('\n'); err != nil {
		return fmt.Errorf("write metrics newline: %w", err)
	}
	if err := w.Flush(); err != nil {
		return fmt.Errorf("flush metrics writer: %w", err)
	}
	return nil
}

// ApplyNoWorkDrainPolicy evaluates drain/watch behavior for a run result.
func ApplyNoWorkDrainPolicy(result string, consecutiveNoWork int, mode string, retryLimit int) (DrainDecision, error) {
	if mode != "drain" && mode != "watch" {
		return DrainDecision{}, fmt.Errorf("invalid drain mode %q", mode)
	}
	if retryLimit < 0 {
		retryLimit = 0
	}

	decision := DrainDecision{
		ConsecutiveNoWork: consecutiveNoWork,
		LoopAction:        model.SummaryLoopActionContinue,
	}

	if result != model.SummaryResultNoWork {
		decision.ConsecutiveNoWork = 0
		return decision, nil
	}

	decision.ConsecutiveNoWork = consecutiveNoWork + 1
	if mode == "watch" {
		return decision, nil
	}

	if decision.ConsecutiveNoWork > retryLimit {
		decision.Stop = true
		decision.LoopAction = model.SummaryLoopActionStop
		decision.LoopActionReason = fmt.Sprintf(
			"queue-drained-after-%d-consecutive-no_work-runs",
			decision.ConsecutiveNoWork,
		)
		decision.Reason = decision.LoopActionReason
	}

	return decision, nil
}

// RunOnce executes one iteration and interprets the produced summary.
func RunOnce(cfg RunConfig) (RunOutcome, error) {
	if cfg.Executor == nil {
		return RunOutcome{}, errors.New("loop executor is required")
	}
	if cfg.RunNumber <= 0 {
		return RunOutcome{}, fmt.Errorf("run number must be >= 1, got %d", cfg.RunNumber)
	}
	if strings.TrimSpace(cfg.Paths.SummaryJSON) == "" {
		return RunOutcome{}, errors.New("summary json path is required")
	}
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	if cfg.AssignmentMode == "" {
		cfg.AssignmentMode = "self-select"
	}

	if err := os.MkdirAll(filepath.Dir(cfg.Paths.SummaryJSON), 0o755); err != nil {
		return RunOutcome{}, fmt.Errorf("create summary directory: %w", err)
	}

	execResult, err := cfg.Executor.Execute(RunInvocation{
		RunNumber: cfg.RunNumber,
		Paths:     cfg.Paths,
	})
	if err != nil {
		return RunOutcome{}, fmt.Errorf("execute run %d: %w", cfg.RunNumber, err)
	}

	summaryRes, err := ParseAndValidateSummary(cfg.Paths.SummaryJSON, cfg.AssignedIssueID)
	if err != nil {
		return RunOutcome{}, err
	}

	result, reason := determineRunResult(execResult.ExitCode, summaryRes)
	issueID := ""
	if summaryRes.Summary != nil {
		issueID = summaryRes.Summary.IssueID
	}

	if strings.TrimSpace(execResult.FailureReason) != "" {
		result = model.SummaryResultFailed
		reason = execResult.FailureReason
	}

	tokensUsed, tokensParseStatus := extractTokensUsedFromRunLog(cfg.Paths.RunLog)

	planned, source, assignmentOutcome, assignmentMatch := assignmentTelemetry(
		cfg.AssignmentMode,
		cfg.AssignedIssueID,
		issueID,
	)

	outcome := RunOutcome{
		SummaryResult:        summaryRes,
		ExitCode:             execResult.ExitCode,
		DurationSecs:         execResult.DurationSeconds,
		Result:               result,
		Reason:               reason,
		IssueID:              issueID,
		LoopAction:           summaryRes.LoopAction,
		LoopActionReason:     summaryRes.LoopActionReason,
		PlannedAssignedIssue: planned,
		AssignmentSource:     source,
		AssignmentOutcome:    assignmentOutcome,
		AssignmentMatch:      assignmentMatch,
		StopRequested:        (summaryRes.ParseStatus == SummaryParseParsed && summaryRes.LoopAction == model.SummaryLoopActionStop) || execResult.StopRequested,
		TokensUsed:           tokensUsed,
		TokensParseStatus:    tokensParseStatus,
	}

	if strings.TrimSpace(execResult.FailureReason) != "" {
		outcome.LoopAction = model.SummaryLoopActionStop
		outcome.LoopActionReason = execResult.FailureReason
	}

	return outcome, nil
}

// Loop runs the iteration loop with drain/watch stop policy.
func Loop(cfg LoopConfig) error {
	if cfg.Executor == nil {
		return errors.New("loop executor is required")
	}
	if cfg.PathsForRun == nil {
		return errors.New("paths-for-run callback is required")
	}
	if cfg.NoWorkDrainMode == "" {
		cfg.NoWorkDrainMode = "drain"
	}
	if cfg.NoWorkDrainMode != "drain" && cfg.NoWorkDrainMode != "watch" {
		return fmt.Errorf("invalid no-work drain mode %q", cfg.NoWorkDrainMode)
	}
	if cfg.AssignmentMode == "" {
		cfg.AssignmentMode = "self-select"
	}
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	if cfg.Sleep == nil {
		cfg.Sleep = time.Sleep
	}

	consecutiveNoWork := 0
	runsCompleted := 0

	for {
		if cfg.MaxRuns > 0 && runsCompleted >= cfg.MaxRuns {
			break
		}

		runNumber := runsCompleted + 1
		paths := cfg.PathsForRun(runNumber)
		outcome, err := RunOnce(RunConfig{
			AgentName:       cfg.AgentName,
			SessionID:       cfg.SessionID,
			RunNumber:       runNumber,
			HarnessVersion:  cfg.HarnessVersion,
			AssignmentMode:  cfg.AssignmentMode,
			AssignedIssueID: cfg.AssignedIssueID,
			ModeID:          cfg.ModeID,
			ApproachSource:  cfg.ApproachSource,
			ApproachSHA256:  cfg.ApproachSHA256,
			Paths:           paths,
			Executor:        cfg.Executor,
			Now:             cfg.Now,
		})
		if err != nil {
			return err
		}

		if !outcome.StopRequested {
			decision, err := ApplyNoWorkDrainPolicy(
				outcome.Result,
				consecutiveNoWork,
				cfg.NoWorkDrainMode,
				cfg.NoWorkRetryLimit,
			)
			if err != nil {
				return err
			}
			consecutiveNoWork = decision.ConsecutiveNoWork

			if decision.Stop {
				outcome.StopRequested = true
				outcome.LoopAction = decision.LoopAction
				outcome.LoopActionReason = decision.LoopActionReason
				outcome.Reason = decision.Reason
			}
		} else if outcome.Result != model.SummaryResultNoWork {
			consecutiveNoWork = 0
		}

		metrics := buildMetricsRow(cfg, runNumber, paths, outcome)
		if strings.TrimSpace(cfg.MetricsPath) != "" {
			if err := AppendMetrics(cfg.MetricsPath, metrics); err != nil {
				return err
			}
		}
		if cfg.OnRunComplete != nil {
			cfg.OnRunComplete(outcome, metrics)
		}

		runsCompleted++
		if outcome.StopRequested {
			break
		}
		if cfg.MaxRuns > 0 && runsCompleted >= cfg.MaxRuns {
			break
		}
		if cfg.RunSleep > 0 {
			cfg.Sleep(cfg.RunSleep)
		}
	}

	return nil
}

func determineRunResult(exitCode int, summaryRes *SummaryResult) (string, string) {
	result := model.SummaryResultFailed
	reason := fmt.Sprintf("agent-exit-%d", exitCode)

	switch summaryRes.ParseStatus {
	case SummaryParseMissing:
		return result, "summary-missing"
	case SummaryParseInvalidJSON:
		return result, "summary-invalid-json"
	}

	if summaryRes.SchemaStatus == SummarySchemaInvalid {
		if len(summaryRes.SchemaReasonCodes) > 0 {
			return result, "summary-schema-invalid:" + summaryRes.SchemaReasonCodes[0]
		}
		return result, "summary-schema-invalid"
	}

	if summaryRes.Summary != nil && strings.TrimSpace(summaryRes.Summary.Result) != "" {
		result = summaryRes.Summary.Result
	} else if exitCode == 0 {
		return model.SummaryResultFailed, "summary-result-missing"
	}

	if summaryRes.ParseStatus == SummaryParseParsed && summaryRes.LoopAction == model.SummaryLoopActionStop {
		if strings.TrimSpace(summaryRes.LoopActionReason) != "" {
			reason = summaryRes.LoopActionReason
		} else {
			reason = "agent-requested-stop"
		}
	}

	return result, reason
}

func assignmentTelemetry(mode, assignedIssueID, summaryIssueID string) (*string, string, string, *bool) {
	if mode == "assigned" {
		source := "planner"
		if strings.TrimSpace(assignedIssueID) == "" {
			return nil, source, "unassigned", nil
		}

		planned := &assignedIssueID
		if summaryIssueID == assignedIssueID {
			matched := true
			return planned, source, "matched", &matched
		}
		matched := false
		return planned, source, "mismatch", &matched
	}

	return nil, "self-select", "unassigned", nil
}

func extractTokensUsedFromRunLog(path string) (*int, string) {
	if strings.TrimSpace(path) == "" {
		return nil, "missing"
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, "missing"
	}
	lines := strings.Split(string(raw), "\n")
	for i := 0; i < len(lines)-1; i++ {
		if strings.TrimSpace(lines[i]) != "tokens used" {
			continue
		}
		candidate := strings.TrimSpace(lines[i+1])
		if candidate == "" {
			return nil, "missing"
		}
		candidate = strings.ReplaceAll(candidate, ",", "")
		candidate = strings.ReplaceAll(candidate, " ", "")
		n, err := strconv.Atoi(candidate)
		if err != nil {
			return nil, "parse_error"
		}
		return &n, "ok"
	}
	return nil, "missing"
}

func defaultTokensParseStatus(v string) string {
	if strings.TrimSpace(v) == "" {
		return "missing"
	}
	return v
}

// SummaryMarkdownInput describes one compact summary.md rendering.
type SummaryMarkdownInput struct {
	Timestamp                time.Time
	AgentName                string
	SessionID                string
	RunNumber                int
	ExitCode                 int
	DurationSeconds          int
	Result                   string
	Reason                   string
	SummaryParseStatus       string
	SummarySchemaStatus      string
	SummarySchemaReasonCodes []string
	LoopAction               string
	LoopActionReason         string
	IssueID                  string
	AssignedIssueID          string
	AssignmentMatch          *bool
	PlannedAssignedIssue     *string
	AssignmentSource         string
	AssignmentOutcome        string
	SummaryResult            *string
	SummaryIssueStatus       *string
	SummaryMerged            *bool
	SummaryDiscoveryCount    *int
	SummaryDiscoveryIDs      []string
	TokensUsed               *int
	TokensParseStatus        string
	ModeID                   *string
	ApproachSource           *string
	ApproachSHA256           *string
	RunLogPath               string
	SummaryJSONPath          string
	SummaryMarkdownPath      string
	LastMessagePath          string
}

// WriteRunSummaryMarkdown writes compact summary markdown artifact.
func WriteRunSummaryMarkdown(path string, in SummaryMarkdownInput) error {
	if strings.TrimSpace(path) == "" {
		return errors.New("summary markdown path is required")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("create summary markdown directory: %w", err)
	}

	fmtStr := func(v *string, fallback string) string {
		if v == nil || strings.TrimSpace(*v) == "" {
			return fallback
		}
		return *v
	}
	fmtBoolPtr := func(v *bool, fallback string) string {
		if v == nil {
			return fallback
		}
		if *v {
			return "true"
		}
		return "false"
	}
	modeID := fmtStr(in.ModeID, "none")
	approachSource := fmtStr(in.ApproachSource, "none")
	approachSHA := fmtStr(in.ApproachSHA256, "none")
	tokens := "n/a"
	if in.TokensUsed != nil {
		tokens = strconv.Itoa(*in.TokensUsed)
	}

	var b strings.Builder
	b.WriteString("# Orca Run Summary\n\n")
	b.WriteString("- Timestamp: " + in.Timestamp.Format(time.RFC3339) + "\n")
	b.WriteString("- Agent: " + in.AgentName + "\n")
	b.WriteString("- Session: " + in.SessionID + "\n")
	b.WriteString("- Run: " + strconv.Itoa(in.RunNumber) + "\n")
	b.WriteString("- Exit Code: " + strconv.Itoa(in.ExitCode) + "\n")
	b.WriteString("- Duration Seconds: " + strconv.Itoa(in.DurationSeconds) + "\n")
	b.WriteString("- Result: " + in.Result + "\n")
	b.WriteString("- Reason: " + in.Reason + "\n")
	b.WriteString("- Summary JSON: " + in.SummaryJSONPath + "\n")
	b.WriteString("- Summary Parse Status: " + in.SummaryParseStatus + "\n")
	b.WriteString("- Summary Schema Status: " + in.SummarySchemaStatus + "\n")
	if len(in.SummarySchemaReasonCodes) > 0 {
		b.WriteString("- Summary Schema Reason Codes: " + strings.Join(in.SummarySchemaReasonCodes, ",") + "\n")
	}
	b.WriteString("- Loop Action: " + in.LoopAction + "\n")
	if strings.TrimSpace(in.LoopActionReason) != "" {
		b.WriteString("- Loop Action Reason: " + in.LoopActionReason + "\n")
	}
	if strings.TrimSpace(in.IssueID) != "" {
		b.WriteString("- Issue: " + in.IssueID + "\n")
	}
	if strings.TrimSpace(in.AssignedIssueID) != "" {
		b.WriteString("- Assigned Issue: " + in.AssignedIssueID + "\n")
		if in.AssignmentMatch != nil {
			b.WriteString("- Assigned Issue Match: " + fmtBoolPtr(in.AssignmentMatch, "") + "\n")
		}
	}
	if in.PlannedAssignedIssue != nil {
		b.WriteString("- Planned Assigned Issue: " + *in.PlannedAssignedIssue + "\n")
	}
	if strings.TrimSpace(in.AssignmentSource) != "" {
		b.WriteString("- Assignment Source: " + in.AssignmentSource + "\n")
	}
	if strings.TrimSpace(in.AssignmentOutcome) != "" {
		b.WriteString("- Assignment Outcome: " + in.AssignmentOutcome + "\n")
	}
	if in.SummaryResult != nil {
		b.WriteString("- Summary Result: " + *in.SummaryResult + "\n")
	}
	if in.SummaryIssueStatus != nil {
		b.WriteString("- Summary Issue Status: " + *in.SummaryIssueStatus + "\n")
	}
	if in.SummaryMerged != nil {
		b.WriteString("- Summary Merged: " + fmtBoolPtr(in.SummaryMerged, "") + "\n")
	}
	if in.SummaryDiscoveryCount != nil {
		b.WriteString("- Summary Discovery Count: " + strconv.Itoa(*in.SummaryDiscoveryCount) + "\n")
	}
	if len(in.SummaryDiscoveryIDs) > 0 {
		b.WriteString("- Summary Discovery IDs: " + strings.Join(in.SummaryDiscoveryIDs, ",") + "\n")
	}
	b.WriteString("- Tokens Used: " + tokens + " (" + defaultTokensParseStatus(in.TokensParseStatus) + ")\n")
	b.WriteString("- Mode ID: " + modeID + "\n")
	b.WriteString("- Approach Source: " + approachSource + "\n")
	b.WriteString("- Approach SHA256: " + approachSHA + "\n\n")
	b.WriteString("## Artifacts\n")
	b.WriteString("- Run Log: " + in.RunLogPath + "\n")
	b.WriteString("- Agent Final Message: " + in.LastMessagePath + "\n")

	if err := os.WriteFile(path, []byte(b.String()), 0o644); err != nil {
		return fmt.Errorf("write summary markdown: %w", err)
	}

	return nil
}

func buildMetricsRow(cfg LoopConfig, runNumber int, paths RunPaths, outcome RunOutcome) model.MetricsRow {
	now := cfg.Now
	if now == nil {
		now = time.Now
	}

	var assignedIssueID *string
	if strings.TrimSpace(cfg.AssignedIssueID) != "" {
		assignedIssueID = &cfg.AssignedIssueID
	}

	assignmentSource := outcome.AssignmentSource
	assignmentOutcome := outcome.AssignmentOutcome

	var issueID *string
	if strings.TrimSpace(outcome.IssueID) != "" {
		issueID = &outcome.IssueID
	}

	var modeID *string
	if strings.TrimSpace(cfg.ModeID) != "" {
		modeID = &cfg.ModeID
	}
	var approachSource *string
	if strings.TrimSpace(cfg.ApproachSource) != "" {
		approachSource = &cfg.ApproachSource
	}
	var approachSHA *string
	if strings.TrimSpace(cfg.ApproachSHA256) != "" {
		approachSHA = &cfg.ApproachSHA256
	}

	summary := model.MetricsSummary{
		DiscoveryIDs:         []string{},
		PlannedAssignedIssue: outcome.PlannedAssignedIssue,
		AssignmentSource:     &assignmentSource,
		AssignmentOutcome:    &assignmentOutcome,
		AssignmentMatch:      outcome.AssignmentMatch,
		LoopAction:           outcome.LoopAction,
	}
	if strings.TrimSpace(outcome.LoopActionReason) != "" {
		summary.LoopActionReason = &outcome.LoopActionReason
	}

	if outcome.SummaryResult != nil && outcome.SummaryResult.Summary != nil {
		raw := outcome.SummaryResult.Summary
		if strings.TrimSpace(raw.Result) != "" {
			summary.Result = &raw.Result
		}
		if strings.TrimSpace(raw.IssueStatus) != "" {
			summary.IssueStatus = &raw.IssueStatus
		}
		summary.Merged = &raw.Merged
		if raw.DiscoveryCount != nil {
			v := *raw.DiscoveryCount
			summary.DiscoveryCount = &v
		}
		summary.DiscoveryIDs = append([]string(nil), raw.DiscoveryIDs...)
	}

	return model.MetricsRow{
		Timestamp:            now().Format(time.RFC3339),
		AgentName:            cfg.AgentName,
		SessionID:            cfg.SessionID,
		HarnessVersion:       cfg.HarnessVersion,
		RunNumber:            runNumber,
		ExitCode:             outcome.ExitCode,
		Result:               outcome.Result,
		Reason:               outcome.Reason,
		AssignedIssueID:      assignedIssueID,
		PlannedAssignedIssue: outcome.PlannedAssignedIssue,
		AssignmentSource:     &assignmentSource,
		AssignmentOutcome:    &assignmentOutcome,
		IssueID:              issueID,
		ModeID:               modeID,
		ApproachSource:       approachSource,
		ApproachSHA256:       approachSHA,
		DurationsSeconds: model.MetricsDurations{
			IterationTotal: outcome.DurationSecs,
		},
		TokensUsed:               outcome.TokensUsed,
		TokensParseStatus:        defaultTokensParseStatus(outcome.TokensParseStatus),
		SummaryParseStatus:       outcome.SummaryResult.ParseStatus,
		SummarySchemaStatus:      outcome.SummaryResult.SchemaStatus,
		SummarySchemaReasonCodes: append([]string(nil), outcome.SummaryResult.SchemaReasonCodes...),
		Summary:                  summary,
		Files: model.MetricsArtifactSet{
			RunLog:           paths.RunLog,
			SummaryJSON:      paths.SummaryJSON,
			SummaryMarkdown:  paths.SummaryMarkdown,
			AgentLastMessage: paths.AgentLastMessage,
		},
	}
}
