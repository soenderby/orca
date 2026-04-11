// Package bootstrap provides setup automation with --yes and --dry-run modes.
package bootstrap

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	doctorpkg "github.com/soenderby/orca/internal/doctor"
)

const (
	brInstallURL = "https://raw.githubusercontent.com/Dicklesworthstone/beads_rust/main/install.sh"
)

// Config configures bootstrap execution.
type Config struct {
	Yes    bool
	DryRun bool

	Cwd      string
	OrcaHome string

	Stdout io.Writer
	Stderr io.Writer

	LookPath   func(string) (string, error)
	RunCommand func(dir string, name string, args ...string) (string, error)
}

// Run executes bootstrap workflow.
func Run(cfg Config) error {
	if strings.TrimSpace(cfg.Cwd) == "" {
		if wd, err := os.Getwd(); err == nil {
			cfg.Cwd = wd
		}
	}
	if strings.TrimSpace(cfg.OrcaHome) == "" {
		cfg.OrcaHome = cfg.Cwd
	}
	if cfg.Stdout == nil {
		cfg.Stdout = os.Stdout
	}
	if cfg.Stderr == nil {
		cfg.Stderr = os.Stderr
	}
	lookPath := cfg.LookPath
	if lookPath == nil {
		lookPath = exec.LookPath
	}
	runCommand := cfg.RunCommand
	if runCommand == nil {
		runCommand = defaultRunCommand
	}

	repoRoot, err := runCommand(cfg.Cwd, "git", "rev-parse", "--show-toplevel")
	if err != nil || strings.TrimSpace(repoRoot) == "" {
		return fmt.Errorf("run bootstrap from inside the Orca git repository")
	}
	repoRoot = strings.TrimSpace(repoRoot)

	ctx := context{
		cfg:        cfg,
		lookPath:   lookPath,
		runCommand: runCommand,
		repoRoot:   repoRoot,
	}

	ctx.log("starting Orca bootstrap")
	if cfg.DryRun {
		ctx.log("dry-run mode enabled; no mutations will be applied")
	}

	steps := []string{
		"Detect Ubuntu/WSL platform",
		"Install missing Ubuntu dependencies via apt",
		"Ensure python command availability",
		"Install/verify br via upstream installer",
		"Initialize queue workspace",
		"Ensure queue id prefix",
		"Configure local git identity",
		"Check Codex availability/auth (fail-hard)",
	}

	for i, step := range steps {
		ctx.log(fmt.Sprintf("step %d/%d: %s", i+1, len(steps), step))
		switch i + 1 {
		case 1:
			if err := ctx.stepDetectPlatform(); err != nil {
				return err
			}
		case 2:
			if err := ctx.stepInstallAptDependencies(); err != nil {
				return err
			}
		case 3:
			if err := ctx.stepEnsurePythonAlias(); err != nil {
				return err
			}
		case 4:
			if err := ctx.stepInstallBR(); err != nil {
				return err
			}
		case 5:
			if err := ctx.stepInitQueueWorkspace(); err != nil {
				return err
			}
		case 6:
			if err := ctx.stepEnsureQueuePrefix(); err != nil {
				return err
			}
		case 7:
			if err := ctx.stepConfigureGitIdentity(); err != nil {
				return err
			}
		case 8:
			if err := ctx.stepCheckCodexAuth(); err != nil {
				return err
			}
		}
	}

	if cfg.DryRun {
		ctx.log("bootstrap dry-run complete")
		return nil
	}

	ctx.log("running final verification: " + filepath.Join(cfg.OrcaHome, "doctor.sh"))
	doc := doctorpkg.Run(doctorpkg.Config{Cwd: repoRoot, OrcaHome: cfg.OrcaHome, LookPath: lookPath, RunCommand: runCommand})
	if !doc.OK {
		return fmt.Errorf("bootstrap completed with remaining hard-fail checks. Resolve doctor failures and re-run")
	}
	ctx.log("bootstrap complete: local prerequisites are ready")
	return nil
}

