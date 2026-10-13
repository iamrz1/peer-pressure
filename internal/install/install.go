// Package install copies an embedded skill into agent skills directories.
//
// A directory is replaced only when it carries a marker file written by this
// package. Anything else under the same name is treated as someone else's skill
// and left alone unless the caller forces the replacement.
package install

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
)

// MarkerFile is written into every installed skill directory. Its presence is
// the only proof that this package owns the directory.
const MarkerFile = ".peer-pressure-install.json"

// Marker is the content of MarkerFile.
type Marker struct {
	Source  string `json:"source"`
	Version string `json:"version"`
	Hash    string `json:"hash"`
}

// Options controls one install or uninstall run.
type Options struct {
	// Source is recorded in the marker, for example the module path.
	Source string
	// Version is recorded in the marker.
	Version string
	// DryRun reports what would happen without touching the disk.
	DryRun bool
	// Force replaces a directory that has no marker.
	Force bool
}

// Status describes what happened to one target.
type Status string

// Possible results for a target.
const (
	Installed Status = "installed"
	Updated   Status = "updated"
	Unchanged Status = "unchanged"
	Removed   Status = "removed"
	Absent    Status = "not installed"
)

// Result is the outcome for one skills directory.
type Result struct {
	Dir    string
	Status Status
	// Previous is the version found in the old marker, if any.
	Previous string
}

// ErrNotOwned means the destination exists without this package's marker.
var ErrNotOwned = errors.New("directory exists and was not installed by peer-pressure")

// Install writes the skill rooted at root inside src into dir/<name>.
func Install(src fs.FS, root, name, dir string, opts Options) (Result, error) {
	res := Result{Dir: dir}

	files, err := readTree(src, root)
	if err != nil {
		return res, err
	}
	hash := treeHash(files)
	dest := filepath.Join(dir, name)

	old, state, err := inspect(dest)
	if err != nil {
		return res, err
	}
	res.Previous = old.Version

	switch state {
	case stateMissing:
		res.Status = Installed
	case stateOwned:
		if old.Hash == hash {
			res.Status = Unchanged
			return res, nil
		}
		res.Status = Updated
	case stateForeign:
		if !opts.Force {
			return res, fmt.Errorf("%s: %w (use -force to replace it)", dest, ErrNotOwned)
		}
		res.Status = Updated
	}

	if opts.DryRun {
		return res, nil
	}

	// Stage next to the skills directory, not inside it: agents scan the skills
	// directory, and a half-written skill must never be visible there. The same
	// parent keeps the final rename on one filesystem.
	parent := filepath.Dir(dir)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return res, err
	}
	stage, err := os.MkdirTemp(parent, ".peer-pressure-stage-")
	if err != nil {
		return res, err
	}
	defer os.RemoveAll(stage)

	staged := filepath.Join(stage, name)
	if err := writeTree(staged, files); err != nil {
		return res, err
	}
	marker, err := json.MarshalIndent(Marker{Source: opts.Source, Version: opts.Version, Hash: hash}, "", "  ")
	if err != nil {
		return res, err
	}
	if err := os.WriteFile(filepath.Join(staged, MarkerFile), append(marker, '\n'), 0o644); err != nil {
		return res, err
	}

	if state != stateMissing {
		aside := filepath.Join(stage, "old")
		if err := os.Rename(dest, aside); err != nil {
			return res, fmt.Errorf("move old copy aside: %w", err)
		}
		if err := os.Rename(staged, dest); err != nil {
			// Put the old copy back so the user is not left without a skill.
			_ = os.Rename(aside, dest)
			return res, fmt.Errorf("move new copy into place: %w", err)
		}
		return res, nil
	}
	if err := os.Rename(staged, dest); err != nil {
		return res, fmt.Errorf("move new copy into place: %w", err)
	}
	return res, nil
}

