// Package model defines core orca data types shared across packages.
//
// The model package is dependency-free and contains only data structures and
// pure validation logic.
package model

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"sort"
)

const (
	SummaryResultCompleted = "completed"
	SummaryResultBlocked   = "blocked"
	SummaryResultNoWork    = "no_work"
	SummaryResultFailed    = "failed"

	SummaryLoopActionContinue = "continue"
	SummaryLoopActionStop     = "stop"
)

// Summary is the required structured output from each run.
//
// The unexported raw field captures parsed JSON for schema validation that needs
// to distinguish missing fields from type mismatches.
type Summary struct {
	IssueID          string   `json:"issue_id"`
	Result           string   `json:"result"`
	IssueStatus      string   `json:"issue_status"`
	Merged           bool     `json:"merged"`
	LoopAction       string   `json:"loop_action"`
	LoopActionReason string   `json:"loop_action_reason"`
	Notes            string   `json:"notes"`
	DiscoveryIDs     []string `json:"discovery_ids,omitempty"`
	DiscoveryCount   *int     `json:"discovery_count,omitempty"`

	raw map[string]any `json:"-"`
}

// UnmarshalJSON keeps the raw object to support schema-style validation.
func (s *Summary) UnmarshalJSON(data []byte) error {
	type alias Summary
	*s = Summary{}

	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()

	var raw map[string]any
	if err := dec.Decode(&raw); err != nil {
		return err
	}
	s.raw = raw

	if v, ok := raw["issue_id"].(string); ok {
		s.IssueID = v
	}
	if v, ok := raw["result"].(string); ok {
		s.Result = v
	}
	if v, ok := raw["issue_status"].(string); ok {
		s.IssueStatus = v
	}
	if v, ok := raw["merged"].(bool); ok {
		s.Merged = v
	}
	if v, ok := raw["loop_action"].(string); ok {
		s.LoopAction = v
	}
	if v, ok := raw["loop_action_reason"].(string); ok {
		s.LoopActionReason = v
	}
	if v, ok := raw["notes"].(string); ok {
		s.Notes = v
	}

	if vals, ok := toArray(raw["discovery_ids"]); ok {
		ids := make([]string, 0, len(vals))
		allStrings := true
		for _, item := range vals {
			str, ok := item.(string)
			if !ok {
				allStrings = false
				break
			}
			ids = append(ids, str)
		}
		if allStrings {
			s.DiscoveryIDs = ids
		}
	}

	if n, ok := intFromJSON(raw["discovery_count"]); ok {
		s.DiscoveryCount = &n
	}

	return nil
}

// MetricsRow is one line in agent-logs/metrics.jsonl.
type MetricsRow struct {
	Timestamp                string             `json:"timestamp"`
	AgentName                string             `json:"agent_name"`
	SessionID                string             `json:"session_id"`
	HarnessVersion           string             `json:"harness_version"`
	RunNumber                int                `json:"run_number"`
	ExitCode                 int                `json:"exit_code"`
	Result                   string             `json:"result"`
	Reason                   string             `json:"reason"`
	AssignedIssueID          *string            `json:"assigned_issue_id"`
	PlannedAssignedIssue     *string            `json:"planned_assigned_issue"`
	AssignmentSource         *string            `json:"assignment_source"`
	AssignmentOutcome        *string            `json:"assignment_outcome"`
	IssueID                  *string            `json:"issue_id"`
	ModeID                   *string            `json:"mode_id"`
	ApproachSource           *string            `json:"approach_source"`
	ApproachSHA256           *string            `json:"approach_sha256"`
	DurationsSeconds         MetricsDurations   `json:"durations_seconds"`
	TokensUsed               *int               `json:"tokens_used"`
	TokensParseStatus        string             `json:"tokens_parse_status"`
	SummaryParseStatus       string             `json:"summary_parse_status"`
	SummarySchemaStatus      string             `json:"summary_schema_status"`
	SummarySchemaReasonCodes []string           `json:"summary_schema_reason_codes"`
	Summary                  MetricsSummary     `json:"summary"`
	Files                    MetricsArtifactSet `json:"files"`
}

type MetricsDurations struct {
	IterationTotal int `json:"iteration_total"`
}

type MetricsSummary struct {
	Result               *string  `json:"result"`
	IssueStatus          *string  `json:"issue_status"`
	Merged               *bool    `json:"merged"`
	DiscoveryCount       *int     `json:"discovery_count"`
	DiscoveryIDs         []string `json:"discovery_ids"`
	AssignmentMatch      *bool    `json:"assignment_match"`
	PlannedAssignedIssue *string  `json:"planned_assigned_issue"`
	AssignmentSource     *string  `json:"assignment_source"`
	AssignmentOutcome    *string  `json:"assignment_outcome"`
	LoopAction           string   `json:"loop_action"`
	LoopActionReason     *string  `json:"loop_action_reason"`
}

type MetricsArtifactSet struct {
	RunLog           string `json:"run_log"`
	SummaryJSON      string `json:"summary_json"`
	SummaryMarkdown  string `json:"summary_markdown"`
	AgentLastMessage string `json:"agent_last_message"`
}

