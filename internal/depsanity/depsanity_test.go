package depsanity

import (
	"reflect"
	"sort"
	"testing"

	"github.com/soenderby/orca/internal/model"
)

func TestCheck_RegressionParity(t *testing.T) {
	issues := []Issue{
		{
			ID:     "orca-a",
			Status: "open",
			Dependencies: []Dependency{{
				IssueID:     "orca-a",
				DependsOnID: "orca-a",
				Type:        "blocks",
			}},
		},
		{
			ID:     "orca-b",
			Status: "open",
			Dependencies: []Dependency{{
				IssueID:     "orca-b",
				DependsOnID: "orca-c",
				Type:        "blocks",
			}},
		},
		{
			ID:     "orca-c",
			Status: "in_progress",
			Dependencies: []Dependency{{
				IssueID:     "orca-c",
				DependsOnID: "orca-b",
				Type:        "blocks",
			}},
		},
		{
			ID:     "orca-d",
			Status: "open",
			Dependencies: []Dependency{
				{IssueID: "orca-d", DependsOnID: "orca-e", Type: "parent-child"},
				{IssueID: "orca-d", DependsOnID: "orca-e", Type: "blocks"},
			},
		},
		{ID: "orca-e", Status: "open"},
		{
			ID:     "orca-f",
			Status: "closed",
			Dependencies: []Dependency{{
				IssueID:     "orca-f",
				DependsOnID: "orca-f",
				Type:        "blocks",
			}},
		},
	}

	report := Check(issues)
	if report.CheckerVersion != "v1" {
		t.Fatalf("checker version mismatch: %q", report.CheckerVersion)
	}
	if report.Summary.HazardCount != 4 {
		t.Fatalf("hazard count mismatch: got %d want 4", report.Summary.HazardCount)
	}

	codes := hazardCodes(report)
	wantCodes := []string{
		"active-dependency-cycle",
		"mixed-parent-child-blocks",
		"mutual-blocks-active",
		"self-dependency-active",
	}
	if !reflect.DeepEqual(codes, wantCodes) {
		t.Fatalf("hazard codes mismatch\nwant=%#v\ngot =%#v", wantCodes, codes)
	}

	assertHazardDetail(t, report, "self-dependency-active", "issue_id", "orca-a")
	assertHazardDetail(t, report, "mutual-blocks-active", "issue_a", "orca-b")
	assertHazardDetail(t, report, "mutual-blocks-active", "issue_b", "orca-c")
	assertCycleNodesContain(t, report, "orca-b", "orca-c")
	assertHazardDetail(t, report, "mixed-parent-child-blocks", "issue_a", "orca-d")
	assertHazardDetail(t, report, "mixed-parent-child-blocks", "issue_b", "orca-e")
}

func TestCheck_NoHazards(t *testing.T) {
	issues := []Issue{
		{
			ID:     "orca-a",
			Status: "open",
			Dependencies: []Dependency{{
				IssueID:     "orca-a",
				DependsOnID: "orca-b",
				Type:        "blocks",
			}},
		},
		{ID: "orca-b", Status: "open"},
	}

	report := Check(issues)
	if report.Summary.HazardCount != 0 {
		t.Fatalf("expected no hazards, got %#v", report.Hazards)
	}
}

func TestCheck_ClosedSelfDependencyNotFlagged(t *testing.T) {
	issues := []Issue{
		{
			ID:     "orca-a",
			Status: "closed",
			Dependencies: []Dependency{{
				IssueID:     "orca-a",
				DependsOnID: "orca-a",
				Type:        "blocks",
			}},
		},
	}

	report := Check(issues)
	if report.Summary.HazardCount != 0 {
		t.Fatalf("expected no active hazards for closed issue, got %#v", report.Hazards)
	}
}

func hazardCodes(report model.DepSanityReport) []string {
	codes := make([]string, 0, len(report.Hazards))
	for _, h := range report.Hazards {
		codes = append(codes, h.Code)
	}
	sort.Strings(codes)
	return codes
}

func assertHazardDetail(t *testing.T, report model.DepSanityReport, code, key, want string) {
	t.Helper()
	for _, h := range report.Hazards {
		if h.Code != code {
			continue
		}
		if got, _ := h.Details[key].(string); got == want {
			return
		}
	}
	t.Fatalf("hazard detail not found: code=%q key=%q want=%q", code, key, want)
}

func assertCycleNodesContain(t *testing.T, report model.DepSanityReport, nodes ...string) {
	t.Helper()
	for _, h := range report.Hazards {
		if h.Code != "active-dependency-cycle" {
			continue
		}
		rawNodes, ok := h.Details["cycle_nodes"]
		if !ok {
			continue
		}

		var got []string
		switch vals := rawNodes.(type) {
		case []string:
			got = vals
		case []any:
			for _, v := range vals {
				str, ok := v.(string)
				if ok {
					got = append(got, str)
				}
			}
		}

		contains := map[string]struct{}{}
		for _, v := range got {
			contains[v] = struct{}{}
		}
		for _, want := range nodes {
			if _, ok := contains[want]; !ok {
				t.Fatalf("cycle nodes missing %q from %#v", want, got)
			}
		}
		return
	}
	t.Fatalf("active-dependency-cycle hazard not found")
}
