// Package depsanity checks queue dependency graph hazards.
package depsanity

import (
	"sort"
	"strings"

	"github.com/soenderby/orca/internal/model"
)

// Issue models the subset of queue issue fields needed for dependency checks.
type Issue struct {
	ID           string
	Status       string
	Dependencies []Dependency
}

// Dependency models one issue dependency edge.
type Dependency struct {
	IssueID     string
	DependsOnID string
	Type        string
}

// Check runs dependency sanity checks and returns a v1 report.
func Check(issues []Issue) model.DepSanityReport {
	activeIssues := map[string]struct{}{}
	activeNodesPresent := map[string]struct{}{}
	adjacency := map[string]map[string]struct{}{}
	indegree := map[string]int{}
	activeBlocksEdge := map[string]struct{}{}
	undirectedTypes := map[string]map[string]struct{}{}

	hazards := make([]model.DepSanityHazard, 0)
	depCount := 0

	for _, issue := range issues {
		if issue.ID == "" {
			continue
		}
		status := issue.Status
		if status == "" {
			status = "open"
		}
		if isActiveStatus(status) {
			activeIssues[issue.ID] = struct{}{}
			activeNodesPresent[issue.ID] = struct{}{}
			if _, ok := adjacency[issue.ID]; !ok {
				adjacency[issue.ID] = map[string]struct{}{}
			}
			if _, ok := indegree[issue.ID]; !ok {
				indegree[issue.ID] = 0
			}
		}
	}

	for _, issue := range issues {
		for _, dep := range issue.Dependencies {
			depCount++
			fromID := dep.IssueID
			toID := dep.DependsOnID
			depType := dep.Type
			if depType == "" {
				depType = "blocks"
			}
			if fromID == "" || toID == "" {
				continue
			}

			pair := undirectedPair(fromID, toID)
			if _, ok := undirectedTypes[pair]; !ok {
				undirectedTypes[pair] = map[string]struct{}{}
			}
			undirectedTypes[pair][depType] = struct{}{}

			if _, ok := activeIssues[fromID]; !ok {
				continue
			}
			if _, ok := activeIssues[toID]; !ok {
				continue
			}

			if fromID == toID {
				hazards = append(hazards, hazard("self-dependency-active", map[string]any{
					"issue_id": fromID,
					"type":     depType,
				}))
				continue
			}

			activeNodesPresent[fromID] = struct{}{}
			activeNodesPresent[toID] = struct{}{}
			if _, ok := adjacency[fromID]; !ok {
				adjacency[fromID] = map[string]struct{}{}
			}
			if _, exists := adjacency[fromID][toID]; !exists {
				adjacency[fromID][toID] = struct{}{}
				indegree[toID] = indegree[toID] + 1
				if _, ok := indegree[fromID]; !ok {
					indegree[fromID] = 0
				}
			}

			if depType == "blocks" {
				activeBlocksEdge[fromID+"|"+toID] = struct{}{}
			}
		}
	}

	for pair, types := range undirectedTypes {
		if hasType(types, "parent-child") && hasType(types, "blocks") {
			left, right := splitPair(pair)
			hazards = append(hazards, hazard("mixed-parent-child-blocks", map[string]any{
				"issue_a": left,
				"issue_b": right,
			}))
		}
	}

	for edge := range activeBlocksEdge {
		fromID, toID := splitPair(edge)
		reverse := toID + "|" + fromID
		if _, ok := activeBlocksEdge[reverse]; !ok {
			continue
		}
		if fromID > toID {
			continue
		}
		hazards = append(hazards, hazard("mutual-blocks-active", map[string]any{
			"issue_a": fromID,
			"issue_b": toID,
		}))
	}

	removed := 0
	queue := topoQueue(activeNodesPresent, indegree)
	queued := map[string]struct{}{}
	for _, node := range queue {
		queued[node] = struct{}{}
	}

	for len(queue) > 0 {
		current := queue[0]
		queue = queue[1:]
		removed++

		neighbors := sortedKeys(adjacency[current])
		for _, neighbor := range neighbors {
			indegree[neighbor] = indegree[neighbor] - 1
			if indegree[neighbor] == 0 {
				if _, ok := queued[neighbor]; !ok {
					queue = append(queue, neighbor)
					queued[neighbor] = struct{}{}
				}
			}
		}
		if len(queue) > 1 {
			sort.Strings(queue)
		}
	}

	totalActiveNodes := len(activeNodesPresent)
	if removed < totalActiveNodes {
		cycleNodes := make([]string, 0)
		for node := range activeNodesPresent {
			if indegree[node] > 0 {
				cycleNodes = append(cycleNodes, node)
			}
		}
		if len(cycleNodes) > 0 {
			sort.Strings(cycleNodes)
			hazards = append(hazards, hazard("active-dependency-cycle", map[string]any{
				"cycle_nodes": cycleNodes,
			}))
		}
	}

	sort.Slice(hazards, func(i, j int) bool {
		li := hazards[i]
		lj := hazards[j]
		if li.Code != lj.Code {
			return li.Code < lj.Code
		}
		liIssueID, _ := li.Details["issue_id"].(string)
		ljIssueID, _ := lj.Details["issue_id"].(string)
		if liIssueID != ljIssueID {
			return liIssueID < ljIssueID
		}
		liIssueA, _ := li.Details["issue_a"].(string)
		ljIssueA, _ := lj.Details["issue_a"].(string)
		if liIssueA != ljIssueA {
			return liIssueA < ljIssueA
		}
		liIssueB, _ := li.Details["issue_b"].(string)
		ljIssueB, _ := lj.Details["issue_b"].(string)
		return liIssueB < ljIssueB
	})

	return model.DepSanityReport{
		CheckerVersion: "v1",
		Input: model.DepSanityInput{
			IssueCount:      len(issues),
			DependencyCount: depCount,
		},
		Hazards: hazards,
		Summary: model.DepSanitySummary{
			HazardCount: len(hazards),
			StrictMode:  false,
		},
	}
}

func isActiveStatus(status string) bool {
	switch status {
	case "open", "in_progress", "blocked":
		return true
	default:
		return false
	}
}

func hazard(code string, details map[string]any) model.DepSanityHazard {
	return model.DepSanityHazard{
		Code:     code,
		Severity: "error",
		Details:  details,
	}
}

func undirectedPair(a, b string) string {
	if a < b {
		return a + "|" + b
	}
	return b + "|" + a
}

func splitPair(pair string) (string, string) {
	parts := strings.SplitN(pair, "|", 2)
	if len(parts) != 2 {
		return pair, ""
	}
	return parts[0], parts[1]
}

func hasType(types map[string]struct{}, kind string) bool {
	_, ok := types[kind]
	return ok
}

func sortedKeys(m map[string]struct{}) []string {
	if len(m) == 0 {
		return nil
	}
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func topoQueue(nodes map[string]struct{}, indegree map[string]int) []string {
	queue := make([]string, 0)
	for node := range nodes {
		if indegree[node] == 0 {
			queue = append(queue, node)
		}
	}
	sort.Strings(queue)
	return queue
}
