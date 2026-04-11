package bootstrap

import (
	"bytes"
	"errors"
	"strings"
	"testing"
)

func TestRun_DryRunAuthGateFailure(t *testing.T) {
	var out bytes.Buffer
	var errOut bytes.Buffer

	err := Run(Config{
		Yes:      true,
		DryRun:   true,
		Cwd:      "/tmp/repo",
		OrcaHome: "/tmp/orca",
		Stdout:   &out,
		Stderr:   &errOut,
		LookPath: func(bin string) (string, error) {
			switch bin {
			case "git", "tmux", "jq", "flock", "br", "codex", "curl", "python3":
				return "/fake/bin/" + bin, nil
			default:
				return "", errors.New("missing")
			}
		},
		RunCommand: func(dir string, name string, args ...string) (string, error) {
			_ = dir
			joined := name + " " + strings.Join(args, " ")
			switch joined {
			case "git rev-parse --show-toplevel":
				return "/tmp/repo", nil
			case "br config get id.prefix":
				return "", errors.New("no prefix")
			case "git config --local --get user.name":
				return "tester", nil
			case "git config --local --get user.email":
				return "tester@example.com", nil
			case "codex login status":
				return "Error: not authenticated", errors.New("auth")
			default:
				return "", nil
			}
		},
	})
	if err == nil {
		t.Fatal("expected auth gate failure")
	}
	if !strings.Contains(err.Error(), "codex authentication is required") {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(out.String(), "[bootstrap] step 8/8: Check Codex availability/auth (fail-hard)") {
		t.Fatalf("missing step log: %s", out.String())
	}
	if !strings.Contains(errOut.String(), "Error: not authenticated") {
		t.Fatalf("missing codex error output: %s", errOut.String())
	}
}

func TestRun_DryRunSuccess(t *testing.T) {
	var out bytes.Buffer
	err := Run(Config{
		Yes:      true,
		DryRun:   true,
		Cwd:      "/tmp/repo",
		OrcaHome: "/tmp/orca",
		Stdout:   &out,
		LookPath: func(bin string) (string, error) {
			switch bin {
			case "git", "tmux", "jq", "flock", "br", "codex", "curl", "python3", "python":
				return "/fake/bin/" + bin, nil
			default:
				return "", errors.New("missing")
			}
		},
		RunCommand: func(dir string, name string, args ...string) (string, error) {
			_ = dir
			joined := name + " " + strings.Join(args, " ")
			switch joined {
			case "git rev-parse --show-toplevel":
				return "/tmp/repo", nil
			case "br config get id.prefix":
				return "orca", nil
			case "git config --local --get user.name":
				return "tester", nil
			case "git config --local --get user.email":
				return "tester@example.com", nil
			case "codex login status":
				return "ok", nil
			default:
				return "", nil
			}
		},
	})
	if err != nil {
		t.Fatalf("bootstrap dry-run should succeed: %v", err)
	}
	if !strings.Contains(out.String(), "[bootstrap] dry-run mode enabled") {
		t.Fatalf("missing dry-run log: %s", out.String())
	}
	if !strings.Contains(out.String(), "[bootstrap] bootstrap dry-run complete") {
		t.Fatalf("missing completion log: %s", out.String())
	}
}