// Uninstall removes dir/<name> if this package installed it.
func Uninstall(name, dir string, opts Options) (Result, error) {
	res := Result{Dir: dir}
	dest := filepath.Join(dir, name)

	old, state, err := inspect(dest)
	if err != nil {
		return res, err
	}
	res.Previous = old.Version

	switch state {
	case stateMissing:
		res.Status = Absent
		return res, nil
	case stateForeign:
		if !opts.Force {
			return res, fmt.Errorf("%s: %w (use -force to remove it)", dest, ErrNotOwned)
		}
	}
	res.Status = Removed
	if opts.DryRun {
		return res, nil
	}
	return res, os.RemoveAll(dest)
}

type destState int

const (
	stateMissing destState = iota
	stateOwned
	stateForeign
)

func inspect(dest string) (Marker, destState, error) {
	info, err := os.Lstat(dest)
	if errors.Is(err, fs.ErrNotExist) {
		return Marker{}, stateMissing, nil
	}
	if err != nil {
		return Marker{}, 0, err
	}
	// A symlink is somebody else's arrangement. Never write through it.
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return Marker{}, stateForeign, nil
	}
	raw, err := os.ReadFile(filepath.Join(dest, MarkerFile))
	if errors.Is(err, fs.ErrNotExist) {
		return Marker{}, stateForeign, nil
	}
	if err != nil {
		return Marker{}, 0, err
	}
	var m Marker
	if err := json.Unmarshal(raw, &m); err != nil {
		return Marker{}, stateForeign, nil
	}
	return m, stateOwned, nil
}

type file struct {
	rel  string
	data []byte
	mode fs.FileMode
}

func readTree(src fs.FS, root string) ([]file, error) {
	var files []file
	err := fs.WalkDir(src, root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		data, err := fs.ReadFile(src, p)
		if err != nil {
			return err
		}
		rel := strings.TrimPrefix(p, root+"/")
		files = append(files, file{rel: rel, data: data, mode: modeFor(rel)})
		return nil
	})
	if err != nil {
		return nil, err
	}
	if len(files) == 0 {
		return nil, fmt.Errorf("no files found under %q", root)
	}
	sort.Slice(files, func(i, j int) bool { return files[i].rel < files[j].rel })
	return files, nil
}

// modeFor makes shell scripts executable. Embedded files carry no mode bits.
func modeFor(rel string) fs.FileMode {
	if strings.HasPrefix(rel, "scripts/") && path.Ext(rel) == ".sh" {
		return 0o755
	}
	return 0o644
}

func writeTree(dir string, files []file) error {
	for _, f := range files {
		p := filepath.Join(dir, filepath.FromSlash(f.rel))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(p, f.data, f.mode); err != nil {
			return err
		}
		// WriteFile is subject to the umask. Set the mode explicitly.
		if err := os.Chmod(p, f.mode); err != nil {
			return err
		}
	}
	return nil
}

func treeHash(files []file) string {
	h := sha256.New()
	for _, f := range files {
		fmt.Fprintf(h, "%s\x00%o\x00%d\x00", f.rel, f.mode, len(f.data))
		h.Write(f.data)
	}
	return hex.EncodeToString(h.Sum(nil))
}

// Presence tells whether a skill directory exists and who owns it.
type Presence int

// Possible values for Presence.
const (
	NotInstalled Presence = iota
	// Ours means the directory carries this package's marker.
	Ours
	// NotOurs means something else occupies the name.
	NotOurs
)

// Lookup reports what is installed at dir/<name> without changing anything.
// The marker is only filled in when the result is Ours.
func Lookup(name, dir string) (Marker, Presence, error) {
	m, state, err := inspect(filepath.Join(dir, name))
	if err != nil {
		return Marker{}, NotInstalled, err
	}
	switch state {
	case stateOwned:
		return m, Ours, nil
	case stateForeign:
		return Marker{}, NotOurs, nil
	}
	return Marker{}, NotInstalled, nil
}