type context struct {
	cfg        Config
	lookPath   func(string) (string, error)
	runCommand func(dir string, name string, args ...string) (string, error)
	repoRoot   string
}

func (c *context) log(msg string) {
	_, _ = fmt.Fprintf(c.cfg.Stdout, "[bootstrap] %s\n", msg)
}

func (c *context) warn(msg string) {
	_, _ = fmt.Fprintf(c.cfg.Stderr, "[bootstrap] warn: %s\n", msg)
}

func (c *context) dry(cmd string) {
	_, _ = fmt.Fprintf(c.cfg.Stdout, "[bootstrap] dry-run: %s\n", cmd)
}

func (c *context) requireYes(prompt string) error {
	if c.cfg.Yes {
		return nil
	}
	return fmt.Errorf("aborted by user (requires confirmation): %s", prompt)
}

func (c *context) stepDetectPlatform() error {
	isWSL := false
	if strings.TrimSpace(os.Getenv("WSL_INTEROP")) != "" {
		isWSL = true
	} else if raw, err := os.ReadFile("/proc/sys/kernel/osrelease"); err == nil {
		lower := strings.ToLower(string(raw))
		isWSL = strings.Contains(lower, "microsoft") || strings.Contains(lower, "wsl")
	}
	if !isWSL {
		if raw, err := os.ReadFile("/proc/version"); err == nil {
			isWSL = strings.Contains(strings.ToLower(string(raw)), "microsoft")
		}
	}

	osID := ""
	osLike := ""
	if raw, err := os.ReadFile("/etc/os-release"); err == nil {
		for _, line := range strings.Split(string(raw), "\n") {
			if strings.HasPrefix(line, "ID=") {
				osID = strings.Trim(strings.TrimPrefix(line, "ID="), "\"")
			}
			if strings.HasPrefix(line, "ID_LIKE=") {
				osLike = strings.Trim(strings.TrimPrefix(line, "ID_LIKE="), "\"")
			}
		}
	}
	if osID != "ubuntu" && !strings.Contains(" "+osLike+" ", " ubuntu ") {
		return fmt.Errorf("unsupported distro (ID=%s). Orca bootstrap currently supports Ubuntu (WSL preferred)", valueOrUnknown(osID))
	}
	if !isWSL {
		c.warn("WSL was not detected. Continuing on Ubuntu, but this path is optimized for Ubuntu on WSL.")
	}
	if isWSL {
		c.log("platform detected: Ubuntu on WSL")
	} else {
		c.log("platform detected: Ubuntu")
	}
	return nil
}

func (c *context) stepInstallAptDependencies() error {
	missing := make([]string, 0)
	if _, err := c.lookPath("git"); err != nil {
		missing = append(missing, "git")
	}
	if _, err := c.lookPath("tmux"); err != nil {
		missing = append(missing, "tmux")
	}
	if _, err := c.lookPath("jq"); err != nil {
		missing = append(missing, "jq")
	}
	if _, err := c.lookPath("flock"); err != nil {
		missing = append(missing, "util-linux")
	}
	if _, err := c.lookPath("curl"); err != nil {
		missing = append(missing, "curl")
	}
	if _, err := c.lookPath("python3"); err != nil {
		missing = append(missing, "python3")
	}
	if len(missing) == 0 {
		c.log("ubuntu package prerequisites already installed")
		return nil
	}
	if err := c.requireYes("Install missing apt packages: " + strings.Join(missing, " ") + "?"); err != nil {
		return err
	}
	if c.cfg.DryRun {
		c.dry("sudo apt-get update")
		c.dry("sudo apt-get install -y " + strings.Join(missing, " "))
		return nil
	}
	sudoPrefix, err := sudoPrefix()
	if err != nil {
		return err
	}
	if len(sudoPrefix) > 0 {
		if _, err := c.runCommand(c.cfg.Cwd, sudoPrefix[0], append(sudoPrefix[1:], "apt-get", "update")...); err != nil {
			return err
		}
		args := append(append([]string{}, sudoPrefix[1:]...), "apt-get", "install")
		if c.cfg.Yes {
			args = append(args, "-y")
		}
		args = append(args, missing...)
		_, err = c.runCommand(c.cfg.Cwd, sudoPrefix[0], args...)
		return err
	}
	if _, err := c.runCommand(c.cfg.Cwd, "apt-get", "update"); err != nil {
		return err
	}
	args := []string{"install"}
	if c.cfg.Yes {
		args = append(args, "-y")
	}
	args = append(args, missing...)
	_, err = c.runCommand(c.cfg.Cwd, "apt-get", args...)
	return err
}

