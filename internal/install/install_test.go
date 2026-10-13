package install

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
	"testing/fstest"
)

func skillFS(body string) fstest.MapFS {
	return fstest.MapFS{
		"s/SKILL.md":             {Data: []byte(body)},
		"s/references/a.md":      {Data: []byte("a")},
		"s/scripts/run.sh":       {Data: []byte("#!/bin/sh\n")},
		"s/scripts/notes.txt":    {Data: []byte("n")},
		"s/references/deep/b.md": {Data: []byte("b")},
	}
}

func opts(version string) Options { return Options{Source: "test", Version: version} }

func mustRead(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestInstallFresh(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "skills")
	res, err := Install(skillFS("one"), "s", "demo", dir, opts("v1"))
	if err != nil {
		t.Fatal(err)
	}
	if res.Status != Installed {
		t.Fatalf("status = %s, want installed", res.Status)
	}
	if got := mustRead(t, filepath.Join(dir, "demo", "SKILL.md")); got != "one" {
		t.Fatalf("SKILL.md = %q", got)
	}
	if got := mustRead(t, filepath.Join(dir, "demo", "references", "deep", "b.md")); got != "b" {
		t.Fatalf("nested file = %q", got)
	}
	if _, err := os.Stat(filepath.Join(dir, "demo", MarkerFile)); err != nil {
		t.Fatalf("marker missing: %v", err)
	}
}

func TestScriptsAreExecutable(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "skills")
	if _, err := Install(skillFS("one"), "s", "demo", dir, opts("v1")); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(filepath.Join(dir, "demo", "scripts", "run.sh"))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm()&0o111 == 0 {
		t.Fatalf("run.sh mode = %v, want executable", info.Mode())
	}
	info, err = os.Stat(filepath.Join(dir, "demo", "scripts", "notes.txt"))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm()&0o111 != 0 {
		t.Fatalf("notes.txt mode = %v, want not executable", info.Mode())
	}
}

func TestUnchangedWhenSameContent(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "skills")
	if _, err := Install(skillFS("one"), "s", "demo", dir, opts("v1")); err != nil {
		t.Fatal(err)
	}
	res, err := Install(skillFS("one"), "s", "demo", dir, opts("v2"))
	if err != nil {
		t.Fatal(err)
	}
	if res.Status != Unchanged {
		t.Fatalf("status = %s, want unchanged", res.Status)
	}
}

func TestUpdateReplacesAndDropsStaleFiles(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "skills")
	if _, err := Install(skillFS("one"), "s", "demo", dir, opts("v1")); err != nil {
		t.Fatal(err)
	}
	next := skillFS("two")
	delete(next, "s/references/a.md")
	res, err := Install(next, "s", "demo", dir, opts("v2"))
	if err != nil {
		t.Fatal(err)
	}
	if res.Status != Updated || res.Previous != "v1" {
		t.Fatalf("result = %+v, want updated from v1", res)
	}
	if got := mustRead(t, filepath.Join(dir, "demo", "SKILL.md")); got != "two" {
		t.Fatalf("SKILL.md = %q", got)
	}
	if _, err := os.Stat(filepath.Join(dir, "demo", "references", "a.md")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("stale file still present: %v", err)
	}
}

func TestRefusesForeignDirectory(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "skills")
	foreign := filepath.Join(dir, "demo")
	if err := os.MkdirAll(foreign, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(foreign, "SKILL.md"), []byte("mine"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := Install(skillFS("one"), "s", "demo", dir, opts("v1"))
	if !errors.Is(err, ErrNotOwned) {
		t.Fatalf("err = %v, want ErrNotOwned", err)
	}
	if got := mustRead(t, filepath.Join(foreign, "SKILL.md")); got != "mine" {
		t.Fatalf("foreign file was changed: %q", got)
	}
}

func TestForceReplacesForeignDirectory(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "skills")
	foreign := filepath.Join(dir, "demo")
	if err := os.MkdirAll(foreign, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(foreign, "SKILL.md"), []byte("mine"), 0o644); err != nil {
		t.Fatal(err)
	}
	o := opts("v1")
	o.Force = true
	if _, err := Install(skillFS("one"), "s", "demo", dir, o); err != nil {
		t.Fatal(err)
	}
	if got := mustRead(t, filepath.Join(foreign, "SKILL.md")); got != "one" {
		t.Fatalf("SKILL.md = %q", got)
	}
}

func TestRefusesSymlink(t *testing.T) {
	base := t.TempDir()
	dir := filepath.Join(base, "skills")
	target := filepath.Join(base, "elsewhere")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(dir, "demo")); err != nil {
		t.Skip("symlinks not supported")
	}
	_, err := Install(skillFS("one"), "s", "demo", dir, opts("v1"))
	if !errors.Is(err, ErrNotOwned) {
		t.Fatalf("err = %v, want ErrNotOwned", err)
	}
	entries, _ := os.ReadDir(target)
	if len(entries) != 0 {
		t.Fatalf("wrote through the symlink: %v", entries)
	}
}

func TestDryRunWritesNothing(t *testing.T) {
	base := t.TempDir()
	dir := filepath.Join(base, "skills")
	o := opts("v1")
	o.DryRun = true
	res, err := Install(skillFS("one"), "s", "demo", dir, o)
	if err != nil {
		t.Fatal(err)
	}
	if res.Status != Installed {
		t.Fatalf("status = %s", res.Status)
	}
	if _, err := os.Stat(dir); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("dry run created %s", dir)
	}
}

func TestNoStagingLeftBehind(t *testing.T) {
	base := t.TempDir()
	dir := filepath.Join(base, "skills")
	if _, err := Install(skillFS("one"), "s", "demo", dir, opts("v1")); err != nil {
		t.Fatal(err)
	}
	if _, err := Install(skillFS("two"), "s", "demo", dir, opts("v2")); err != nil {
		t.Fatal(err)
	}
	entries, err := os.ReadDir(base)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].Name() != "skills" {
		t.Fatalf("leftovers next to skills dir: %v", entries)
	}
}

func TestUninstall(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "skills")
	if res, err := Uninstall("demo", dir, opts("v1")); err != nil || res.Status != Absent {
		t.Fatalf("missing: res=%+v err=%v", res, err)
	}
	if _, err := Install(skillFS("one"), "s", "demo", dir, opts("v1")); err != nil {
		t.Fatal(err)
	}
	if res, err := Uninstall("demo", dir, opts("v1")); err != nil || res.Status != Removed {
		t.Fatalf("owned: res=%+v err=%v", res, err)
	}
	if _, err := os.Stat(filepath.Join(dir, "demo")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("directory still present: %v", err)
	}

	foreign := filepath.Join(dir, "demo")
	if err := os.MkdirAll(foreign, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := Uninstall("demo", dir, opts("v1")); !errors.Is(err, ErrNotOwned) {
		t.Fatalf("foreign err = %v, want ErrNotOwned", err)
	}
}
