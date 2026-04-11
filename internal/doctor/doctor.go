// Package doctor provides preflight diagnostics and JSON/human reports.
package doctor

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/soenderby/orca/internal/model"
)

// Config configures doctor checks.
type Config struct {
	Cwd      string
	OrcaHome string

	LookPath   func(string) (string, error)
	RunCommand func(dir string, name string, args ...string) (string, error)
}

// Run executes doctor checks and returns a structured result.
func Run(cfg Config) model.DoctorResult {
	if strings.TrimSpace(cfg.Cwd) == "" {
		if wd, err := os.Getwd(); err == nil {
			cfg.Cwd = wd
		}
	}
	if strings.TrimSpace(cfg.OrcaHome) == "" {
		cfg.OrcaHome = cfg.Cwd
	}
	lookPath := cfg.LookPath
	if lookPath == nil {
		lookPath = exec.LookPath
	}
	runCommand := cfg.RunCommand
	if runCommand == nil {
		runCommand = defaultRunCommand
	}

	r := reporter{}
	platformCheck(&r)

	binaryCheck := func(cmd, id, remediationSummary string, remediationCommands []string) {
		if path, err := lookPath(cmd); err == nil {
			r.add(passCheck(id, "Required binary present: "+cmd, "dependency", "Found "+cmd+" at "+path+"."))
			return
		}
		r.add(failCheck(id, "Required binary present: "+cmd, "dependency", true,
			cmd+" is not available on PATH.", remediationSummary, remediationCommands...))
	}

	binaryCheck("git", "dep.git.present", "Install git and verify it is available.", []string{"sudo apt-get update", "sudo apt-get install -y git", "git --version"})
	binaryCheck("tmux", "dep.tmux.present", "Install tmux and verify it is available.", []string{"sudo apt-get update", "sudo apt-get install -y tmux", "tmux -V"})
	binaryCheck("jq", "dep.jq.present", "Install jq and verify it is available.", []string{"sudo apt-get update", "sudo apt-get install -y jq", "jq --version"})
	binaryCheck("flock", "dep.flock.present", "Install util-linux (provides flock) and verify it is available.", []string{"sudo apt-get update", "sudo apt-get install -y util-linux", "flock --version"})
	binaryCheck("br", "dep.br.present", "Install/configure br and ensure it is on PATH.", []string{"command -v br", "br --version"})
	binaryCheck("codex", "dep.codex.present", "Install/configure codex CLI and ensure it is on PATH.", []string{"command -v codex", "codex --version"})

	if _, err := lookPath("br"); err == nil {
		if _, err := runCommand(cfg.Cwd, "br", "--version"); err == nil {
			r.add(passCheck("dep.br.executable", "br executable sanity", "dependency", "br --version succeeded."))
		} else {
			r.add(failCheck("dep.br.executable", "br executable sanity", "dependency", true,
				"br is present but not executable.",
				"Reinstall br or fix runtime dependencies until br --version succeeds.",
				"br --version",
			))
		}
	} else {
		r.add(failCheck("dep.br.executable", "br executable sanity", "dependency", true,
			"Skipping executable check because br is missing.",
			"Install/configure br and ensure it is on PATH.",
			"command -v br", "br --version",
		))
	}

	repoRoot := cfg.Cwd
	inGit := false
	if top, err := runCommand(cfg.Cwd, "git", "rev-parse", "--show-toplevel"); err == nil && strings.TrimSpace(top) != "" {
		inGit = true
		repoRoot = strings.TrimSpace(top)
		r.add(passCheck("repo.git_worktree", "Repository context is a git worktree", "repo", "Detected git worktree root: "+repoRoot+"."))
	} else {
		r.add(failCheck("repo.git_worktree", "Repository context is a git worktree", "repo", true,
			"Current working directory is not inside a git worktree.",
			"Run doctor from inside the Orca repository checkout.",
			"cd /path/to/orca",
			filepath.Join(cfg.OrcaHome, "orca.sh")+" doctor",
		))
	}

	if inGit {
		if origin, err := runCommand(repoRoot, "git", "remote", "get-url", "origin"); err == nil && strings.TrimSpace(origin) != "" {
			r.add(passCheck("repo.origin_present", "origin remote is configured", "repo", "origin points to "+strings.TrimSpace(origin)+"."))
			if _, err := runCommand(repoRoot, "git", "ls-remote", "--exit-code", "origin", "HEAD"); err == nil {
				r.add(passCheck("repo.origin_reachable", "origin remote reachability", "repo", "origin is reachable (HEAD resolved)."))
			} else {
				r.add(warnCheck("repo.origin_reachable", "origin remote reachability", "repo",
					"origin is configured but remote reachability/auth failed.",
					"Verify network access and authentication to origin before running long loops.",
					"git remote -v", "GIT_TERMINAL_PROMPT=1 git ls-remote --exit-code origin HEAD"))
			}
		} else {
			r.add(failCheck("repo.origin_present", "origin remote is configured", "repo", true,
				"No origin remote configured.",
				"Add origin so queue/merge helpers can sync and push.",
				"git remote add origin <repo-url>", "git remote -v",
			))
			r.add(warnCheck("repo.origin_reachable", "origin remote reachability", "repo",
				"Skipping reachability check because origin is missing.",
				"Configure origin first.",
				"git remote add origin <repo-url>"))
		}

		if name, _ := runCommand(repoRoot, "git", "config", "--local", "--get", "user.name"); strings.TrimSpace(name) != "" {
			r.add(passCheck("git.user_name_local", "Local git user.name configured", "git", "Local user.name is set."))
		} else {
			r.add(failCheck("git.user_name_local", "Local git user.name configured", "git", true,
				"Local git user.name is not configured.",
				"Set a local identity in this repository.",
				"git config --local user.name \"Your Name\"",
			))
		}
		if email, _ := runCommand(repoRoot, "git", "config", "--local", "--get", "user.email"); strings.TrimSpace(email) != "" {
			r.add(passCheck("git.user_email_local", "Local git user.email configured", "git", "Local user.email is set."))
		} else {
			r.add(failCheck("git.user_email_local", "Local git user.email configured", "git", true,
				"Local git user.email is not configured.",
				"Set a local identity in this repository.",
				"git config --local user.email \"you@example.com\"",
			))
		}
	} else {
		r.add(failCheck("repo.origin_present", "origin remote is configured", "repo", true,
			"Skipping origin check because repository context is invalid.",
			"Run doctor from inside the Orca repository checkout.",
			"cd /path/to/orca",
		))
		r.add(warnCheck("repo.origin_reachable", "origin remote reachability", "repo",
			"Skipping remote reachability check because repository context is invalid.",
			"Run doctor from inside the Orca repository checkout.",
			"cd /path/to/orca",
		))
		r.add(failCheck("git.user_name_local", "Local git user.name configured", "git", true,
			"Skipping local identity check because repository context is invalid.",
			"Run doctor from inside the Orca repository checkout.",
			"cd /path/to/orca",
		))
		r.add(failCheck("git.user_email_local", "Local git user.email configured", "git", true,
			"Skipping local identity check because repository context is invalid.",
			"Run doctor from inside the Orca repository checkout.",
			"cd /path/to/orca",
		))
	}

	beadsPath := filepath.Join(repoRoot, ".beads")
	if info, err := os.Stat(beadsPath); err == nil && info.IsDir() {
		r.add(passCheck("queue.workspace_dir", "Queue workspace directory exists", "queue", "Found "+beadsPath+"."))
	} else {
		r.add(failCheck("queue.workspace_dir", "Queue workspace directory exists", "queue", true,
			"Missing "+beadsPath+" queue workspace directory.",
			"Initialize queue workspace for this repository.",
			"cd "+repoRoot, "br init",
		))
	}

	if _, err := lookPath("br"); err == nil {
		if _, err := runCommand(repoRoot, "br", "doctor"); err == nil {
			r.add(passCheck("queue.br_doctor", "Queue workspace health (br doctor)", "queue", "br doctor succeeded."))
		} else {
			r.add(failCheck("queue.br_doctor", "Queue workspace health (br doctor)", "queue", true,
				"br doctor failed.",
				"Repair the queue workspace and re-run doctor.",
				"cd "+repoRoot, "br doctor",
			))
		}
	} else {
		r.add(failCheck("queue.br_doctor", "Queue workspace health (br doctor)", "queue", true,
			"Skipping br doctor because br is missing.",
			"Install/configure br and re-run doctor.",
			"command -v br", "br --version",
		))
	}

	if _, err := lookPath("br"); err == nil {
		if prefix, _ := runCommand(repoRoot, "br", "config", "get", "id.prefix"); strings.TrimSpace(prefix) != "" {
			r.add(passCheck("queue.id_prefix", "Queue id prefix configured", "queue", "Configured id.prefix="+strings.TrimSpace(prefix)+"."))
		} else {
			r.add(failCheck("queue.id_prefix", "Queue id prefix configured", "queue", true,
				"Queue id.prefix is missing.",
				"Set an id prefix for queue issue identifiers.",
				"cd "+repoRoot, "br config set id.prefix orca",
			))
		}
	} else {
		r.add(failCheck("queue.id_prefix", "Queue id prefix configured", "queue", true,
			"Skipping id prefix check because br is missing.",
			"Install/configure br and re-run doctor.",
			"command -v br", "br --version",
		))
	}

	helper := func(path, id, title string) {
		if info, err := os.Stat(path); err == nil && !info.IsDir() {
			if info.Mode()&0o111 != 0 {
				r.add(passCheck(id, title, "helper", "Helper is present and executable: "+path))
				return
			}
			r.add(failCheck(id, title, "helper", true,
				"Helper exists but is not executable: "+path,
				"Mark helper as executable.",
				"chmod +x "+path,
			))
			return
		}

		orcaGo := filepath.Join(cfg.OrcaHome, "orca-go")
		if info, err := os.Stat(orcaGo); err == nil && !info.IsDir() && info.Mode()&0o111 != 0 {
			r.add(passCheck(id, title, "helper", "Legacy helper script missing; using go subcommand via "+orcaGo))
			return
		}
		orcaBin := filepath.Join(cfg.OrcaHome, "orca")
		if info, err := os.Stat(orcaBin); err == nil && !info.IsDir() && info.Mode()&0o111 != 0 {
			r.add(passCheck(id, title, "helper", "Legacy helper script missing; using go subcommand via "+orcaBin))
			return
		}

		r.add(failCheck(id, title, "helper", true,
			"Missing helper script: "+path,
			"Restore the helper script at the expected path or install an executable orca-go/orca binary in ORCA_HOME.",
			"ls -l "+repoRoot,
			"ls -l "+cfg.OrcaHome,
		))
	}

	helper(filepath.Join(cfg.OrcaHome, "with-lock.sh"), "helper.with_lock_executable", "with-lock helper is executable")
	helper(filepath.Join(cfg.OrcaHome, "queue-read-main.sh"), "helper.queue_read_main_executable", "queue-read-main helper is executable")
	helper(filepath.Join(cfg.OrcaHome, "queue-write-main.sh"), "helper.queue_write_main_executable", "queue-write-main helper is executable")
	helper(filepath.Join(cfg.OrcaHome, "merge-main.sh"), "helper.merge_main_executable", "merge-main helper is executable")

	return r.result()
}

