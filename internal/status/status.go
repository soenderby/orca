// Package status provides read-only runtime status reporting.
package status

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/soenderby/orca/internal/model"
	"github.com/soenderby/orca/internal/tmux"
)

var sessionIDTimestampSuffix = regexp.MustCompile(`-[0-9]{8}T[0-9]{6}Z$`)

// Config configures status collection.
type Config struct {
	RepoPath      string
	SessionPrefix string
	Now           func() time.Time

	LookPath     func(string) (string, error)
	RunCommand   func(dir string, name string, args ...string) (string, error)
	ListSessions func() ([]tmux.SessionInfo, error)
}

// Collect reads current runtime status.
func Collect(cfg Config) (model.StatusOutput, error) {
	now := cfg.Now
	if now == nil {
		now = time.Now
	}
	if strings.TrimSpace(cfg.SessionPrefix) == "" {
		cfg.SessionPrefix = "orca-agent"
	}
	lookPath := cfg.LookPath
	if lookPath == nil {
		lookPath = exec.LookPath
	}
	runCommand := cfg.RunCommand
	if runCommand == nil {
		runCommand = defaultRunCommand
	}
	listSessions := cfg.ListSessions
	if listSessions == nil {
		listSessions = tmux.ListSessions
	}

	out := model.StatusOutput{
		GeneratedAt: now().Format(time.RFC3339),
		Queue: model.StatusQueue{
			Ready:      0,
			InProgress: 0,
		},
		BR: model.StatusBR{
			Version:   "unavailable",
			Workspace: false,
		},
		Sessions: []model.StatusSession{},
		Latest:   model.StatusLatest{},
	}

	tmuxSessions := []string{}
	if _, err := lookPath("tmux"); err == nil {
		sessions, err := listSessions()
		if err == nil {
			for _, s := range sessions {
				if strings.HasPrefix(s.Name, cfg.SessionPrefix) {
					tmuxSessions = append(tmuxSessions, s.Name)
				}
			}
		}
	}
	out.ActiveSessions = len(tmuxSessions)

	if _, err := lookPath("br"); err == nil {
		if versionOut, err := runCommand(cfg.RepoPath, "br", "--version"); err == nil {
			lines := strings.Split(strings.TrimSpace(versionOut), "\n")
			if len(lines) > 0 && strings.TrimSpace(lines[0]) != "" {
				out.BR.Version = strings.TrimSpace(lines[0])
			}
		}

		beadsPath := filepath.Join(cfg.RepoPath, ".beads")
		if info, err := os.Stat(beadsPath); err == nil && info.IsDir() {
			out.BR.Workspace = true
			if rawReady, err := runCommand(cfg.RepoPath, "br", "ready", "--json"); err == nil {
				out.Queue.Ready = jsonArrayLen(rawReady)
			}
			if rawInProgress, err := runCommand(cfg.RepoPath, "br", "list", "--status", "in_progress", "--json"); err == nil {
				out.Queue.InProgress = jsonArrayLen(rawInProgress)
			}
		}
	}

	sessionLogRoot := filepath.Join(cfg.RepoPath, "agent-logs", "sessions")
	for _, tmuxSession := range tmuxSessions {
		sessionID, agentName, lastResult, lastIssue := resolveSession(sessionLogRoot, cfg.SessionPrefix, tmuxSession)
		row := model.StatusSession{
			TmuxSession: tmuxSession,
			State:       "running",
			SessionID:   nil,
			AgentName:   nil,
			LastResult:  nil,
			LastIssue:   nil,
		}
		if sessionID != "" {
			v := sessionID
			row.SessionID = &v
		}
		if agentName != "" {
			v := agentName
			row.AgentName = &v
		}
		if lastResult != "" {
			v := lastResult
			row.LastResult = &v
		}
		if lastIssue != "" {
			v := lastIssue
			row.LastIssue = &v
		}
		out.Sessions = append(out.Sessions, row)
	}

	latest, err := readLatest(filepath.Join(cfg.RepoPath, "agent-logs", "metrics.jsonl"), now())
	if err == nil {
		out.Latest = latest
	}

	return out, nil
}

// RenderHuman renders status output in the same minimal format as status.sh.
func RenderHuman(s model.StatusOutput) string {
	var b strings.Builder
	b.WriteString("== orca status ==\n")
	b.WriteString(fmt.Sprintf("active sessions: %d\n", s.ActiveSessions))
	b.WriteString(fmt.Sprintf("queue: %d ready, %d in progress\n", s.Queue.Ready, s.Queue.InProgress))
	if s.Latest.Result != nil {
		agent := derefOrEmpty(s.Latest.Agent)
		result := derefOrEmpty(s.Latest.Result)
		issue := derefOrEmpty(s.Latest.Issue)
		dur := derefOrEmpty(s.Latest.Duration)
		tokens := derefOrEmpty(s.Latest.Tokens)
		age := derefOrEmpty(s.Latest.Age)
		b.WriteString(fmt.Sprintf("latest: agent=%s result=%s issue=%s duration=%ss tokens=%s %s\n", agent, result, issue, dur, tokens, age))
	}
	b.WriteString("\n")

	if len(s.Sessions) > 0 {
		b.WriteString("== sessions ==\n")
		for _, row := range s.Sessions {
			line := fmt.Sprintf("- %s: state=%s", row.TmuxSession, row.State)
			if row.LastResult != nil {
				line += " result=" + *row.LastResult
			}
			if row.LastIssue != nil {
				line += " issue=" + *row.LastIssue
			}
			b.WriteString(line + "\n")
		}
		b.WriteString("\n")
	}

	if s.ActiveSessions == 0 {
		b.WriteString("(no active orca sessions)\n")
	}

	return b.String()
}

