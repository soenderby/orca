package main

import (
	"bytes"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/soenderby/orca/internal/loop"
)

func TestLoadIssueLabels(t *testing.T) {
	path := filepath.Join(t.TempDir(), "issues.jsonl")
	data := "" +
		"{\"id\":\"orca-1\",\"labels\":[\"ck:queue\",\"meta:tracker\"]}\n" +
		"{\"id\":\"orca-2\",\"labels\":[]}\n"
	if err := os.WriteFile(path, []byte(data), 0o644); err != nil {
		t.Fatalf("write issues jsonl: %v", err)
	}

	got, err := loadIssueLabels(path)
	if err != nil {
		t.Fatalf("load issue labels: %v", err)
	}

	want := map[string][]string{
		"orca-1": {"ck:queue", "meta:tracker"},
		"orca-2": {},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("labels mismatch\nwant=%#v\ngot =%#v", want, got)
	}
}

func TestLoadDepIssues(t *testing.T) {
	path := filepath.Join(t.TempDir(), "issues.jsonl")
	data := "" +
		"{\"id\":\"orca-a\",\"status\":\"open\",\"dependencies\":[{\"issue_id\":\"orca-a\",\"depends_on_id\":\"orca-b\",\"type\":\"blocks\"}]}\n" +
		"{\"id\":\"orca-b\",\"status\":\"in_progress\",\"dependencies\":[]}\n"
	if err := os.WriteFile(path, []byte(data), 0o644); err != nil {
		t.Fatalf("write issues jsonl: %v", err)
	}

	issues, issueCount, depCount, err := loadDepIssues(path)
	if err != nil {
		t.Fatalf("load dep issues: %v", err)
	}
	if issueCount != 2 || depCount != 1 {
		t.Fatalf("counts mismatch: issueCount=%d depCount=%d", issueCount, depCount)
	}
	if len(issues) != 2 {
		t.Fatalf("issues len mismatch: %d", len(issues))
	}
	if issues[0].ID != "orca-a" || len(issues[0].Dependencies) != 1 {
		t.Fatalf("unexpected first issue: %#v", issues[0])
	}
}

func TestEnvIntOrDefault(t *testing.T) {
	const key = "ORCA_TEST_ENV_INT"
	defer os.Unsetenv(key)

	os.Unsetenv(key)
	if got := envIntOrDefault(key, 7); got != 7 {
		t.Fatalf("missing env should use default, got %d", got)
	}

	os.Setenv(key, "9")
	if got := envIntOrDefault(key, 7); got != 9 {
		t.Fatalf("expected parsed env int, got %d", got)
	}

	os.Setenv(key, "-1")
	if got := envIntOrDefault(key, 7); got != 7 {
		t.Fatalf("negative env should use default, got %d", got)
	}
}

func TestQueueReadMain_FailFastUnsupportedFlags(t *testing.T) {
	var out bytes.Buffer
	var errOut bytes.Buffer

	code := run([]string{"queue-read-main", "--lock-helper", "/tmp/fake", "--", "br", "ready", "--json"}, &out, &errOut)
	if code == 0 {
		t.Fatal("expected non-zero exit for unsupported --lock-helper")
	}
	if !strings.Contains(errOut.String(), "not supported") {
		t.Fatalf("expected unsupported error message, got: %s", errOut.String())
	}

	errOut.Reset()
	code = run([]string{"queue-read-main", "--fallback", "worktree", "--", "br", "ready", "--json"}, &out, &errOut)
	if code == 0 {
		t.Fatal("expected non-zero exit for unsupported --fallback")
	}
	if !strings.Contains(errOut.String(), "not supported") {
		t.Fatalf("expected unsupported error message, got: %s", errOut.String())
	}
}

func TestQueueWriteMain_FailFastUnsupportedFlags(t *testing.T) {
	var out bytes.Buffer
	var errOut bytes.Buffer

	code := run([]string{"queue-write-main", "--lock-helper", "/tmp/fake", "--actor", "agent-1", "--", "br", "update", "orca-1", "--claim", "--actor", "agent-1", "--json"}, &out, &errOut)
	if code == 0 {
		t.Fatal("expected non-zero exit for unsupported --lock-helper")
	}
	if !strings.Contains(errOut.String(), "not supported") {
		t.Fatalf("expected unsupported error message, got: %s", errOut.String())
	}

	errOut.Reset()
	code = run([]string{"queue-write-main", "--message", "x", "--actor", "agent-1", "--", "br", "update", "orca-1", "--claim", "--actor", "agent-1", "--json"}, &out, &errOut)
	if code == 0 {
		t.Fatal("expected non-zero exit for unsupported --message")
	}
	if !strings.Contains(errOut.String(), "not supported") {
		t.Fatalf("expected unsupported error message, got: %s", errOut.String())
	}
}

func TestBuildLoopEnv_IncludesPromptExpectedAgentVars(t *testing.T) {
	env := buildLoopEnv(
		loop.RunInvocation{RunNumber: 3, Paths: loop.RunPaths{SummaryJSON: "/tmp/summary.json", RunLog: "/tmp/run.log"}},
		"agent-7",
		"session-xyz",
		"/tmp/worktree",
		"/tmp/orca-go",
		"self-select",
		"",
		"/tmp/repo",
		"/tmp/with-lock.sh",
		"/tmp/queue-read-main.sh",
		"/tmp/queue-write-main.sh",
		"/tmp/merge-main.sh",
		"/tmp/br-guard.sh",
		"merge",
		120,
		"",
	)

	if !containsEnvKV(env, "AGENT_NAME", "agent-7") {
		t.Fatalf("missing AGENT_NAME in env: %#v", env)
	}
	if !containsEnvKV(env, "AGENT_SESSION_ID", "session-xyz") {
		t.Fatalf("missing AGENT_SESSION_ID in env: %#v", env)
	}
	if !containsEnvKV(env, "WORKTREE", "/tmp/worktree") {
		t.Fatalf("missing WORKTREE in env: %#v", env)
	}
	if !containsEnvKV(env, "ORCA_BIN_PATH", "/tmp/orca-go") {
		t.Fatalf("missing ORCA_BIN_PATH in env: %#v", env)
	}
}

func containsEnvKV(env []string, key, want string) bool {
	prefix := key + "="
	for _, item := range env {
		if strings.HasPrefix(item, prefix) {
			return strings.TrimPrefix(item, prefix) == want
		}
	}
	return false
}