// RenderHuman renders a human-readable doctor report.
func RenderHuman(res model.DoctorResult) string {
	var b strings.Builder
	b.WriteString("Orca Doctor\n")
	b.WriteString("===========\n")
	for _, c := range res.Checks {
		label := strings.ToUpper(c.Status)
		if label == "WARN" {
			label = "WARN"
		}
		b.WriteString(fmt.Sprintf("[%s] %s (%s)\n", label, c.ID, c.Title))
		if strings.TrimSpace(c.Message) != "" {
			b.WriteString("  " + c.Message + "\n")
		}
		if strings.TrimSpace(c.Remediation.Summary) != "" {
			b.WriteString("  Fix: " + c.Remediation.Summary + "\n")
		}
		for _, cmd := range c.Remediation.Commands {
			if strings.TrimSpace(cmd) == "" {
				continue
			}
			b.WriteString("  Run: " + cmd + "\n")
		}
	}
	b.WriteString("\n")
	b.WriteString(fmt.Sprintf("Summary: pass=%d fail=%d warn=%d hard_fail=%d\n", res.Summary.Pass, res.Summary.Fail, res.Summary.Warn, res.Summary.HardFail))
	if res.OK {
		b.WriteString("Result: ready\n")
	} else {
		b.WriteString("Result: not ready\n")
	}
	return b.String()
}

