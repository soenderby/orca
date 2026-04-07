package model

import (
	"encoding/json"
	"reflect"
	"sort"
	"testing"
)

func TestValidateSummary(t *testing.T) {
	tests := []struct {
		name          string
		jsonInput     string
		assignedIssue string
		wantCodes     []string
	}{
		{
			name: "valid minimal summary",
			jsonInput: `{
				"issue_id":"orca-1",
				"result":"completed",
				"issue_status":"closed",
				"merged":true,
				"loop_action":"continue",
				"loop_action_reason":"",
				"notes":"done"
			}`,
		},
		{
			name:      "missing required fields",
			jsonInput: `{}`,
			wantCodes: []string{
				"missing:issue_id",
				"missing:issue_status",
				"missing:loop_action",
				"missing:loop_action_reason",
				"missing:merged",
				"missing:notes",
				"missing:result",
			},
		},
		{
			name: "type errors",
			jsonInput: `{
				"issue_id":123,
				"result":true,
				"issue_status":{},
				"merged":"yes",
				"loop_action":9,
				"loop_action_reason":[],
				"notes":false,
				"discovery_ids":{},
				"discovery_count":1.5
			}`,
			wantCodes: []string{
				"enum:loop_action",
				"enum:result",
				"type:discovery_count",
				"type:discovery_ids",
				"type:issue_id",
				"type:issue_status",
				"type:loop_action",
				"type:loop_action_reason",
				"type:merged",
				"type:notes",
				"type:result",
			},
		},
		{
			name: "enum errors",
			jsonInput: `{
				"issue_id":"orca-1",
				"result":"wat",
				"issue_status":"open",
				"merged":false,
				"loop_action":"later",
				"loop_action_reason":"",
				"notes":"n"
			}`,
			wantCodes: []string{"enum:loop_action", "enum:result"},
		},
		{
			name: "discovery ids item type error",
			jsonInput: `{
				"issue_id":"orca-1",
				"result":"completed",
				"issue_status":"closed",
				"merged":false,
				"loop_action":"continue",
				"loop_action_reason":"",
				"notes":"n",
				"discovery_ids":["orca-2", 7]
			}`,
			wantCodes: []string{"type:discovery_ids_items"},
		},
		{
			name: "discovery count mismatch",
			jsonInput: `{
				"issue_id":"orca-1",
				"result":"completed",
				"issue_status":"closed",
				"merged":false,
				"loop_action":"continue",
				"loop_action_reason":"",
				"notes":"n",
				"discovery_ids":["orca-2"],
				"discovery_count":2
			}`,
			wantCodes: []string{"mismatch:discovery_count"},
		},
		{
			name: "assigned issue mismatch",
			jsonInput: `{
				"issue_id":"orca-other",
				"result":"completed",
				"issue_status":"closed",
				"merged":true,
				"loop_action":"continue",
				"loop_action_reason":"",
				"notes":"done"
			}`,
			assignedIssue: "orca-assigned",
			wantCodes:     []string{"mismatch:assigned_issue_id"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var summary Summary
			if err := json.Unmarshal([]byte(tt.jsonInput), &summary); err != nil {
				t.Fatalf("unmarshal summary: %v", err)
			}

			got := ValidateSummaryForAssignment(&summary, tt.assignedIssue)
			if tt.wantCodes == nil {
				if len(got) != 0 {
					t.Fatalf("expected no validation codes, got %#v", got)
				}
				return
			}
			if !reflect.DeepEqual(got, tt.wantCodes) {
				t.Fatalf("codes mismatch\nwant: %#v\n got: %#v", tt.wantCodes, got)
			}
		})
	}
}

func TestValidateSummary_Nil(t *testing.T) {
	got := ValidateSummary(nil)
	want := []string{
		"missing:issue_id",
		"missing:issue_status",
		"missing:loop_action",
		"missing:loop_action_reason",
		"missing:merged",
		"missing:notes",
		"missing:result",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("codes mismatch\nwant: %#v\n got: %#v", want, got)
	}
}

