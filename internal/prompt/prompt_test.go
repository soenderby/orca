package prompt

import (
	"strings"
	"testing"
)

func TestRender_AllPlaceholdersReplaced(t *testing.T) {
	template := "agent=__AGENT_NAME__ worktree=__WORKTREE__ repo=__PRIMARY_REPO__ lock=__WITH_LOCK_PATH__ qread=__QUEUE_READ_MAIN_PATH__ qwrite=__QUEUE_WRITE_MAIN_PATH__ merge=__MERGE_MAIN_PATH__ mode=__ASSIGNMENT_MODE__ issue=__ASSIGNED_ISSUE_ID__ summary=__SUMMARY_JSON_PATH__"
	values := map[string]string{
		"AGENT_NAME":            "agent-1",
		"WORKTREE":              "/tmp/wt",
		"PRIMARY_REPO":          "/tmp/repo",
		"WITH_LOCK_PATH":        "/tmp/with-lock.sh",
		"QUEUE_READ_MAIN_PATH":  "/tmp/queue-read-main.sh",
		"QUEUE_WRITE_MAIN_PATH": "/tmp/queue-write-main.sh",
		"MERGE_MAIN_PATH":       "/tmp/merge-main.sh",
		"ASSIGNMENT_MODE":       "assigned",
		"ASSIGNED_ISSUE_ID":     "orca-1",
		"SUMMARY_JSON_PATH":     "/tmp/summary.json",
	}

	got, err := Render(template, values)
	if err != nil {
		t.Fatalf("render returned error: %v", err)
	}

	want := "agent=agent-1 worktree=/tmp/wt repo=/tmp/repo lock=/tmp/with-lock.sh qread=/tmp/queue-read-main.sh qwrite=/tmp/queue-write-main.sh merge=/tmp/merge-main.sh mode=assigned issue=orca-1 summary=/tmp/summary.json"
	if got != want {
		t.Fatalf("render mismatch\nwant: %q\n got: %q", want, got)
	}
}

func TestRender_UnknownPlaceholderFailsFast(t *testing.T) {
	template := "known=__AGENT_NAME__ unknown=__NOT_A_REAL_PLACEHOLDER__"
	_, err := Render(template, map[string]string{"AGENT_NAME": "agent-1"})
	if err == nil {
		t.Fatal("expected error for unknown placeholder, got nil")
	}
	if !strings.Contains(err.Error(), "__NOT_A_REAL_PLACEHOLDER__") {
		t.Fatalf("error does not mention unknown placeholder: %v", err)
	}
}

func TestValidateTemplate_CollectsAndSortsUnknownPlaceholders(t *testing.T) {
	template := "bad=__ZZZ__ also=__AAA__ again=__ZZZ__"
	err := ValidateTemplate(template)
	if err == nil {
		t.Fatal("expected unknown-placeholder error, got nil")
	}
	if err.Error() != "unknown placeholders: __AAA__,__ZZZ__" {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestRender_EmptyTemplate(t *testing.T) {
	got, err := Render("", map[string]string{"AGENT_NAME": "agent-1"})
	if err != nil {
		t.Fatalf("render returned error: %v", err)
	}
	if got != "" {
		t.Fatalf("expected empty output, got %q", got)
	}
}

func TestRender_MissingValuesBecomeEmptyForKnownPlaceholders(t *testing.T) {
	template := "agent=__AGENT_NAME__ issue=__ASSIGNED_ISSUE_ID__"
	got, err := Render(template, map[string]string{"AGENT_NAME": "agent-1"})
	if err != nil {
		t.Fatalf("render returned error: %v", err)
	}
	want := "agent=agent-1 issue="
	if got != want {
		t.Fatalf("render mismatch\nwant: %q\n got: %q", want, got)
	}
}