type reporter struct {
	checks []model.DoctorCheck
}

func (r *reporter) add(check model.DoctorCheck) {
	r.checks = append(r.checks, check)
}

func (r *reporter) result() model.DoctorResult {
	res := model.DoctorResult{SchemaVersion: 1, Checks: append([]model.DoctorCheck(nil), r.checks...)}
	for _, c := range r.checks {
		switch c.Status {
		case "pass":
			res.Summary.Pass++
		case "fail":
			res.Summary.Fail++
			res.FailedCheckIDs = append(res.FailedCheckIDs, c.ID)
			if c.HardRequirement {
				res.Summary.HardFail++
			}
		case "warn":
			res.Summary.Warn++
		}
	}
	res.OK = res.Summary.HardFail == 0
	return res
}

func passCheck(id, title, category, message string) model.DoctorCheck {
	return model.DoctorCheck{
		ID:              id,
		Title:           title,
		Category:        category,
		Status:          "pass",
		Severity:        "info",
		HardRequirement: true,
		Message:         message,
		Remediation:     model.DoctorRemediation{Summary: "", Commands: []string{}},
	}
}

func failCheck(id, title, category string, hard bool, message, remediation string, commands ...string) model.DoctorCheck {
	return model.DoctorCheck{
		ID:              id,
		Title:           title,
		Category:        category,
		Status:          "fail",
		Severity:        "error",
		HardRequirement: hard,
		Message:         message,
		Remediation:     model.DoctorRemediation{Summary: remediation, Commands: append([]string(nil), commands...)},
	}
}