func resolveSession(sessionLogRoot, sessionPrefix, tmuxSession string) (sessionID, agentName, lastResult, lastIssue string) {
	sessionDir := ""
	dateDirs, _ := filepath.Glob(filepath.Join(sessionLogRoot, "????", "??", "??"))
	sort.Sort(sort.Reverse(sort.StringSlice(dateDirs)))
	if len(dateDirs) > 7 {
		dateDirs = dateDirs[:7]
	}

	for _, dateDir := range dateDirs {
		candidates, _ := filepath.Glob(filepath.Join(dateDir, tmuxSession+"*"))
		sort.Strings(candidates)
		for _, candidate := range candidates {
			if info, err := os.Stat(candidate); err == nil && info.IsDir() {
				sessionDir = candidate
				break
			}
		}
		if sessionDir != "" {
			break
		}
	}
	if sessionDir == "" {
		return "", "", "", ""
	}

	sessionID = filepath.Base(sessionDir)
	agentName = strings.TrimPrefix(sessionID, sessionPrefix+"-")
	agentName = sessionIDTimestampSuffix.ReplaceAllString(agentName, "")

	runs, _ := filepath.Glob(filepath.Join(sessionDir, "runs", "*"))
	sort.Sort(sort.Reverse(sort.StringSlice(runs)))
	if len(runs) == 0 {
		return sessionID, agentName, "", ""
	}

	summaryPath := filepath.Join(runs[0], "summary.json")
	raw, err := os.ReadFile(summaryPath)
	if err != nil {
		return sessionID, agentName, "", ""
	}
	var summary struct {
		Result  string `json:"result"`
		IssueID string `json:"issue_id"`
	}
	if err := json.Unmarshal(raw, &summary); err != nil {
		return sessionID, agentName, "", ""
	}
	return sessionID, agentName, strings.TrimSpace(summary.Result), strings.TrimSpace(summary.IssueID)
}

func readLatest(path string, now time.Time) (model.StatusLatest, error) {
	f, err := os.Open(path)
	if err != nil {
		return model.StatusLatest{}, err
	}
	defer f.Close()

	last := ""
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		last = line
	}
	if err := scanner.Err(); err != nil {
		return model.StatusLatest{}, err
	}
	if last == "" {
		return model.StatusLatest{}, fmt.Errorf("empty metrics")
	}

	var row struct {
		Timestamp string `json:"timestamp"`
		AgentName string `json:"agent_name"`
		Result    string `json:"result"`
		IssueID   string `json:"issue_id"`
		Durations struct {
			IterationTotal int `json:"iteration_total"`
		} `json:"durations_seconds"`
		TokensUsed *int `json:"tokens_used"`
	}
	if err := json.Unmarshal([]byte(last), &row); err != nil {
		return model.StatusLatest{}, err
	}

	latest := model.StatusLatest{}
	if strings.TrimSpace(row.AgentName) != "" {
		v := row.AgentName
		latest.Agent = &v
	}
	if strings.TrimSpace(row.Result) != "" {
		v := row.Result
		latest.Result = &v
	}
	if strings.TrimSpace(row.IssueID) != "" {
		v := row.IssueID
		latest.Issue = &v
	}
	if latest.Result != nil {
		d := strconv.Itoa(row.Durations.IterationTotal)
		latest.Duration = &d
		tokens := 0
		if row.TokensUsed != nil {
			tokens = *row.TokensUsed
		}
		t := strconv.Itoa(tokens)
		latest.Tokens = &t

		if parsed, err := time.Parse(time.RFC3339, strings.TrimSpace(row.Timestamp)); err == nil {
			age := humanAge(now.Sub(parsed))
			latest.Age = &age
		}
	}

	return latest, nil
}

func humanAge(d time.Duration) string {
	if d < 0 {
		d = 0
	}
	sec := int(d.Seconds())
	if sec < 60 {
		return fmt.Sprintf("%ds ago", sec)
	}
	if sec < 3600 {
		return fmt.Sprintf("%dm ago", sec/60)
	}
	if sec < 86400 {
		return fmt.Sprintf("%dh ago", sec/3600)
	}
	return fmt.Sprintf("%dd ago", sec/86400)
}

func jsonArrayLen(raw string) int {
	var arr []json.RawMessage
	if err := json.Unmarshal([]byte(raw), &arr); err != nil {
		return 0
	}
	return len(arr)
}

func derefOrEmpty(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

func defaultRunCommand(dir string, name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	if strings.TrimSpace(dir) != "" {
		cmd.Dir = dir
	}
	out, err := cmd.CombinedOutput()
	trimmed := strings.TrimSpace(string(out))
	if err != nil {
		if trimmed == "" {
			return "", err
		}
		return "", fmt.Errorf("%w: %s", err, trimmed)
	}
	return trimmed, nil
}