// PlanOutput is the planner result contract.
type PlanOutput struct {
	PlannerVersion string            `json:"planner_version"`
	Input          PlanInputSummary  `json:"input"`
	Assignments    []PlanAssignment  `json:"assignments"`
	Held           []PlanHeldIssue   `json:"held"`
	Decisions      []PlanDecisionRow `json:"decisions"`
}

type PlanInputSummary struct {
	Slots      int `json:"slots"`
	ReadyCount int `json:"ready_count"`
}

type PlanAssignment struct {
	Slot      int      `json:"slot"`
	IssueID   string   `json:"issue_id"`
	Priority  *int     `json:"priority"`
	CreatedAt *string  `json:"created_at"`
	Labels    []string `json:"labels"`
}

type PlanHeldIssue struct {
	IssueID     string  `json:"issue_id"`
	ReasonCode  string  `json:"reason_code"`
	ConflictKey *string `json:"conflict_key,omitempty"`
}

type PlanDecisionRow struct {
	IssueID     string   `json:"issue_id"`
	Action      string   `json:"action"`
	ReasonCode  string   `json:"reason_code"`
	ConflictKey *string  `json:"conflict_key,omitempty"`
	Labels      []string `json:"labels"`
}

// DepSanityReport is the dependency checker output.
type DepSanityReport struct {
	CheckerVersion string            `json:"checker_version"`
	Input          DepSanityInput    `json:"input"`
	Hazards        []DepSanityHazard `json:"hazards"`
	Summary        DepSanitySummary  `json:"summary"`
}

type DepSanityInput struct {
	IssuesJSONL     string `json:"issues_jsonl,omitempty"`
	IssueCount      int    `json:"issue_count"`
	DependencyCount int    `json:"dependency_count"`
}

type DepSanityHazard struct {
	Code     string         `json:"code"`
	Severity string         `json:"severity"`
	Details  map[string]any `json:"details"`
}

type DepSanitySummary struct {
	HazardCount int  `json:"hazard_count"`
	StrictMode  bool `json:"strict_mode"`
}

// DoctorResult is doctor --json output.
type DoctorResult struct {
	SchemaVersion  int           `json:"schema_version"`
	OK             bool          `json:"ok"`
	Summary        DoctorSummary `json:"summary"`
	FailedCheckIDs []string      `json:"failed_check_ids"`
	Checks         []DoctorCheck `json:"checks"`
}

type DoctorSummary struct {
	Pass     int `json:"pass"`
	Fail     int `json:"fail"`
	Warn     int `json:"warn"`
	HardFail int `json:"hard_fail"`
}

type DoctorCheck struct {
	ID              string            `json:"id"`
	Title           string            `json:"title"`
	Category        string            `json:"category"`
	Status          string            `json:"status"`
	Severity        string            `json:"severity"`
	HardRequirement bool              `json:"hard_requirement"`
	Message         string            `json:"message"`
	Remediation     DoctorRemediation `json:"remediation"`
}

type DoctorRemediation struct {
	Summary  string   `json:"summary"`
	Commands []string `json:"commands"`
}

// StatusOutput is status --json output.
type StatusOutput struct {
	GeneratedAt    string          `json:"generated_at"`
	ActiveSessions int             `json:"active_sessions"`
	Queue          StatusQueue     `json:"queue"`
	BR             StatusBR        `json:"br"`
	Sessions       []StatusSession `json:"sessions"`
	Latest         StatusLatest    `json:"latest"`
}

type StatusQueue struct {
	Ready      int `json:"ready"`
	InProgress int `json:"in_progress"`
}

type StatusBR struct {
	Version   string `json:"version"`
	Workspace bool   `json:"workspace"`
}

type StatusSession struct {
	TmuxSession string  `json:"tmux_session"`
	SessionID   *string `json:"session_id"`
	AgentName   *string `json:"agent_name"`
	State       string  `json:"state"`
	LastResult  *string `json:"last_result"`
	LastIssue   *string `json:"last_issue"`
}

type StatusLatest struct {
	Agent    *string `json:"agent"`
	Result   *string `json:"result"`
	Issue    *string `json:"issue"`
	Duration *string `json:"duration"`
	Tokens   *string `json:"tokens"`
	Age      *string `json:"age"`
}

// ValidateSummary validates a run summary and returns reason codes compatible
// with the bash implementation.
func ValidateSummary(s *Summary) []string {
	return ValidateSummaryForAssignment(s, "")
}

