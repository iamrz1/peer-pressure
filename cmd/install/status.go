package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"path/filepath"
	"strings"
	"time"

	"github.com/iamrz1/peer-pressure/internal/install"
	"github.com/iamrz1/peer-pressure/skills"
)

const proxyBase = "https://proxy.golang.org"

// latestVersion asks the Go module proxy for the newest release tag.
func latestVersion(ctx context.Context, client *http.Client, base string) (string, error) {
	url := fmt.Sprintf("%s/%s/@latest", base, strings.ToLower(source))
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", err
	}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("proxy returned %s", resp.Status)
	}
	var body struct{ Version string }
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<16)).Decode(&body); err != nil {
		return "", err
	}
	if body.Version == "" {
		return "", fmt.Errorf("proxy returned no version")
	}
	return body.Version, nil
}

// printStatus lists every target with its installed version and hash, then
// the newest release. It never writes to disk.
func printStatus(w io.Writer, targets []string, latest string, latestErr error) {
	for _, dir := range targets {
		dest := filepath.Join(dir, skills.Name)
		m, presence, err := install.Lookup(skills.Name, dir)
		switch {
		case err != nil:
			fmt.Fprintf(w, "%s: error: %v\n", dest, err)
		case presence == install.NotInstalled:
			fmt.Fprintf(w, "%s: not installed\n", dest)
		case presence == install.NotOurs:
			fmt.Fprintf(w, "%s: exists but was not installed by peer-pressure\n", dest)
		default:
			fmt.Fprintf(w, "%s: %s (hash %s)%s\n", dest, orUnknown(m.Version), shortHash(m.Hash), upToDate(m.Version, latest, latestErr))
		}
	}
	if latestErr != nil {
		fmt.Fprintf(w, "latest release: unknown (%v)\n", latestErr)
		return
	}
	fmt.Fprintf(w, "latest release: %s\n", latest)
}

func upToDate(installed, latest string, latestErr error) string {
	if latestErr != nil {
		return ""
	}
	if installed == latest {
		return ", up to date"
	}
	return ", newer release available"
}

func shortHash(h string) string {
	if len(h) > 12 {
		return h[:12]
	}
	return h
}

func fetchLatest() (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return latestVersion(ctx, http.DefaultClient, proxyBase)
}
