// Package tmux provides tmux session management primitives used by orca.
package tmux

import (
	"fmt"
	"os/exec"
	"strings"
)

// SessionInfo is the minimal tmux session representation needed by orca.
type SessionInfo struct {
	Name string
}

// Client wraps tmux command execution.
type Client struct {
	run commandRunner
}

type commandRunner func(name string, args ...string) (stdout string, exitCode int, err error)

// New returns a tmux client backed by the system tmux binary.
func New() *Client {
	return &Client{run: defaultRunner}
}

// ListSessions lists active tmux sessions.
func ListSessions() ([]SessionInfo, error) {
	return New().ListSessions()
}

// HasSession returns true if a session exists.
func HasSession(name string) (bool, error) {
	return New().HasSession(name)
}

// NewSession creates a detached tmux session that runs command.
func NewSession(name, command string) error {
	return New().NewSession(name, command)
}

// KillSession kills a tmux session.
func KillSession(name string) error {
	return New().KillSession(name)
}

// SendKeys sends keys to a session.
func SendKeys(session, keys string) error {
	return New().SendKeys(session, keys)
}

// ListSessions lists active tmux sessions.
func (c *Client) ListSessions() ([]SessionInfo, error) {
	out, code, err := c.run("tmux", "list-sessions", "-F", "#S")
	if err != nil {
		if code == 1 {
			return nil, nil
		}
		return nil, fmt.Errorf("tmux list-sessions: %w", err)
	}

	lines := strings.Split(strings.TrimSpace(out), "\n")
	sessions := make([]SessionInfo, 0, len(lines))
	for _, line := range lines {
		name := strings.TrimSpace(line)
		if name == "" {
			continue
		}
		sessions = append(sessions, SessionInfo{Name: name})
	}
	return sessions, nil
}

// HasSession returns true if a session exists.
func (c *Client) HasSession(name string) (bool, error) {
	if strings.TrimSpace(name) == "" {
		return false, fmt.Errorf("session name is required")
	}
	_, code, err := c.run("tmux", "has-session", "-t", name)
	if err != nil {
		if code == 1 {
			return false, nil
		}
		return false, fmt.Errorf("tmux has-session %q: %w", name, err)
	}
	return true, nil
}

// NewSession creates a detached tmux session that runs command.
func (c *Client) NewSession(name, command string) error {
	if strings.TrimSpace(name) == "" {
		return fmt.Errorf("session name is required")
	}
	if strings.TrimSpace(command) == "" {
		return fmt.Errorf("session command is required")
	}
	_, _, err := c.run("tmux", "new-session", "-d", "-s", name, command)
	if err != nil {
		return fmt.Errorf("tmux new-session %q: %w", name, err)
	}
	return nil
}

// KillSession kills a tmux session.
func (c *Client) KillSession(name string) error {
	if strings.TrimSpace(name) == "" {
		return fmt.Errorf("session name is required")
	}
	_, _, err := c.run("tmux", "kill-session", "-t", name)
	if err != nil {
		return fmt.Errorf("tmux kill-session %q: %w", name, err)
	}
	return nil
}

// SendKeys sends keys to a tmux session.
func (c *Client) SendKeys(session, keys string) error {
	if strings.TrimSpace(session) == "" {
		return fmt.Errorf("session name is required")
	}
	_, _, err := c.run("tmux", "send-keys", "-t", session, keys)
	if err != nil {
		return fmt.Errorf("tmux send-keys %q: %w", session, err)
	}
	return nil
}

func defaultRunner(name string, args ...string) (string, int, error) {
	cmd := exec.Command(name, args...)
	out, err := cmd.CombinedOutput()
	trimmed := strings.TrimSpace(string(out))
	if err == nil {
		return trimmed, 0, nil
	}

	exitCode := 1
	if ee, ok := err.(*exec.ExitError); ok {
		exitCode = ee.ExitCode()
	}

	if trimmed == "" {
		return "", exitCode, err
	}
	return "", exitCode, fmt.Errorf("%w: %s", err, trimmed)
}
