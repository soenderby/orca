package tmux

import (
	"errors"
	"reflect"
	"testing"
)

func TestListSessions_ParsesOutput(t *testing.T) {
	client := &Client{
		run: func(name string, args ...string) (string, int, error) {
			if name != "tmux" {
				t.Fatalf("unexpected command: %s", name)
			}
			wantArgs := []string{"list-sessions", "-F", "#S"}
			if !reflect.DeepEqual(args, wantArgs) {
				t.Fatalf("args mismatch\nwant=%#v\n got=%#v", wantArgs, args)
			}
			return "orca-agent-1\norca-agent-2\n", 0, nil
		},
	}

	sessions, err := client.ListSessions()
	if err != nil {
		t.Fatalf("list sessions: %v", err)
	}
	want := []SessionInfo{{Name: "orca-agent-1"}, {Name: "orca-agent-2"}}
	if !reflect.DeepEqual(sessions, want) {
		t.Fatalf("sessions mismatch\nwant=%#v\n got=%#v", want, sessions)
	}
}

func TestListSessions_NoSessionsExitCodeOne(t *testing.T) {
	client := &Client{
		run: func(string, ...string) (string, int, error) {
			return "", 1, errors.New("no server running")
		},
	}

	sessions, err := client.ListSessions()
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if len(sessions) != 0 {
		t.Fatalf("expected empty sessions, got %#v", sessions)
	}
}

func TestHasSession(t *testing.T) {
	t.Run("exists", func(t *testing.T) {
		client := &Client{run: func(name string, args ...string) (string, int, error) {
			wantArgs := []string{"has-session", "-t", "orca-agent-1"}
			if !reflect.DeepEqual(args, wantArgs) {
				t.Fatalf("args mismatch\nwant=%#v\n got=%#v", wantArgs, args)
			}
			return "", 0, nil
		}}
		exists, err := client.HasSession("orca-agent-1")
		if err != nil {
			t.Fatalf("has session: %v", err)
		}
		if !exists {
			t.Fatal("expected session to exist")
		}
	})

	t.Run("missing", func(t *testing.T) {
		client := &Client{run: func(string, ...string) (string, int, error) {
			return "", 1, errors.New("not found")
		}}
		exists, err := client.HasSession("orca-agent-1")
		if err != nil {
			t.Fatalf("has session: %v", err)
		}
		if exists {
			t.Fatal("expected session to be missing")
		}
	})
}

func TestCommandFormatting(t *testing.T) {
	tests := []struct {
		name      string
		invoke    func(*Client) error
		wantArgs  []string
		wantError bool
	}{
		{
			name: "new session",
			invoke: func(c *Client) error {
				return c.NewSession("orca-agent-1", "echo hi")
			},
			wantArgs: []string{"new-session", "-d", "-s", "orca-agent-1", "echo hi"},
		},
		{
			name: "kill session",
			invoke: func(c *Client) error {
				return c.KillSession("orca-agent-1")
			},
			wantArgs: []string{"kill-session", "-t", "orca-agent-1"},
		},
		{
			name: "send keys",
			invoke: func(c *Client) error {
				return c.SendKeys("orca-agent-1", "C-c")
			},
			wantArgs: []string{"send-keys", "-t", "orca-agent-1", "C-c"},
		},
		{
			name: "new session validates name",
			invoke: func(c *Client) error {
				return c.NewSession("", "echo hi")
			},
			wantError: true,
		},
		{
			name: "new session validates command",
			invoke: func(c *Client) error {
				return c.NewSession("orca-agent-1", "")
			},
			wantError: true,
		},
		{
			name: "kill session validates name",
			invoke: func(c *Client) error {
				return c.KillSession("")
			},
			wantError: true,
		},
		{
			name: "send keys validates session",
			invoke: func(c *Client) error {
				return c.SendKeys("", "x")
			},
			wantError: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			called := false
			client := &Client{run: func(name string, args ...string) (string, int, error) {
				called = true
				if name != "tmux" {
					t.Fatalf("unexpected command: %s", name)
				}
				if !reflect.DeepEqual(args, tt.wantArgs) {
					t.Fatalf("args mismatch\nwant=%#v\n got=%#v", tt.wantArgs, args)
				}
				return "", 0, nil
			}}

			err := tt.invoke(client)
			if tt.wantError {
				if err == nil {
					t.Fatal("expected error, got nil")
				}
				if called {
					t.Fatal("runner should not be called on validation failure")
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if !called {
				t.Fatal("runner was not called")
			}
		})
	}
}
