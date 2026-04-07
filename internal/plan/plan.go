// Package plan implements deterministic issue-to-slot assignment.
package plan

import (
	"math"
	"sort"
	"strings"

	"github.com/soenderby/orca/internal/model"
)

// Issue is one ready issue considered by the planner.
type Issue struct {
	ID        string
	Priority  *int
	CreatedAt *string
	Labels    []string
}

// Build computes the planner v1 assignment output.
func Build(issues []Issue, slots int) model.PlanOutput {
	if slots < 0 {
		slots = 0
	}

	sorted := append([]Issue(nil), issues...)
	sort.Slice(sorted, func(i, j int) bool {
		left := sorted[i]
		right := sorted[j]

		lp := priorityOrDefault(left.Priority)
		rp := priorityOrDefault(right.Priority)
		if lp != rp {
			return lp < rp
		}

		lc := ""
		rc := ""
		if left.CreatedAt != nil {
			lc = *left.CreatedAt
		}
		if right.CreatedAt != nil {
			rc = *right.CreatedAt
		}
		if lc != rc {
			return lc < rc
		}

		return left.ID < right.ID
	})

	assigned := make([]Issue, 0, slots)
	held := make([]model.PlanHeldIssue, 0)
	decisions := make([]model.PlanDecisionRow, 0, len(sorted))
	usedCK := make(map[string]struct{})
	hasExclusiveAssignment := false

	for _, issue := range sorted {
		labels := append([]string(nil), issue.Labels...)
		isExclusive := hasLabel(labels, "px:exclusive")
		isTracker := hasLabel(labels, "meta:tracker")
		issueCK := contentionKeys(labels)
		sharedCK := sharedContentionKeys(issueCK, usedCK)

		switch {
		case isTracker:
			held = append(held, model.PlanHeldIssue{
				IssueID:    issue.ID,
				ReasonCode: "tracker-issue",
			})
			decisions = append(decisions, model.PlanDecisionRow{
				IssueID:    issue.ID,
				Action:     "held",
				ReasonCode: "tracker-issue",
				Labels:     labels,
			})

		case len(assigned) >= slots:
			held = append(held, model.PlanHeldIssue{
				IssueID:    issue.ID,
				ReasonCode: "not-enough-slots",
			})
			decisions = append(decisions, model.PlanDecisionRow{
				IssueID:    issue.ID,
				Action:     "held",
				ReasonCode: "not-enough-slots",
				Labels:     labels,
			})

		case hasExclusiveAssignment:
			held = append(held, model.PlanHeldIssue{
				IssueID:    issue.ID,
				ReasonCode: "exclusive-already-selected",
			})
			decisions = append(decisions, model.PlanDecisionRow{
				IssueID:    issue.ID,
				Action:     "held",
				ReasonCode: "exclusive-already-selected",
				Labels:     labels,
			})

		case isExclusive && len(assigned) > 0:
			held = append(held, model.PlanHeldIssue{
				IssueID:    issue.ID,
				ReasonCode: "exclusive-conflict",
			})
			decisions = append(decisions, model.PlanDecisionRow{
				IssueID:    issue.ID,
				Action:     "held",
				ReasonCode: "exclusive-conflict",
				Labels:     labels,
			})

		case len(sharedCK) > 0:
			conflict := sharedCK[0]
			held = append(held, model.PlanHeldIssue{
				IssueID:     issue.ID,
				ReasonCode:  "contention-key-conflict",
				ConflictKey: &conflict,
			})
			decisions = append(decisions, model.PlanDecisionRow{
				IssueID:     issue.ID,
				Action:      "held",
				ReasonCode:  "contention-key-conflict",
				ConflictKey: &conflict,
				Labels:      labels,
			})

		default:
			assigned = append(assigned, issue)
			decisions = append(decisions, model.PlanDecisionRow{
				IssueID:    issue.ID,
				Action:     "assigned",
				ReasonCode: "scheduled",
				Labels:     labels,
			})
			if isExclusive {
				hasExclusiveAssignment = true
			}
			for _, key := range issueCK {
				usedCK[key] = struct{}{}
			}
		}
	}

	assignments := make([]model.PlanAssignment, 0, len(assigned))
	for i, issue := range assigned {
		assignments = append(assignments, model.PlanAssignment{
			Slot:      i + 1,
			IssueID:   issue.ID,
			Priority:  issue.Priority,
			CreatedAt: issue.CreatedAt,
			Labels:    append([]string(nil), issue.Labels...),
		})
	}

	return model.PlanOutput{
		PlannerVersion: "v1",
		Input: model.PlanInputSummary{
			Slots:      slots,
			ReadyCount: len(sorted),
		},
		Assignments: assignments,
		Held:        held,
		Decisions:   decisions,
	}
}

func priorityOrDefault(p *int) int {
	if p == nil {
		return math.MaxInt32
	}
	return *p
}

func hasLabel(labels []string, want string) bool {
	for _, label := range labels {
		if label == want {
			return true
		}
	}
	return false
}

func contentionKeys(labels []string) []string {
	seen := map[string]struct{}{}
	keys := make([]string, 0)
	for _, label := range labels {
		if !strings.HasPrefix(label, "ck:") {
			continue
		}
		key := strings.TrimPrefix(label, "ck:")
		if _, ok := seen[key]; ok {
			continue
		}
		seen[key] = struct{}{}
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func sharedContentionKeys(keys []string, used map[string]struct{}) []string {
	shared := make([]string, 0)
	for _, key := range keys {
		if _, ok := used[key]; ok {
			shared = append(shared, key)
		}
	}
	sort.Strings(shared)
	return shared
}
