package queue

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/soenderby/orca/internal/lock"
)

type fakeLocker struct {
	calls int
	err   error
}

func (l *fakeLocker) WithLock(scope string, timeout time.Duration, fn func() error) error {
	l.calls++
	if l.err != nil {
		return l.err
	}
	return fn()
}

type fakeGitOps struct {
	branch       string
	clean        bool
	fetchPullErr error
	pushErr      error

	fetchPullCalls int
	pushCalls      int
}

func (g *fakeGitOps) CurrentBranch(string) (string, error) { return g.branch, nil }
func (g *fakeGitOps) IsClean(string) (bool, error)         { return g.clean, nil }
func (g *fakeGitOps) FetchAndPull(string) error {
	g.fetchPullCalls++
	return g.fetchPullErr
}
func (g *fakeGitOps) Push(string) error {
	g.pushCalls++
	return g.pushErr
}

type call struct {
	Dir  string
	Name string
	Args []string
}

type fakeRunner struct {
	calls []call
	stub  func(dir, name string, args ...string) (string, int, error)
}

func (r *fakeRunner) run(dir, name string, args ...string) (string, int, error) {
	r.calls = append(r.calls, call{Dir: dir, Name: name, Args: append([]string(nil), args...)})
	if r.stub != nil {
		return r.stub(dir, name, args...)
	}
	return defaultFakeResponse(name, args...)
}

func defaultFakeResponse(name string, args ...string) (string, int, error) {
	if name == "git" && reflect.DeepEqual(args, []string{"diff", "--cached", "--quiet"}) {
		return "", 0, nil
	}
	if name == "br" && len(args) >= 2 && args[0] == "ready" && args[1] == "--json" {
		return "[]", 0, nil
	}
	if name == "br" && len(args) >= 3 && args[0] == "show" && args[2] == "--json" {
		return `{"id":"orca-1"}`, 0, nil
	}
	if name == "br" && len(args) >= 4 && args[0] == "dep" && args[1] == "list" && args[3] == "--json" {
		return "[]", 0, nil
	}
	if name == "br" && len(args) >= 2 && args[0] == "create" {
		return `{"id":"orca-42"}`, 0, nil
	}
	return "", 0, nil
}

func TestNewValidation(t *testing.T) {
	if _, err := New(Config{}); err == nil {
		t.Fatal("expected repo-path validation error")
	}
}

func TestReadReady_LockGuardedReadOnMain(t *testing.T) {
	locker := &fakeLocker{}
	git := &fakeGitOps{branch: "main", clean: true}
	runner := &fakeRunner{}

	client := newTestClient(t, locker, git, runner)
	issues, err := client.ReadReady()
	if err != nil {
		t.Fatalf("read ready: %v", err)
	}
	if len(issues) != 0 {
		t.Fatalf("expected empty issues, got %#v", issues)
	}
	if locker.calls != 1 {
		t.Fatalf("expected one lock call, got %d", locker.calls)
	}

	wantBR := [][]string{{"sync", "--import-only"}, {"ready", "--json"}}
	gotBR := brCalls(runner.calls)
	if !reflect.DeepEqual(gotBR, wantBR) {
		t.Fatalf("br call order mismatch\nwant=%#v\ngot =%#v", wantBR, gotBR)
	}
}