func TestJSONRoundTrip_AllTypes(t *testing.T) {
	count := 2
	trueValue := true
	issue := "orca-123"
	assignment := "orca-assign"
	source := "planner"
	outcome := "matched"
	modeID := "execute"
	approachSource := "/tmp/approach.md"
	approachSHA := "abc123"
	loopReason := "done"
	duration := "12"
	tokens := "245"
	age := "5s ago"
	sessionID := "session-1"
	agentName := "agent-1"
	lastResult := "completed"
	lastIssue := "orca-123"
	priority := 1
	createdAt := "2026-03-01T00:00:00Z"
	conflict := "queue"

	values := []any{
		Summary{
			IssueID:          issue,
			Result:           SummaryResultCompleted,
			IssueStatus:      "closed",
			Merged:           true,
			LoopAction:       SummaryLoopActionContinue,
			LoopActionReason: "",
			Notes:            "done",
			DiscoveryIDs:     []string{"orca-200", "orca-201"},
			DiscoveryCount:   &count,
		},
		MetricsRow{
			Timestamp:            "2026-03-01T00:00:01Z",
			AgentName:            "agent-1",
			SessionID:            "agent-1-20260301T000000Z",
			HarnessVersion:       "v0.1.0",
			RunNumber:            1,
			ExitCode:             0,
			Result:               "completed",
			Reason:               "agent-exit-0",
			AssignedIssueID:      &assignment,
			PlannedAssignedIssue: &assignment,
			AssignmentSource:     &source,
			AssignmentOutcome:    &outcome,
			IssueID:              &issue,
			ModeID:               &modeID,
			ApproachSource:       &approachSource,
			ApproachSHA256:       &approachSHA,
			DurationsSeconds: MetricsDurations{
				IterationTotal: 42,
			},
			TokensUsed:               &count,
			TokensParseStatus:        "ok",
			SummaryParseStatus:       "parsed",
			SummarySchemaStatus:      "valid",
			SummarySchemaReasonCodes: []string{},
			Summary: MetricsSummary{
				Result:               &lastResult,
				IssueStatus:          &outcome,
				Merged:               &trueValue,
				DiscoveryCount:       &count,
				DiscoveryIDs:         []string{"orca-200"},
				AssignmentMatch:      &trueValue,
				PlannedAssignedIssue: &assignment,
				AssignmentSource:     &source,
				AssignmentOutcome:    &outcome,
				LoopAction:           "continue",
				LoopActionReason:     &loopReason,
			},
			Files: MetricsArtifactSet{
				RunLog:           "/tmp/run.log",
				SummaryJSON:      "/tmp/summary.json",
				SummaryMarkdown:  "/tmp/summary.md",
				AgentLastMessage: "/tmp/last-message.md",
			},
		},
		PlanOutput{
			PlannerVersion: "v1",
			Input: PlanInputSummary{
				Slots:      1,
				ReadyCount: 2,
			},
			Assignments: []PlanAssignment{{
				Slot:      1,
				IssueID:   issue,
				Priority:  &priority,
				CreatedAt: &createdAt,
				Labels:    []string{"ck:queue"},
			}},
			Held: []PlanHeldIssue{{
				IssueID:     "orca-2",
				ReasonCode:  "contention-key-conflict",
				ConflictKey: &conflict,
			}},
			Decisions: []PlanDecisionRow{{
				IssueID:    issue,
				Action:     "assigned",
				ReasonCode: "scheduled",
				Labels:     []string{},
			}},
		},
		DepSanityReport{
			CheckerVersion: "v1",
			Input: DepSanityInput{
				IssueCount:      2,
				DependencyCount: 1,
			},
			Hazards: []DepSanityHazard{{
				Code:     "self-dependency-active",
				Severity: "error",
				Details: map[string]any{
					"issue_id": "orca-1",
					"type":     "blocks",
				},
			}},
			Summary: DepSanitySummary{
				HazardCount: 1,
				StrictMode:  true,
			},
		},
		DoctorResult{
			SchemaVersion: 1,
			OK:            false,
			Summary: DoctorSummary{
				Pass:     5,
				Fail:     1,
				Warn:     2,
				HardFail: 1,
			},
			FailedCheckIDs: []string{"dependency.git"},
			Checks: []DoctorCheck{{
				ID:              "dependency.git",
				Title:           "git present",
				Category:        "dependency",
				Status:          "fail",
				Severity:        "error",
				HardRequirement: true,
				Message:         "missing git",
				Remediation: DoctorRemediation{
					Summary:  "install git",
					Commands: []string{"sudo apt install -y git"},
				},
			}},
		},
		StatusOutput{
			GeneratedAt:    "2026-03-01T00:00:01Z",
			ActiveSessions: 1,
			Queue: StatusQueue{
				Ready:      4,
				InProgress: 2,
			},
			BR: StatusBR{
				Version:   "0.9.0",
				Workspace: true,
			},
			Sessions: []StatusSession{{
				TmuxSession: "orca-agent-1-20260301T000000Z",
				SessionID:   &sessionID,
				AgentName:   &agentName,
				State:       "idle",
				LastResult:  &lastResult,
				LastIssue:   &lastIssue,
			}},
			Latest: StatusLatest{
				Agent:    &agentName,
				Result:   &lastResult,
				Issue:    &issue,
				Duration: &duration,
				Tokens:   &tokens,
				Age:      &age,
			},
		},
	}

	for i, value := range values {
		data, err := json.Marshal(value)
		if err != nil {
			t.Fatalf("case %d: marshal: %v", i, err)
		}

		var original any
		if err := json.Unmarshal(data, &original); err != nil {
			t.Fatalf("case %d: unmarshal original json: %v", i, err)
		}

		clonePtr := cloneForType(value)
		if err := json.Unmarshal(data, clonePtr); err != nil {
			t.Fatalf("case %d: unmarshal roundtrip: %v", i, err)
		}

		roundTripData, err := json.Marshal(clonePtr)
		if err != nil {
			t.Fatalf("case %d: marshal roundtrip: %v", i, err)
		}

		var roundTripped any
		if err := json.Unmarshal(roundTripData, &roundTripped); err != nil {
			t.Fatalf("case %d: unmarshal roundtrip json: %v", i, err)
		}

		if !reflect.DeepEqual(original, roundTripped) {
			t.Fatalf("case %d: json changed after roundtrip\noriginal=%#v\nroundtrip=%#v", i, original, roundTripped)
		}
	}

}

func cloneForType(value any) any {
	switch value.(type) {
	case Summary:
		return &Summary{}
	case MetricsRow:
		return &MetricsRow{}
	case PlanOutput:
		return &PlanOutput{}
	case DepSanityReport:
		return &DepSanityReport{}
	case DoctorResult:
		return &DoctorResult{}
	case StatusOutput:
		return &StatusOutput{}
	default:
		panic("unsupported type")
	}
}

func TestValidateSummary_DeduplicatesAndSortsCodes(t *testing.T) {
	var summary Summary
	if err := json.Unmarshal([]byte(`{"issue_id":1}`), &summary); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	got := ValidateSummaryForAssignment(&summary, "orca-1")
	if !sort.StringsAreSorted(got) {
		t.Fatalf("codes not sorted: %#v", got)
	}

	seen := map[string]struct{}{}
	for _, code := range got {
		if _, ok := seen[code]; ok {
			t.Fatalf("duplicate code %q in %#v", code, got)
		}
		seen[code] = struct{}{}
	}
}
