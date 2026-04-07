package loop

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/soenderby/orca/internal/model"
)

func TestParseAndValidateSummary(t *testing.T) {
	t.Run("missing file", func(t *testing.T) {
		res, err := ParseAndValidateSummary(filepath.Join(t.TempDir(), "missing.json"), "")
		if err != nil {
			t.Fatalf("parse summary: %v", err)
		}
		if res.ParseStatus != SummaryParseMissing {
			t.Fatalf("parse status mismatch: %q", res.ParseStatus)
		}
		if res.SchemaStatus != SummarySchemaNotChecked {
			t.Fatalf("schema status mismatch: %q", res.SchemaStatus)
		}
	})

	t.Run("invalid json", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), "summary.json")
		if err := os.WriteFile(path, []byte("{"), 0o644); err != nil {
			t.Fatalf("write file: %v", err)
		}
		res, err := ParseAndValidateSummary(path, "")
		if err != nil {
			t.Fatalf("parse summary: %v", err)
		}
		if res.ParseStatus != SummaryParseInvalidJSON {
			t.Fatalf("parse status mismatch: %q", res.ParseStatus)
		}
		if res.SchemaStatus != SummarySchemaNotChecked {
			t.Fatalf("schema status mismatch: %q", res.SchemaStatus)
		}
	})

	t.Run("valid summary", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), "summary.json")
		writeJSON(t, path, map[string]any{
			"issue_id":           "orca-1",
			"result":             "completed",
			"issue_status":       "closed",
			"merged":             true,
			"loop_action":        "continue",
			"loop_action_reason": "",
			"notes":              "done",
		})

		res, err := ParseAndValidateSummary(path, "orca-1")
		if err != nil {
			t.Fatalf("parse summary: %v", err)
		}
		if res.ParseStatus != SummaryParseParsed {
			t.Fatalf("parse status mismatch: %q", res.ParseStatus)
		}
		if res.SchemaStatus != SummarySchemaValid {
			t.Fatalf("schema status mismatch: %q", res.SchemaStatus)
		}
		if res.LoopAction != model.SummaryLoopActionContinue {
			t.Fatalf("loop action mismatch: %q", res.LoopAction)
		}
	})

	t.Run("assigned mismatch fails closed", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), "summary.json")
		writeJSON(t, path, map[string]any{
			"issue_id":           "orca-other",
			"result":             "completed",
			"issue_status":       "closed",
			"merged":             true,
			"loop_action":        "stop",
			"loop_action_reason": "agent-requested-stop",
			"notes":              "done",
		})

		res, err := ParseAndValidateSummary(path, "orca-assigned")
		if err != nil {
			t.Fatalf("parse summary: %v", err)
		}
		if res.SchemaStatus != SummarySchemaInvalid {
			t.Fatalf("schema status mismatch: %q", res.SchemaStatus)
		}
		if !contains(res.SchemaReasonCodes, "mismatch:assigned_issue_id") {
			t.Fatalf("missing assigned mismatch code: %#v", res.SchemaReasonCodes)
		}
		if res.LoopAction != model.SummaryLoopActionContinue {
			t.Fatalf("invalid summary must fail closed to continue, got %q", res.LoopAction)
		}
		if res.LoopActionReason != "" {
			t.Fatalf("invalid summary loop action reason should be cleared, got %q", res.LoopActionReason)
		}
	})
}

func TestAppendMetrics(t *testing.T) {
	path := filepath.Join(t.TempDir(), "agent-logs", "metrics.jsonl")
	row1 := model.MetricsRow{Timestamp: "2026-03-01T00:00:01Z", AgentName: "agent-1"}
	row2 := model.MetricsRow{Timestamp: "2026-03-01T00:00:02Z", AgentName: "agent-2"}

	if err := AppendMetrics(path, row1); err != nil {
		t.Fatalf("append row1: %v", err)
	}
	if err := AppendMetrics(path, row2); err != nil {
		t.Fatalf("append row2: %v", err)
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read metrics: %v", err)
	}
	lines := splitNonEmptyLines(string(raw))
	if len(lines) != 2 {
		t.Fatalf("expected 2 metrics rows, got %d", len(lines))
	}

	var got1, got2 model.MetricsRow
	if err := json.Unmarshal([]byte(lines[0]), &got1); err != nil {
		t.Fatalf("unmarshal row1: %v", err)
	}
	if err := json.Unmarshal([]byte(lines[1]), &got2); err != nil {
		t.Fatalf("unmarshal row2: %v", err)
	}

	if got1.AgentName != "agent-1" || got2.AgentName != "agent-2" {
		t.Fatalf("row ordering mismatch: got %#v %#v", got1, got2)
	}
}

