package plan

import (
	"reflect"
	"testing"

	"github.com/soenderby/orca/internal/model"
)

func TestBuild_RegressionParity(t *testing.T) {
	issues := []Issue{
		{ID: "orca-t", Priority: intPtr(1), CreatedAt: strPtr("2026-03-01T00:00:00Z"), Labels: []string{"meta:tracker"}},
		{ID: "orca-e", Priority: intPtr(3), CreatedAt: strPtr("2026-03-01T00:00:05Z"), Labels: []string{}},
		{ID: "orca-c", Priority: intPtr(1), CreatedAt: strPtr("2026-03-01T00:00:03Z"), Labels: []string{"ck:queue"}},
		{ID: "orca-a", Priority: intPtr(1), CreatedAt: strPtr("2026-03-01T00:00:01Z"), Labels: []string{}},
		{ID: "orca-d", Priority: intPtr(2), CreatedAt: strPtr("2026-03-01T00:00:04Z"), Labels: []string{"px:exclusive"}},
		{ID: "orca-f", Priority: intPtr(4), CreatedAt: strPtr("2026-03-01T00:00:06Z"), Labels: []string{}},
		{ID: "orca-b", Priority: intPtr(1), CreatedAt: strPtr("2026-03-01T00:00:02Z"), Labels: []string{"ck:queue"}},
	}

	got := Build(issues, 3)
	gotAgain := Build(issues, 3)
	if !reflect.DeepEqual(got, gotAgain) {
		t.Fatalf("planner output is not deterministic\nfirst=%#v\nsecond=%#v", got, gotAgain)
	}

	wantAssignments := []string{"orca-a", "orca-b", "orca-e"}
	if ids := assignmentIDs(got); !reflect.DeepEqual(ids, wantAssignments) {
		t.Fatalf("assignment mismatch\nwant=%#v\ngot =%#v", wantAssignments, ids)
	}

	assertHeldReason(t, got, "orca-t", "tracker-issue")
	assertHeldReason(t, got, "orca-c", "contention-key-conflict")
	assertHeldConflictKey(t, got, "orca-c", "queue")
	assertHeldReason(t, got, "orca-d", "exclusive-conflict")
	assertHeldReason(t, got, "orca-f", "not-enough-slots")
}

func TestBuild_ExclusiveRunsAlone(t *testing.T) {
	issues := []Issue{
		{ID: "orca-x", Priority: intPtr(1), CreatedAt: strPtr("2026-03-01T00:00:01Z"), Labels: []string{"px:exclusive"}},
		{ID: "orca-y", Priority: intPtr(2), CreatedAt: strPtr("2026-03-01T00:00:02Z"), Labels: []string{}},
		{ID: "orca-z", Priority: intPtr(3), CreatedAt: strPtr("2026-03-01T00:00:03Z"), Labels: []string{"ck:queue"}},
	}

	got := Build(issues, 3)
	wantAssignments := []string{"orca-x"}
	if ids := assignmentIDs(got); !reflect.DeepEqual(ids, wantAssignments) {
		t.Fatalf("assignment mismatch\nwant=%#v\ngot =%#v", wantAssignments, ids)
	}

	assertHeldReason(t, got, "orca-y", "exclusive-already-selected")
	assertHeldReason(t, got, "orca-z", "exclusive-already-selected")
}

func TestBuild_NoIssues(t *testing.T) {
	got := Build(nil, 2)
	if len(got.Assignments) != 0 || len(got.Held) != 0 || len(got.Decisions) != 0 {
		t.Fatalf("expected empty output, got %#v", got)
	}
	if got.Input.ReadyCount != 0 {
		t.Fatalf("ready count mismatch: got %d", got.Input.ReadyCount)
	}
}

func TestBuild_SingleSlot(t *testing.T) {
	issues := []Issue{
		{ID: "orca-a", Priority: intPtr(2), CreatedAt: strPtr("2026-03-01T00:00:02Z")},
		{ID: "orca-b", Priority: intPtr(1), CreatedAt: strPtr("2026-03-01T00:00:01Z")},
	}

	got := Build(issues, 1)
	wantAssignments := []string{"orca-b"}
	if ids := assignmentIDs(got); !reflect.DeepEqual(ids, wantAssignments) {
		t.Fatalf("assignment mismatch\nwant=%#v\ngot =%#v", wantAssignments, ids)
	}
	assertHeldReason(t, got, "orca-a", "not-enough-slots")
}

func assignmentIDs(out model.PlanOutput) []string {
	ids := make([]string, 0, len(out.Assignments))
	for _, assignment := range out.Assignments {
		ids = append(ids, assignment.IssueID)
	}
	return ids
}

func assertHeldReason(t *testing.T, out model.PlanOutput, issueID, reason string) {
	t.Helper()
	for _, item := range out.Held {
		if item.IssueID == issueID && item.ReasonCode == reason {
			return
		}
	}
	t.Fatalf("held reason not found: issue=%q reason=%q", issueID, reason)
}

func assertHeldConflictKey(t *testing.T, out model.PlanOutput, issueID, key string) {
	t.Helper()
	for _, item := range out.Held {
		if item.IssueID != issueID {
			continue
		}
		if item.ConflictKey == nil || *item.ConflictKey != key {
			t.Fatalf("conflict key mismatch for %q: got %#v want %q", issueID, item.ConflictKey, key)
		}
		return
	}
	t.Fatalf("held issue not found: %q", issueID)
}

func intPtr(v int) *int       { return &v }
func strPtr(v string) *string { return &v }
