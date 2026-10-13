package main

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/iamrz1/peer-pressure/internal/install"
	"github.com/iamrz1/peer-pressure/skills"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func stubProxy(status int, body string) *http.Client {
	return &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/github.com/iamrz1/peer-pressure/@latest" {
			status, body = http.StatusNotFound, ""
		}
		return &http.Response{
			StatusCode: status,
			Status:     http.StatusText(status),
			Body:       io.NopCloser(strings.NewReader(body)),
			Header:     http.Header{},
			Request:    r,
		}, nil
	})}
}

func TestLatestVersion(t *testing.T) {
	ok := stubProxy(http.StatusOK, `{"Version":"v1.2.3","Time":"2026-01-01T00:00:00Z"}`)
	got, err := latestVersion(context.Background(), ok, "https://proxy.example")
	if err != nil || got != "v1.2.3" {
		t.Fatalf("got %q, %v", got, err)
	}

	if _, err := latestVersion(context.Background(), ok, "https://proxy.example/missing"); err == nil {
		t.Fatal("want an error for a 404")
	}
	if _, err := latestVersion(context.Background(), stubProxy(http.StatusOK, `{}`), "https://proxy.example"); err == nil {
		t.Fatal("want an error when the version is empty")
	}
	if _, err := latestVersion(context.Background(), stubProxy(http.StatusOK, `not json`), "https://proxy.example"); err == nil {
		t.Fatal("want an error for bad JSON")
	}
}

func installAt(t *testing.T, version string) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "skills")
	_, err := install.Install(skills.FS, skills.Name, skills.Name, dir, install.Options{Source: source, Version: version})
	if err != nil {
		t.Fatal(err)
	}
	return dir
}

func TestPrintStatus(t *testing.T) {
	current := installAt(t, "v1.0.0")
	old := installAt(t, "v0.9.0")
	empty := filepath.Join(t.TempDir(), "skills")

	foreign := filepath.Join(t.TempDir(), "skills")
	if err := os.MkdirAll(filepath.Join(foreign, skills.Name), 0o755); err != nil {
		t.Fatal(err)
	}

	var out bytes.Buffer
	printStatus(&out, []string{current, old, empty, foreign}, "v1.0.0", nil)
	got := out.String()

	for _, want := range []string{
		"v1.0.0 (hash ",
		", up to date",
		"v0.9.0 (hash ",
		", newer release available",
		"not installed",
		"was not installed by peer-pressure",
		"latest release: v1.0.0",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("output is missing %q:\n%s", want, got)
		}
	}
}

func TestPrintStatusWithoutNetwork(t *testing.T) {
	dir := installAt(t, "v1.0.0")
	var out bytes.Buffer
	printStatus(&out, []string{dir}, "", errors.New("offline"))
	got := out.String()
	if strings.Contains(got, "up to date") || strings.Contains(got, "newer release") {
		t.Errorf("must not claim a comparison when the lookup failed:\n%s", got)
	}
	if !strings.Contains(got, "latest release: unknown (offline)") {
		t.Errorf("missing the unknown line:\n%s", got)
	}
}

func TestStatusDoesNotWrite(t *testing.T) {
	base := t.TempDir()
	dir := filepath.Join(base, "skills")
	var out bytes.Buffer
	printStatus(&out, []string{dir}, "v1.0.0", nil)
	if _, err := os.Stat(dir); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("status created %s", dir)
	}
}