func TestApplyNoWorkDrainPolicy(t *testing.T) {
	tests := []struct {
		name               string
		result             string
		consecutive        int
		mode               string
		retryLimit         int
		wantStop           bool
		wantConsecutive    int
		wantLoopAction     string
		wantLoopReason     string
		wantDecisionReason string
		wantErr            bool
	}{
		{
			name:               "drain mode stop after first no_work when retry=0",
			result:             model.SummaryResultNoWork,
			consecutive:        0,
			mode:               "drain",
			retryLimit:         0,
			wantStop:           true,
			wantConsecutive:    1,
			wantLoopAction:     model.SummaryLoopActionStop,
			wantLoopReason:     "queue-drained-after-1-consecutive-no_work-runs",
			wantDecisionReason: "queue-drained-after-1-consecutive-no_work-runs",
		},
		{
			name:               "drain mode retries before stop",
			result:             model.SummaryResultNoWork,
			consecutive:        0,
			mode:               "drain",
			retryLimit:         1,
			wantStop:           false,
			wantConsecutive:    1,
			wantLoopAction:     model.SummaryLoopActionContinue,
			wantLoopReason:     "",
			wantDecisionReason: "",
		},
		{
			name:               "watch mode never auto-stops",
			result:             model.SummaryResultNoWork,
			consecutive:        5,
			mode:               "watch",
			retryLimit:         0,
			wantStop:           false,
			wantConsecutive:    6,
			wantLoopAction:     model.SummaryLoopActionContinue,
			wantLoopReason:     "",
			wantDecisionReason: "",
		},
		{
			name:               "non-no-work resets counter",
			result:             model.SummaryResultCompleted,
			consecutive:        3,
			mode:               "drain",
			retryLimit:         0,
			wantStop:           false,
			wantConsecutive:    0,
			wantLoopAction:     model.SummaryLoopActionContinue,
			wantLoopReason:     "",
			wantDecisionReason: "",
		},
		{
			name:    "invalid mode",
			result:  model.SummaryResultNoWork,
			mode:    "invalid",
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			decision, err := ApplyNoWorkDrainPolicy(tt.result, tt.consecutive, tt.mode, tt.retryLimit)
			if tt.wantErr {
				if err == nil {
					t.Fatal("expected error, got nil")
				}
				return
			}
			if err != nil {
				t.Fatalf("policy error: %v", err)
			}

			if decision.Stop != tt.wantStop ||
				decision.ConsecutiveNoWork != tt.wantConsecutive ||
				decision.LoopAction != tt.wantLoopAction ||
				decision.LoopActionReason != tt.wantLoopReason ||
				decision.Reason != tt.wantDecisionReason {
				t.Fatalf("decision mismatch\nwant=%#v\n got=%#v", tt, decision)
			}
		})
	}
}

