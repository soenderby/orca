package start

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/soenderby/orca/internal/queue"
	"github.com/soenderby/orca/internal/tmux"
	"github.com/soenderby/orca/internal/worktree"
)

type fakeTmux struct {
	sessions map[string]struct{}
}

func newFakeTmux() *fakeTmux {
	return &fakeTmux{sessions: map[string]struct{}{}}
}

func (f *fakeTmux) HasSession(name string) (bool, error) {
	_, ok := f.sessions[name]
	return ok, nil
}

func (f *fakeTmux) NewSession(name, command string) error {
	_ = command
	f.sessions[name] = struct{}{}
	return nil
}

func (f *fakeTmux) ListSessions() ([]tmux.SessionInfo, error) {
	out := make([]tmux.SessionInfo, 0, len(f.sessions))
	for name := range f.sessions {
		out = append(out, tmux.SessionInfo{Name: name})
	}
	return out, nil
}

type fakeQueue struct {
	ready []queue.Issue
}

func (f *fakeQueue) ReadReady() ([]queue.Issue, error) {
	return append([]queue.Issue(nil), f.ready...), nil
}

func TestRun_AssignmentLaunchCapParity(t *testing.T) {
	repo := t.TempDir()
	mkdir(t, filepath.Join(repo, ".beads"))
	mkdir(t, filepath.Join(repo, "worktrees"))
	writeFile(t, filepath.Join(repo, "ORCA_PROMPT.md"), "test prompt\n")
	writeFile(t, filepath.Join(repo, ".beads", "issues.jsonl"), strings.Join([]string{
		`{"id":"orca-exclusive","title":"exclusive","status":"open","dependencies":[],"labels":["px:exclusive"]}`,
		`{"id":"orca-normal-1","title":"n1","status":"open","dependencies":[],"labels":[]}`,
		`{"id":"orca-normal-2","title":"n2","status":"open","dependencies":[],"labels":[]}`,
	}, "\n")+"\n")

	fakeTmux := newFakeTmux()
	fakeQueue := &fakeQueue{ready: []queue.Issue{
		{ID: "orca-exclusive", Priority: intPtr(1), CreatedAt: strPtr("2026-03-01T00:00:01Z")},
		{ID: "orca-normal-1", Priority: intPtr(2), CreatedAt: strPtr("2026-03-01T00:00:02Z")},
		{ID: "orca-normal-2", Priority: intPtr(3), CreatedAt: strPtr("2026-03-01T00:00:03Z")},
	}}

	var out bytes.Buffer
	var errOut bytes.Buffer

	result, err := Run(Config{
		RepoPath:               repo,
		Count:                  2,
		SessionPrefix:          "start-cap-regression",
		AssignmentMode:         "assigned",
		MaxRuns:                1,
		NoWorkDrainMode:        "drain",
		NoWorkRetryLimit:       1,
		DepSanityMode:          "enforce",
		PromptTemplatePath:     filepath.Join(repo, "ORCA_PROMPT.md"),
		AgentCommand:           "true",
		SkipWorktreeValidation: true,
		Stdout:                 &out,
		Stderr:                 &errOut,
		Now: func() time.Time {
			return time.Date(2026, 3, 1, 0, 0, 0, 0, time.UTC)
		},
		Tmux:  fakeTmux,
		Queue: fakeQueue,
		SetupWorktrees: func(cfg worktree.SetupConfig) (*worktree.SetupResult, error) {
			for i := 1; i <= cfg.Count; i++ {
				mkdir(t, filepath.Join(cfg.RepoPath, "worktrees", fmt.Sprintf("agent-%d", i)))
			}
			return &worktree.SetupResult{BaseRef: "main"}, nil
		},
	})
	if err != nil {
		t.Fatalf("start run failed: %v\nstderr=%s\nstdout=%s", err, errOut.String(), out.String())
	}

	if result.LaunchedCount != 1 {
		t.Fatalf("expected exactly 1 launched session, got %d", result.LaunchedCount)
	}
	if len(fakeTmux.sessions) != 1 {
		t.Fatalf("expected exactly 1 tmux session, got %d", len(fakeTmux.sessions))
	}

	combined := out.String() + "\n" + errOut.String()
	requireContains(t, combined, "[start] dependency sanity: artifact=")
	requireContains(t, combined, "[start] assignment plan: artifact=")
	requireContains(t, combined, "requested_slots=2 assigned=1 held=2")
	requireContains(t, combined, "assignment held: issue=orca-normal-1 reason=exclusive-already-selected")
	requireContains(t, combined, "assignment decision: issue=orca-exclusive action=assigned reason=scheduled")
	requireContains(t, combined, "assigned fewer sessions than requested_slots=2; held_reason_counts=exclusive-already-selected=2")
	requireContains(t, combined, "launch summary: requested=2 running=0 ready=3 launched=1")
}

func TestRun_AssignedContinuousRejected(t *testing.T) {
	repo := t.TempDir()
	mkdir(t, filepath.Join(repo, ".beads"))
	writeFile(t, filepath.Join(repo, "ORCA_PROMPT.md"), "test prompt\n")

	_, err := Run(Config{
		RepoPath:           repo,
		Count:              1,
		AssignmentMode:     "assigned",
		MaxRuns:            0,
		NoWorkDrainMode:    "drain",
		NoWorkRetryLimit:   1,
		DepSanityMode:      "off",
		PromptTemplatePath: filepath.Join(repo, "ORCA_PROMPT.md"),
		Tmux:               newFakeTmux(),
		Queue:              &fakeQueue{},
	})
	if err == nil {
		t.Fatal("expected assigned mode + continuous to be rejected")
	}
	requireContains(t, err.Error(), "--continuous is not supported when ORCA_ASSIGNMENT_MODE=assigned")
}

func requireContains(t *testing.T, got, needle string) {
	t.Helper()
	if !strings.Contains(got, needle) {
		t.Fatalf("expected output to contain %q\nfull output:\n%s", needle, got)
	}
}

func mkdir(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(path, 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", path, err)
	}
}

func writeFile(t *testing.T, path string, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir parent for %s: %v", path, err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

func intPtr(v int) *int       { return &v }
func strPtr(v string) *string { return &v }