func TestReadReady_RejectsNonMainBranch(t *testing.T) {
	client := newTestClient(
		t,
		&fakeLocker{},
		&fakeGitOps{branch: "feature/not-main", clean: true},
		&fakeRunner{},
	)

	_, err := client.ReadReady()
	if err == nil {
		t.Fatal("expected non-main branch error")
	}
	if !strings.Contains(err.Error(), "expected primary repo on main") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestMutationFlow_IncludesImportMutationFlushAndCommitWhenStaged(t *testing.T) {
	locker := &fakeLocker{}
	git := &fakeGitOps{branch: "main", clean: true}
	runner := &fakeRunner{}
	runner.stub = func(dir, name string, args ...string) (string, int, error) {
		if name == "git" && reflect.DeepEqual(args, []string{"diff", "--cached", "--quiet"}) {
			return "", 1, errors.New("staged changes present")
		}
		return defaultFakeResponse(name, args...)
	}

	client := newTestClient(t, locker, git, runner)
	if err := client.Claim("orca-1", "agent-1"); err != nil {
		t.Fatalf("claim: %v", err)
	}

	wantBR := [][]string{
		{"sync", "--import-only"},
		{"update", "orca-1", "--claim", "--actor", "agent-1", "--json"},
		{"sync", "--flush-only"},
	}
	gotBR := brCalls(runner.calls)
	if !reflect.DeepEqual(gotBR, wantBR) {
		t.Fatalf("br flow mismatch\nwant=%#v\ngot =%#v", wantBR, gotBR)
	}

	if !containsGitCall(runner.calls, []string{"add", ".beads/"}) {
		t.Fatal("expected git add .beads/")
	}
	if !containsGitCallPrefix(runner.calls, []string{"commit", "-m"}) {
		t.Fatal("expected git commit when staged changes exist")
	}
	if git.pushCalls != 1 {
		t.Fatalf("expected one push, got %d", git.pushCalls)
	}
}

func TestClaimActorRequired(t *testing.T) {
	client := newTestClient(t, &fakeLocker{}, &fakeGitOps{branch: "main", clean: true}, &fakeRunner{})
	if err := client.Claim("orca-1", ""); err == nil {
		t.Fatal("expected actor required error")
	}
}

func TestCommentUsesFilePayloadAndAuthor(t *testing.T) {
	runner := &fakeRunner{}
	client := newTestClient(t, &fakeLocker{}, &fakeGitOps{branch: "main", clean: true}, runner)
	comment := "line one\nline two\n"
	if err := client.Comment("orca-1", "agent-1", comment); err != nil {
		t.Fatalf("comment: %v", err)
	}

	args := findFirstBRCallArgsRaw(runner.calls, "comments", "add")
	if args == nil {
		t.Fatalf("missing br comments add call; calls=%#v", runner.calls)
	}
	if hasArg(args, "--message") {
		t.Fatalf("unexpected --message payload arg: %#v", args)
	}
	if !hasArg(args, "--file") {
		t.Fatalf("missing --file payload arg: %#v", args)
	}
	if !hasArg(args, "--author") {
		t.Fatalf("missing --author arg: %#v", args)
	}

	filePath := valueAfter(args, "--file")
	if filePath == "" {
		t.Fatalf("missing file path for --file: %#v", args)
	}
	if _, err := os.Stat(filePath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("temp comment file should be removed, stat err=%v", err)
	}
}

func TestCreateParsesIssueID(t *testing.T) {
	client := newTestClient(t, &fakeLocker{}, &fakeGitOps{branch: "main", clean: true}, &fakeRunner{})
	priority := 1
	id, err := client.Create(CreateOpts{
		Title:       "Fix parser",
		Description: "Details",
		Priority:    &priority,
		Labels:      []string{"ck:queue", "px:exclusive"},
		Actor:       "agent-1",
	})
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if id != "orca-42" {
		t.Fatalf("created issue id mismatch: got %q want orca-42", id)
	}
}

func TestDepAddDefaultsType(t *testing.T) {
	runner := &fakeRunner{}
	client := newTestClient(t, &fakeLocker{}, &fakeGitOps{branch: "main", clean: true}, runner)
	if err := client.DepAdd("orca-1", "orca-2", "", "agent-1"); err != nil {
		t.Fatalf("dep-add: %v", err)
	}

	args := findFirstBRCallArgsRaw(runner.calls, "dep", "add")
	if args == nil {
		t.Fatalf("missing br dep add call; calls=%#v", runner.calls)
	}
	if !containsSequence(args, []string{"--type", "blocks"}) {
		t.Fatalf("expected default dep type blocks, args=%#v", args)
	}
}

func TestShowAndDepListParseJSON(t *testing.T) {
	client := newTestClient(t, &fakeLocker{}, &fakeGitOps{branch: "main", clean: true}, &fakeRunner{})

	issue, err := client.Show("orca-1")
	if err != nil {
		t.Fatalf("show: %v", err)
	}
	if issue.ID != "orca-1" {
		t.Fatalf("show issue id mismatch: %#v", issue)
	}

	deps, err := client.DepList("orca-1")
	if err != nil {
		t.Fatalf("dep list: %v", err)
	}
	if len(deps) != 0 {
		t.Fatalf("expected empty deps, got %#v", deps)
	}
}

func newTestClient(t *testing.T, locker lock.Locker, git *fakeGitOps, runner *fakeRunner) *Client {
	t.Helper()
	repo := t.TempDir()
	if err := os.MkdirAll(filepath.Join(repo, ".beads"), 0o755); err != nil {
		t.Fatalf("mkdir .beads: %v", err)
	}

	client, err := New(Config{
		RepoPath: repo,
		Locker:   locker,
		Scope:    "merge",
		Timeout:  time.Second,
		BRBinary: "br",
		Git:      git,
		Run:      runner.run,
	})
	if err != nil {
		t.Fatalf("new queue client: %v", err)
	}
	return client
}

func brCalls(calls []call) [][]string {
	out := make([][]string, 0)
	for _, c := range calls {
		if c.Name != "br" {
			continue
		}
		out = append(out, c.Args)
	}
	return out
}

func containsGitCall(calls []call, args []string) bool {
	for _, c := range calls {
		if c.Name != "git" {
			continue
		}
		if reflect.DeepEqual(c.Args, args) {
			return true
		}
	}
	return false
}

func containsGitCallPrefix(calls []call, prefix []string) bool {
	for _, c := range calls {
		if c.Name != "git" {
			continue
		}
		if len(c.Args) < len(prefix) {
			continue
		}
		if reflect.DeepEqual(c.Args[:len(prefix)], prefix) {
			return true
		}
	}
	return false
}

func findFirstBRCallArgsRaw(calls []call, startsWith ...string) []string {
	for _, c := range calls {
		if c.Name != "br" {
			continue
		}
		if len(c.Args) < len(startsWith) {
			continue
		}
		if reflect.DeepEqual(c.Args[:len(startsWith)], startsWith) {
			return c.Args
		}
	}
	return nil
}

func hasArg(args []string, flag string) bool {
	for _, arg := range args {
		if arg == flag {
			return true
		}
	}
	return false
}

func valueAfter(args []string, flag string) string {
	for i := 0; i < len(args)-1; i++ {
		if args[i] == flag {
			return args[i+1]
		}
	}
	return ""
}

func containsSequence(args []string, seq []string) bool {
	if len(seq) == 0 {
		return true
	}
	for i := 0; i <= len(args)-len(seq); i++ {
		if reflect.DeepEqual(args[i:i+len(seq)], seq) {
			return true
		}
	}
	return false
}
