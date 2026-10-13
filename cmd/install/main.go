// Command install copies the peer-pressure skill into your agent skills
// directories, replacing an older copy that it installed earlier.
//
//	go run github.com/iamrz1/peer-pressure/cmd/install@latest
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"runtime/debug"
	"strings"

	"github.com/iamrz1/peer-pressure/internal/install"
	"github.com/iamrz1/peer-pressure/skills"
)

const source = "github.com/iamrz1/peer-pressure"

type dirList []string

func (d *dirList) String() string     { return strings.Join(*d, ",") }
func (d *dirList) Set(v string) error { *d = append(*d, v); return nil }

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	fl := flag.NewFlagSet("install", flag.ContinueOnError)
	var dirs dirList
	fl.Var(&dirs, "dir", "skills directory to install into (repeatable). Replaces the defaults")
	dryRun := fl.Bool("dry-run", false, "show what would change without writing")
	force := fl.Bool("force", false, "replace or remove a directory that peer-pressure did not install")
	uninstall := fl.Bool("uninstall", false, "remove the skill from every target")
	status := fl.Bool("status", false, "show the installed version and hash, and the latest release")
	if err := fl.Parse(args); err != nil {
		return err
	}

	version := buildVersion()

	targets := []string(dirs)
	if len(targets) == 0 {
		var err error
		if targets, err = defaultTargets(); err != nil {
			return err
		}
	}

	if *status {
		latest, err := fetchLatest()
		printStatus(os.Stdout, targets, latest, err)
		return nil
	}

	opts := install.Options{Source: source, Version: version, DryRun: *dryRun, Force: *force}
	var failed bool
	for _, dir := range targets {
		var res install.Result
		var err error
		if *uninstall {
			res, err = install.Uninstall(skills.Name, dir, opts)
		} else {
			res, err = install.Install(skills.FS, skills.Name, skills.Name, dir, opts)
		}
		if err != nil {
			fmt.Fprintf(os.Stderr, "error: %v\n", err)
			failed = true
			continue
		}
		fmt.Println(describe(res, version, *dryRun))
	}
	if failed {
		return fmt.Errorf("one or more targets failed")
	}
	if !*uninstall && !*dryRun {
		fmt.Println("Restart your agent if it does not list the skill yet.")
	}
	return nil
}

// defaultTargets returns ~/.agents/skills, which most agents read, and
// ~/.claude/skills when Claude Code is present, since Claude Code reads only that one.
func defaultTargets() ([]string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	targets := []string{filepath.Join(home, ".agents", "skills")}
	if info, err := os.Stat(filepath.Join(home, ".claude")); err == nil && info.IsDir() {
		targets = append(targets, filepath.Join(home, ".claude", "skills"))
	}
	return targets, nil
}

func describe(res install.Result, version string, dryRun bool) string {
	prefix := ""
	if dryRun {
		prefix = "(dry run) "
	}
	dest := filepath.Join(res.Dir, skills.Name)
	switch res.Status {
	case install.Updated:
		return fmt.Sprintf("%s%s: updated %s -> %s", prefix, dest, orUnknown(res.Previous), version)
	case install.Unchanged:
		return fmt.Sprintf("%s%s: already up to date (%s)", prefix, dest, orUnknown(res.Previous))
	case install.Installed:
		return fmt.Sprintf("%s%s: installed %s", prefix, dest, version)
	default:
		return fmt.Sprintf("%s%s: %s", prefix, dest, res.Status)
	}
}

func orUnknown(v string) string {
	if v == "" {
		return "unknown"
	}
	return v
}

// buildVersion returns the module version, which is the git tag for go run
// and go install with an @version suffix, or "dev" for a local build.
func buildVersion() string {
	info, ok := debug.ReadBuildInfo()
	if !ok || info.Main.Version == "" || info.Main.Version == "(devel)" {
		return "dev"
	}
	return info.Main.Version
}
