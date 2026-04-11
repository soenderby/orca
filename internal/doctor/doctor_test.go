package doctor

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/soenderby/orca/internal/model"
)

func TestRun_NonRepoContractFields(t *testing.T) {
	res := Run(Config{
		Cwd:      "/tmp/not-a-repo",
		OrcaHome: "/opt/orca",
		LookPath: func(string) (string, error) { return "", errors.New("missing") },
		RunCommand: func(dir string, name string, args ...string) (string, error) {
			_ = dir
			_ = name
			_ = args
			return "", errors.New("command failed")
		},
	})

	if res.SchemaVersion != 1 {
		t.Fatalf("schema version mismatch: %d", res.SchemaVersion)
	}
	if res.OK {
		t.Fatal("expected non-repo result to fail")
	}
	if res.Summary.HardFail == 0 {
		t.Fatal("expected hard failures in non-repo run")
	}

	repoCheck, ok := findCheck(res.Checks, "repo.git_worktree")
	if !ok {
		t.Fatalf("missing repo.git_worktree check")
	}
	if repoCheck.Status != "fail" || !repoCheck.HardRequirement {
		t.Fatalf("repo.git_worktree should be hard fail: %#v", repoCheck)
	}
	if strings.TrimSpace(repoCheck.Remediation.Summary) == "" {
		t.Fatalf("repo.git_worktree remediation summary should be present: %#v", repoCheck)
	}
	if !contains(repoCheck.Remediation.Commands, "cd /path/to/orca") {
		t.Fatalf("expected cd remediation command: %#v", repoCheck.Remediation.Commands)
	}
	if !containsSubstring(repoCheck.Remediation.Commands, "orca.sh doctor") {
		t.Fatalf("expected orca.sh doctor remediation command: %#v", repoCheck.Remediation.Commands)
	}

	// JSON contract: remediation.commands must always be an array.
	raw, err := json.Marshal(res)
	if err != nil {
		t.Fatalf("marshal doctor result: %v", err)
	}
	var doc map[string]any
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatalf("unmarshal doctor result: %v", err)
	}
	checks, ok := doc["checks"].([]any)
	if !ok || len(checks) == 0 {
		t.Fatalf("checks array missing or empty: %#v", doc["checks"])
	}
	for _, item := range checks {
		obj, _ := item.(map[string]any)
		rem, _ := obj["remediation"].(map[string]any)
		if _, ok := rem["commands"].([]any); !ok {
			t.Fatalf("remediation.commands must be array, got: %#v", rem["commands"])
		}
	}
}

func TestRenderHuman(t *testing.T) {
	res := model.DoctorResult{
		SchemaVersion: 1,
		OK:            true,
		Summary:       model.DoctorSummary{Pass: 1, Fail: 0, Warn: 0, HardFail: 0},
		Checks: []model.DoctorCheck{{
			ID:              "dep.git.present",
			Title:           "Required binary present: git",
			Category:        "dependency",
			Status:          "pass",
			Severity:        "info",
			HardRequirement: true,
			Message:         "Found git",
			Remediation:     model.DoctorRemediation{Summary: "", Commands: []string{}},
		}},
	}
	text := RenderHuman(res)
	if !strings.Contains(text, "Orca Doctor") || !strings.Contains(text, "Result: ready") {
		t.Fatalf("unexpected human output: %s", text)
	}
}

func findCheck(checks []model.DoctorCheck, id string) (model.DoctorCheck, bool) {
	for _, c := range checks {
		if c.ID == id {
			return c, true
		}
	}
	return model.DoctorCheck{}, false
}

func contains(items []string, want string) bool {
	for _, item := range items {
		if item == want {
			return true
		}
	}
	return false
}

func containsSubstring(items []string, wantSubstr string) bool {
	for _, item := range items {
		if strings.Contains(item, wantSubstr) {
			return true
		}
	}
	return false
}