func warnCheck(id, title, category, message, remediation string, commands ...string) model.DoctorCheck {
	return model.DoctorCheck{
		ID:              id,
		Title:           title,
		Category:        category,
		Status:          "warn",
		Severity:        "warn",
		HardRequirement: false,
		Message:         message,
		Remediation:     model.DoctorRemediation{Summary: remediation, Commands: append([]string(nil), commands...)},
	}
}

func platformCheck(r *reporter) {
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
	isUbuntu := osID == "ubuntu" || strings.Contains(" "+osLike+" ", " ubuntu ")

	switch {
	case isWSL && isUbuntu:
		r.add(model.DoctorCheck{ID: "platform.wsl_ubuntu", Title: "Platform is Ubuntu on WSL", Category: "platform", Status: "pass", Severity: "info", HardRequirement: false, Message: "Detected Ubuntu on WSL.", Remediation: model.DoctorRemediation{Summary: "", Commands: []string{}}})
	case isWSL:
		r.add(warnCheck("platform.wsl_ubuntu", "Platform is Ubuntu on WSL", "platform", "WSL detected but distro is not Ubuntu (ID="+valueOrUnknown(osID)+").", "Use Ubuntu on WSL for supported onboarding behavior.", "cat /etc/os-release", "wsl --list --verbose"))
	case isUbuntu:
		r.add(warnCheck("platform.wsl_ubuntu", "Platform is Ubuntu on WSL", "platform", "Ubuntu detected, but WSL was not detected.", "Run Orca from Ubuntu on WSL to match the supported target platform.", "uname -a", "cat /proc/version"))
	default:
		r.add(warnCheck("platform.wsl_ubuntu", "Platform is Ubuntu on WSL", "platform", "Unsupported platform for the default onboarding flow (expected Ubuntu on WSL).", "Use Ubuntu on WSL for supported onboarding behavior.", "cat /etc/os-release", "uname -a"))
	}
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
		return "", fmt.Errorf("%w: %s", err, trimmed)
	}
	return trimmed, nil
}