func TestLoop_DrainStopObservabilityParity(t *testing.T) {
	tmp := t.TempDir()
	metricsPath := filepath.Join(tmp, "agent-logs", "metrics.jsonl")
	sessionID := "drain-stop-session"

	runs := 0
	err := Loop(LoopConfig{
		AgentName:        "regression-agent",
		SessionID:        sessionID,
		AssignmentMode:   "self-select",
		MaxRuns:          5,
		NoWorkDrainMode:  "drain",
		NoWorkRetryLimit: 0,
		MetricsPath:      metricsPath,
		Executor: ExecutorFunc(func(inv RunInvocation) (ExecutionResult, error) {
			runs++
			writeJSON(t, inv.Paths.SummaryJSON, map[string]any{
				"issue_id":           "",
				"result":             "no_work",
				"issue_status":       "",
				"merged":             false,
				"loop_action":        "continue",
				"loop_action_reason": "",
				"notes":              "regression test no_work run",
			})
			return ExecutionResult{ExitCode: 0, DurationSeconds: 1}, nil
		}),
		PathsForRun: func(runNumber int) RunPaths {
			runDir := filepath.Join(tmp, "runs", strconv.Itoa(runNumber))
			return RunPaths{
				SummaryJSON:      filepath.Join(runDir, "summary.json"),
				RunLog:           filepath.Join(runDir, "run.log"),
				SummaryMarkdown:  filepath.Join(runDir, "summary.md"),
				AgentLastMessage: filepath.Join(runDir, "last-message.md"),
			}
		},
		Now:   func() time.Time { return time.Date(2026, 3, 1, 0, 0, 0, 0, time.UTC) },
		Sleep: func(time.Duration) {},
	})
	if err != nil {
		t.Fatalf("loop failed: %v", err)
	}
	if runs != 1 {
		t.Fatalf("expected early drain stop before max runs, observed %d runs", runs)
	}

	row := readLastMetricsRow(t, metricsPath)
	if row.Summary.LoopAction != "stop" {
		t.Fatalf("summary.loop_action mismatch: %#v", row.Summary.LoopAction)
	}
	wantReason := "queue-drained-after-1-consecutive-no_work-runs"
	if row.Summary.LoopActionReason == nil || *row.Summary.LoopActionReason != wantReason {
		t.Fatalf("summary.loop_action_reason mismatch: %#v", row.Summary.LoopActionReason)
	}
	if row.PlannedAssignedIssue != nil {
		t.Fatalf("planned_assigned_issue should be null, got %#v", row.PlannedAssignedIssue)
	}
	if row.AssignmentSource == nil || *row.AssignmentSource != "self-select" {
		t.Fatalf("assignment_source mismatch: %#v", row.AssignmentSource)
	}
	if row.AssignmentOutcome == nil || *row.AssignmentOutcome != "unassigned" {
		t.Fatalf("assignment_outcome mismatch: %#v", row.AssignmentOutcome)
	}
	if row.ModeID != nil || row.ApproachSource != nil || row.ApproachSHA256 != nil {
		t.Fatalf("mode attribution should be null, got mode=%#v source=%#v sha=%#v", row.ModeID, row.ApproachSource, row.ApproachSHA256)
	}
	if row.Summary.PlannedAssignedIssue != nil {
		t.Fatalf("summary.planned_assigned_issue should be null, got %#v", row.Summary.PlannedAssignedIssue)
	}
	if row.Summary.AssignmentSource == nil || *row.Summary.AssignmentSource != "self-select" {
		t.Fatalf("summary.assignment_source mismatch: %#v", row.Summary.AssignmentSource)
	}
	if row.Summary.AssignmentOutcome == nil || *row.Summary.AssignmentOutcome != "unassigned" {
		t.Fatalf("summary.assignment_outcome mismatch: %#v", row.Summary.AssignmentOutcome)
	}
}