func (c *context) stepEnsurePythonAlias() error {
	if _, err := c.lookPath("python"); err == nil {
		c.log("python command already available")
		return nil
	}
	if err := c.requireYes("Install python-is-python3 to provide the python command?"); err != nil {
		return err
	}
	if c.cfg.DryRun {
		c.dry("sudo apt-get install -y python-is-python3")
		return nil
	}
	sudoPrefix, err := sudoPrefix()
	if err != nil {
		return err
	}
	if len(sudoPrefix) > 0 {
		args := append(append([]string{}, sudoPrefix[1:]...), "apt-get", "install")
		if c.cfg.Yes {
			args = append(args, "-y")
		}
		args = append(args, "python-is-python3")
		if _, err := c.runCommand(c.cfg.Cwd, sudoPrefix[0], args...); err != nil {
			return err
		}
	} else {
		args := []string{"install"}
		if c.cfg.Yes {
			args = append(args, "-y")
		}
		args = append(args, "python-is-python3")
		if _, err := c.runCommand(c.cfg.Cwd, "apt-get", args...); err != nil {
			return err
		}
	}
	if _, err := c.lookPath("python"); err != nil {
		return fmt.Errorf("python command is still unavailable after installing python-is-python3")
	}
	return nil
}

func (c *context) stepInstallBR() error {
	brExpectedDir := filepath.Join(os.Getenv("HOME"), ".local", "bin")
	brExpectedBin := filepath.Join(brExpectedDir, "br")
	if info, err := os.Stat(brExpectedBin); err == nil && info.Mode()&0o111 != 0 {
		c.log("found br at expected destination: " + brExpectedBin)
	} else {
		if err := c.requireYes("Install br into " + brExpectedDir + " using the upstream installer?"); err != nil {
			return err
		}
		cmd := fmt.Sprintf("curl -fsSL \"%s?%d\" | bash -s -- --dest \"%s\" --verify", brInstallURL, time.Now().Unix(), brExpectedDir)
		if c.cfg.DryRun {
			c.dry(cmd)
		} else {
			if _, err := c.runCommand(c.cfg.Cwd, "bash", "-lc", cmd); err != nil {
				return err
			}
		}
	}
	if c.cfg.DryRun {
		return nil
	}
	if _, err := c.lookPath("br"); err != nil {
		return fmt.Errorf("br is not on PATH after installation. Add %s to PATH and restart your shell", brExpectedDir)
	}
	_, err := c.runCommand(c.cfg.Cwd, "br", "--version")
	return err
}

func (c *context) stepInitQueueWorkspace() error {
	if info, err := os.Stat(filepath.Join(c.repoRoot, ".beads")); err == nil && info.IsDir() {
		c.log("queue workspace already initialized")
		return nil
	}
	cmd := fmt.Sprintf("cd %q && br init", c.repoRoot)
	if c.cfg.DryRun {
		c.dry(cmd)
		return nil
	}
	_, err := c.runCommand(c.cfg.Cwd, "bash", "-lc", cmd)
	return err
}