// ValidateSummaryForAssignment validates a run summary against schema rules and
// an optional assigned issue ID.
func ValidateSummaryForAssignment(s *Summary, assignedIssueID string) []string {
	codes := make([]string, 0)

	add := func(code string) {
		codes = append(codes, code)
	}

	has := func(field string) bool {
		_, ok := getField(s, field)
		return ok
	}

	get := func(field string) any {
		v, _ := getField(s, field)
		return v
	}

	// issue_id
	if !has("issue_id") {
		add("missing:issue_id")
	} else if _, ok := get("issue_id").(string); !ok {
		add("type:issue_id")
	}

	// result
	if !has("result") {
		add("missing:result")
	} else {
		result, ok := get("result").(string)
		if !ok {
			add("type:result")
			add("enum:result")
		} else if !isSummaryResult(result) {
			add("enum:result")
		}
	}

	// issue_status
	if !has("issue_status") {
		add("missing:issue_status")
	} else if _, ok := get("issue_status").(string); !ok {
		add("type:issue_status")
	}

	// merged
	if !has("merged") {
		add("missing:merged")
	} else if _, ok := get("merged").(bool); !ok {
		add("type:merged")
	}

	// discovery_ids
	if has("discovery_ids") {
		if _, ok := toArray(get("discovery_ids")); !ok {
			add("type:discovery_ids")
		} else if !allStrings(get("discovery_ids")) {
			add("type:discovery_ids_items")
		}
	}

	// discovery_count
	discoveryCount, hasCount := intFromJSON(get("discovery_count"))
	if has("discovery_count") && !hasCount {
		add("type:discovery_count")
	}

	// discovery_count vs discovery_ids length
	if has("discovery_count") && has("discovery_ids") {
		if ids, ok := toArray(get("discovery_ids")); ok && hasCount {
			if discoveryCount != len(ids) {
				add("mismatch:discovery_count")
			}
		}
	}

	// loop_action
	if !has("loop_action") {
		add("missing:loop_action")
	} else {
		loopAction, ok := get("loop_action").(string)
		if !ok {
			add("type:loop_action")
			add("enum:loop_action")
		} else if loopAction != SummaryLoopActionContinue && loopAction != SummaryLoopActionStop {
			add("enum:loop_action")
		}
	}

	// loop_action_reason
	if !has("loop_action_reason") {
		add("missing:loop_action_reason")
	} else if _, ok := get("loop_action_reason").(string); !ok {
		add("type:loop_action_reason")
	}

	// notes
	if !has("notes") {
		add("missing:notes")
	} else if _, ok := get("notes").(string); !ok {
		add("type:notes")
	}

	// assignment match
	if assignedIssueID != "" {
		issueID, ok := get("issue_id").(string)
		if !ok || issueID != assignedIssueID {
			add("mismatch:assigned_issue_id")
		}
	}

	codes = uniqueStrings(codes)
	sort.Strings(codes)
	return codes
}

func isSummaryResult(result string) bool {
	switch result {
	case SummaryResultCompleted, SummaryResultBlocked, SummaryResultNoWork, SummaryResultFailed:
		return true
	default:
		return false
	}
}

func uniqueStrings(in []string) []string {
	seen := make(map[string]struct{}, len(in))
	out := make([]string, 0, len(in))
	for _, item := range in {
		if _, ok := seen[item]; ok {
			continue
		}
		seen[item] = struct{}{}
		out = append(out, item)
	}
	return out
}

func getField(s *Summary, field string) (any, bool) {
	if s == nil {
		return nil, false
	}

	if s.raw != nil {
		v, ok := s.raw[field]
		return v, ok
	}

	switch field {
	case "issue_id":
		return s.IssueID, true
	case "result":
		return s.Result, true
	case "issue_status":
		return s.IssueStatus, true
	case "merged":
		return s.Merged, true
	case "loop_action":
		return s.LoopAction, true
	case "loop_action_reason":
		return s.LoopActionReason, true
	case "notes":
		return s.Notes, true
	case "discovery_ids":
		if s.DiscoveryIDs == nil {
			return nil, false
		}
		values := make([]any, 0, len(s.DiscoveryIDs))
		for _, id := range s.DiscoveryIDs {
			values = append(values, id)
		}
		return values, true
	case "discovery_count":
		if s.DiscoveryCount == nil {
			return nil, false
		}
		return *s.DiscoveryCount, true
	default:
		return nil, false
	}
}

func intFromJSON(v any) (int, bool) {
	switch n := v.(type) {
	case int:
		return n, true
	case int8:
		return int(n), true
	case int16:
		return int(n), true
	case int32:
		return int(n), true
	case int64:
		return int(n), true
	case float32:
		f := float64(n)
		if math.Trunc(f) != f {
			return 0, false
		}
		return int(f), true
	case float64:
		if math.Trunc(n) != n {
			return 0, false
		}
		return int(n), true
	case json.Number:
		i, err := n.Int64()
		if err != nil {
			return 0, false
		}
		return int(i), true
	case nil:
		return 0, false
	default:
		return 0, false
	}
}

func toArray(v any) ([]any, bool) {
	switch arr := v.(type) {
	case []any:
		return arr, true
	case []string:
		out := make([]any, 0, len(arr))
		for _, item := range arr {
			out = append(out, item)
		}
		return out, true
	case nil:
		return nil, false
	default:
		return nil, false
	}
}

func allStrings(v any) bool {
	arr, ok := toArray(v)
	if !ok {
		return false
	}
	for i, item := range arr {
		if _, ok := item.(string); !ok {
			_ = i
			return false
		}
	}
	return true
}

func (s Summary) String() string {
	return fmt.Sprintf("summary(issue_id=%q,result=%q)", s.IssueID, s.Result)
}