func TestLoop_AssignedIssueContractParity(t *testing.T) {
	tmp := t.TempDir()
	metricsPath := filepath.Join(tmp, "agent-logs", "metrics.jsonl")
	assigned := "orca-assigned"
	actual := "orca-other"

	err := Loop(LoopConfig{
		AgentName:        "regression-agent",
		SessionID:        "assigned-session",
		AssignmentMode:   "assigned",
		AssignedIssueID:  assigned,
		MaxRuns:          1,
		NoWorkDrainMode:  "drain",
		NoWorkRetryLimit: 0,
		MetricsPath:      metricsPath,
		Executor: ExecutorFunc(func(inv RunInvocation) (ExecutionResult, error) {
			writeJSON(t, inv.Paths.SummaryJSON, map[string]any{
				"issue_id":           actual,
				"result":             "completed",
				"issue_status":       "closed",
				"merged":             true,
				"loop_action":        "continue",
				"loop_action_reason": "",
				"notes":              "assigned issue mismatch regression",
			})
			return ExecutionResult{ExitCode: 0, DurationSeconds: 1}, nil
		}),
		PathsForRun: func(runNumber int) RunPaths {
			runDir := filepath.Join(tmp, "runs", strconv.Itoa(runNumber))
			return RunPaths{SummaryJSON: filepath.Join(runDir, "summary.json")}
		},
		Now:   func() time.Time { return time.Date(2026, 3, 1, 0, 0, 0, 0, time.UTC) },
		Sleep: func(time.Duration) {},
	})
	if err != nil {
		t.Fatalf("loop failed: %v", err)
	}

	row := readLastMetricsRow(t, metricsPath)
	if row.Result != "failed" {
		t.Fatalf("result mismatch: %#v", row.Result)
	}
	if row.AssignedIssueID == nil || *row.AssignedIssueID != assigned {
		t.Fatalf("assigned_issue_id mismatch: %#v", row.AssignedIssueID)
	}
	if row.PlannedAssignedIssue == nil || *row.PlannedAssignedIssue != assigned {
		t.Fatalf("planned_assigned_issue mismatch: %#v", row.PlannedAssignedIssue)
	}
	if row.AssignmentSource == nil || *row.AssignmentSource != "planner" {
		t.Fatalf("assignment_source mismatch: %#v", row.AssignmentSource)
	}
	if row.AssignmentOutcome == nil || *row.AssignmentOutcome != "mismatch" {
		t.Fatalf("assignment_outcome mismatch: %#v", row.AssignmentOutcome)
	}
	if row.IssueID == nil || *row.IssueID != actual {
		t.Fatalf("issue_id mismatch: %#v", row.IssueID)
	}
	if row.SummarySchemaStatus != "invalid" {
		t.Fatalf("summary_schema_status mismatch: %#v", row.SummarySchemaStatus)
	}
	if !contains(row.SummarySchemaReasonCodes, "mismatch:assigned_issue_id") {
		t.Fatalf("missing mismatch reason code: %#v", row.SummarySchemaReasonCodes)
	}
	if row.Summary.AssignmentMatch == nil || *row.Summary.AssignmentMatch != false {
		t.Fatalf("summary.assignment_match mismatch: %#v", row.Summary.AssignmentMatch)
	}
	if row.Summary.PlannedAssignedIssue == nil || *row.Summary.PlannedAssignedIssue != assigned {
		t.Fatalf("summary.planned_assigned_issue mismatch: %#v", row.Summary.PlannedAssignedIssue)
	}
	if row.Summary.AssignmentSource == nil || *row.Summary.AssignmentSource != "planner" {
		t.Fatalf("summary.assignment_source mismatch: %#v", row.Summary.AssignmentSource)
	}
	if row.Summary.AssignmentOutcome == nil || *row.Summary.AssignmentOutcome != "mismatch" {
		t.Fatalf("summary.assignment_outcome mismatch: %#v", row.Summary.AssignmentOutcome)
	}
}

func readLastMetricsRow(t *testing.T, path string) model.MetricsRow {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read metrics: %v", err)
	}
	lines := splitNonEmptyLines(string(raw))
	if len(lines) == 0 {
		t.Fatal("metrics file is empty")
	}
	var row model.MetricsRow
	if err := json.Unmarshal([]byte(lines[len(lines)-1]), &row); err != nil {
		t.Fatalf("unmarshal metrics row: %v", err)
	}
	return row
}

func writeJSON(t *testing.T, path string, value any) {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatalf("marshal json: %v", err)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatalf("write json: %v", err)
	}
}

func contains(items []string, want string) bool {
	for _, item := range items {
		if item == want {
			return true
		}
	}
	return false
}

func splitNonEmptyLines(s string) []string {
	lines := strings.Split(s, "\n")
	out := make([]string, 0, len(lines))
	for _, line := range lines {
		if strings.TrimSpace(line) == "" {
			continue
		}
		out = append(out, line)
	}
	return out
}

func TestApplyNoWorkDrainPolicy_StableFields(t *testing.T) {
	decision, err := ApplyNoWorkDrainPolicy(model.SummaryResultNoWork, 0, "drain", 0)
	if err != nil {
		t.Fatalf("policy error: %v", err)
	}
	if !reflect.DeepEqual(decision, DrainDecision{
		ConsecutiveNoWork: 1,
		Stop:              true,
		LoopAction:        model.SummaryLoopActionStop,
		LoopActionReason:  "queue-drained-after-1-consecutive-no_work-runs",
		Reason:            "queue-drained-after-1-consecutive-no_work-runs",
	}) {
		t.Fatalf("unexpected decision: %#v", decision)
	}
}
