package status

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/soenderby/orca/internal/model"
	"github.com/soenderby/orca/internal/tmux"
)

func TestCollect_BasicSnapshot(t *testing.T) {
	repo := t.TempDir()
	mkdir(t, filepath.Join(repo, ".beads"))
	mkdir(t, filepath.Join(repo, "agent-logs", "sessions", "2026", "04", "07", "orca-agent-1-20260407T120000Z", "runs", "0001-20260407T120001000000000Z"))
	writeFile(t,
		filepath.Join(repo, "agent-logs", "sessions", "2026", "04", "07", "orca-agent-1-20260407T120000Z", "runs", "0001-20260407T120001000000000Z", "summary.json"),
		`{"result":"completed","issue_id":"orca-123"}`,
	)
	writeFile(t, filepath.Join(repo, "agent-logs", "metrics.jsonl"), strings.TrimSpace(`
{"timestamp":"2026-04-07T12:00:00Z","agent_name":"agent-1","result":"completed","issue_id":"orca-123","durations_seconds":{"iteration_total":11},"tokens_used":42}
`)+"\n")

	now := time.Date(2026, 4, 7, 12, 0, 30, 0, time.UTC)
	out, err := Collect(Config{
		RepoPath:      repo,
		SessionPrefix: "orca-agent",
		Now:           func() time.Time { return now },
		LookPath: func(bin string) (string, error) {
			if bin == "tmux" || bin == "br" {
				return "/fake/" + bin, nil
			}
			return "", os.ErrNotExist
		},
		ListSessions: func() ([]tmux.SessionInfo, error) {
			return []tmux.SessionInfo{{Name: "orca-agent-1"}, {Name: "other"}}, nil
		},
		RunCommand: func(dir string, name string, args ...string) (string, error) {
			_ = dir
			if name != "br" {
				return "", os.ErrInvalid
			}
			joined := strings.Join(args, " ")
			switch joined {
			case "--version":
				return "br-test", nil
			case "ready --json":
				return `[{"id":"orca-1"},{"id":"orca-2"}]`, nil
			case "list --status in_progress --json":
				return `[{"id":"orca-3"}]`, nil
			default:
				return "", os.ErrInvalid
			}
		},
	})
	if err != nil {
		t.Fatalf("collect: %v", err)
	}

	if out.ActiveSessions != 1 {
		t.Fatalf("active sessions mismatch: %d", out.ActiveSessions)
	}
	if out.Queue.Ready != 2 || out.Queue.InProgress != 1 {
		t.Fatalf("queue mismatch: %#v", out.Queue)
	}
	if out.BR.Version != "br-test" || !out.BR.Workspace {
		t.Fatalf("br mismatch: %#v", out.BR)
	}
	if len(out.Sessions) != 1 {
		t.Fatalf("sessions mismatch: %#v", out.Sessions)
	}
	row := out.Sessions[0]
	if row.TmuxSession != "orca-agent-1" || row.SessionID == nil || *row.SessionID != "orca-agent-1-20260407T120000Z" {
		t.Fatalf("session identity mismatch: %#v", row)
	}
	if row.AgentName == nil || *row.AgentName != "1" {
		t.Fatalf("agent name mismatch: %#v", row.AgentName)
	}
	if row.LastResult == nil || *row.LastResult != "completed" || row.LastIssue == nil || *row.LastIssue != "orca-123" {
		t.Fatalf("session summary mismatch: %#v", row)
	}

	if out.Latest.Result == nil || *out.Latest.Result != "completed" {
		t.Fatalf("latest result mismatch: %#v", out.Latest)
	}
	if out.Latest.Duration == nil || *out.Latest.Duration != "11" {
		t.Fatalf("latest duration mismatch: %#v", out.Latest.Duration)
	}
	if out.Latest.Tokens == nil || *out.Latest.Tokens != "42" {
		t.Fatalf("latest tokens mismatch: %#v", out.Latest.Tokens)
	}
	if out.Latest.Age == nil || *out.Latest.Age != "30s ago" {
		t.Fatalf("latest age mismatch: %#v", out.Latest.Age)
	}

	if _, err := json.Marshal(out); err != nil {
		t.Fatalf("status output should marshal: %v", err)
	}
}

func TestRenderHuman_NoSessions(t *testing.T) {
	text := RenderHuman(model.StatusOutput{
		GeneratedAt:    "2026-04-07T12:00:00Z",
		ActiveSessions: 0,
		Queue:          model.StatusQueue{Ready: 0, InProgress: 0},
		BR:             model.StatusBR{Version: "unavailable", Workspace: false},
		Sessions:       []model.StatusSession{},
		Latest:         model.StatusLatest{},
	})
	if !strings.Contains(text, "== orca status ==") {
		t.Fatalf("missing header: %s", text)
	}
	if !strings.Contains(text, "(no active orca sessions)") {
		t.Fatalf("missing no-session marker: %s", text)
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