func (c *context) stepEnsureQueuePrefix() error {
	prefix, _ := c.runCommand(c.repoRoot, "br", "config", "get", "id.prefix")
	if strings.TrimSpace(prefix) != "" {
		c.log("queue id.prefix already set to " + strings.TrimSpace(prefix))
		return nil
	}
	cmd := fmt.Sprintf("cd %q && br config set id.prefix orca", c.repoRoot)
	if c.cfg.DryRun {
		c.dry(cmd)
		return nil
	}
	_, err := c.runCommand(c.cfg.Cwd, "bash", "-lc", cmd)
	return err
}

func (c *context) stepConfigureGitIdentity() error {
	name, _ := c.runCommand(c.repoRoot, "git", "config", "--local", "--get", "user.name")
	email, _ := c.runCommand(c.repoRoot, "git", "config", "--local", "--get", "user.email")
	if strings.TrimSpace(name) != "" && strings.TrimSpace(email) != "" {
		c.log("local git identity already configured")
		return nil
	}
	if !c.cfg.Yes {
		return fmt.Errorf("git identity is missing and interactive prompts are not supported in go bootstrap; rerun with --yes")
	}
	globalName, _ := c.runCommand(c.cfg.Cwd, "git", "config", "--global", "--get", "user.name")
	globalEmail, _ := c.runCommand(c.cfg.Cwd, "git", "config", "--global", "--get", "user.email")
	if strings.TrimSpace(name) == "" && strings.TrimSpace(globalName) != "" {
		if _, err := c.runCommand(c.repoRoot, "git", "config", "--local", "user.name", strings.TrimSpace(globalName)); err != nil {
			return err
		}
	}
	if strings.TrimSpace(email) == "" && strings.TrimSpace(globalEmail) != "" {
		if _, err := c.runCommand(c.repoRoot, "git", "config", "--local", "user.email", strings.TrimSpace(globalEmail)); err != nil {
			return err
		}
	}
	if !c.cfg.DryRun {
		name, _ = c.runCommand(c.repoRoot, "git", "config", "--local", "--get", "user.name")
		email, _ = c.runCommand(c.repoRoot, "git", "config", "--local", "--get", "user.email")
		if strings.TrimSpace(name) == "" || strings.TrimSpace(email) == "" {
			return fmt.Errorf("local git identity is missing. Set it with: git -C %s config --local user.name \"Your Name\" && git -C %s config --local user.email \"you@example.com\"", c.repoRoot, c.repoRoot)
		}
	}
	return nil
}

func (c *context) stepCheckCodexAuth() error {
	if _, err := c.lookPath("codex"); err != nil {
		return fmt.Errorf("codex CLI is not on PATH. Install/configure codex, then run: codex login && codex login status")
	}
	statusOut, err := c.runCommand(c.cfg.Cwd, "codex", "login", "status")
	if err == nil {
		c.log("codex auth check passed: " + strings.TrimSpace(statusOut))
		return nil
	}
	if strings.TrimSpace(statusOut) != "" {
		_, _ = fmt.Fprintln(c.cfg.Stderr, strings.TrimSpace(statusOut))
	}
	return fmt.Errorf("codex authentication is required before Orca can run. Remediation: 1) codex login 2) codex login status 3) %s bootstrap --yes", filepath.Join(c.cfg.OrcaHome, "orca.sh"))
}

func sudoPrefix() ([]string, error) {
	if os.Geteuid() == 0 {
		return nil, nil
	}
	if _, err := exec.LookPath("sudo"); err != nil {
		return nil, fmt.Errorf("sudo is required for apt package installation. Re-run as root or install sudo")
	}
	return []string{"sudo"}, nil
}

func valueOrUnknown(v string) string {
	if strings.TrimSpace(v) == "" {
		return "unknown"
	}
	return v
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
		return trimmed, fmt.Errorf("%w: %s", err, trimmed)
	}
	return trimmed, nil
}
