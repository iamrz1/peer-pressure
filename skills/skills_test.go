package skills

import (
	"io/fs"
	"regexp"
	"strings"
	"testing"
)

func skillFile(t *testing.T, rel string) string {
	t.Helper()
	b, err := fs.ReadFile(FS, Name+"/"+rel)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func frontmatter(t *testing.T, doc string) map[string]string {
	t.Helper()
	parts := strings.SplitN(doc, "\n---\n", 2)
	if !strings.HasPrefix(parts[0], "---\n") || len(parts) != 2 {
		t.Fatal("SKILL.md must start with a --- frontmatter block")
	}
	out := map[string]string{}
	for _, line := range strings.Split(strings.TrimPrefix(parts[0], "---\n"), "\n") {
		if k, v, ok := strings.Cut(line, ":"); ok && !strings.HasPrefix(line, " ") {
			out[strings.TrimSpace(k)] = strings.TrimSpace(v)
		}
	}
	return out
}

func TestFrontmatter(t *testing.T) {
	doc := skillFile(t, "SKILL.md")
	fm := frontmatter(t, doc)

	if fm["name"] != Name {
		t.Errorf("name = %q, want %q (must match the directory)", fm["name"], Name)
	}
	if !regexp.MustCompile(`^[a-z0-9]+(-[a-z0-9]+)*$`).MatchString(fm["name"]) || len(fm["name"]) > 64 {
		t.Errorf("name %q is not a valid skill name", fm["name"])
	}
	if n := len(fm["description"]); n < 40 || n > 1024 {
		t.Errorf("description length = %d, want 40 to 1024", n)
	}
	allowed := map[string]bool{"name": true, "description": true, "license": true, "compatibility": true, "metadata": true}
	for k := range fm {
		if !allowed[k] {
			t.Errorf("frontmatter key %q is not portable across agents", k)
		}
	}
}

func TestSkillBodyIsShort(t *testing.T) {
	if n := strings.Count(skillFile(t, "SKILL.md"), "\n"); n > 500 {
		t.Errorf("SKILL.md has %d lines, keep it under 500 and move detail into references/", n)
	}
}

func TestReferencesAreLinkedBothWays(t *testing.T) {
	doc := skillFile(t, "SKILL.md")

	// Every file under references/ and scripts/ must be mentioned in SKILL.md.
	err := fs.WalkDir(FS, Name, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		rel := strings.TrimPrefix(p, Name+"/")
		if rel == "SKILL.md" {
			return nil
		}
		base := rel[strings.LastIndex(rel, "/")+1:]
		if !strings.Contains(doc, base) {
			t.Errorf("%s is never mentioned in SKILL.md", rel)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}

	// Every references/ or scripts/ path in SKILL.md must exist.
	for _, m := range regexp.MustCompile("(?:references|scripts)/[A-Za-z0-9_./-]+\\.(?:md|sh)").FindAllString(doc, -1) {
		if _, err := fs.Stat(FS, Name+"/"+m); err != nil {
			t.Errorf("SKILL.md mentions %s, which does not exist", m)
		}
	}
}

func TestPerspectiveTableMatchesFiles(t *testing.T) {
	doc := skillFile(t, "SKILL.md")
	entries, err := fs.ReadDir(FS, Name+"/references/perspectives")
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if !strings.Contains(doc, "`"+e.Name()+"`") {
			t.Errorf("perspective %s is missing from the SKILL.md table", e.Name())
		}
	}
}

func TestNoStaleOrPrivateContent(t *testing.T) {
	banned := regexp.MustCompile(`(?i)deepreview|mcp__|\.ai/|/Users/|getoutreach|outreach\.io|mechanai`)
	err := fs.WalkDir(FS, Name, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		b, err := fs.ReadFile(FS, p)
		if err != nil {
			return err
		}
		if m := banned.Find(b); m != nil {
			t.Errorf("%s contains %q", p, m)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

func perspectiveNames(t *testing.T) []string {
	t.Helper()
	entries, err := fs.ReadDir(FS, Name+"/references/perspectives")
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, e := range entries {
		names = append(names, strings.TrimSuffix(e.Name(), ".md"))
	}
	return names
}

func TestPromptsNameEveryPerspective(t *testing.T) {
	merger := skillFile(t, "references/pipeline/merger.md")
	validator := skillFile(t, "references/pipeline/validator.md")
	quick := skillFile(t, "references/pipeline/quick-reviewer.md")
	for _, perspective := range perspectiveNames(t) {
		if !strings.Contains(merger, "`"+perspective+"`") {
			t.Errorf("merger.md does not list the %q source name", perspective)
		}
		if !strings.Contains(validator, "| "+perspective+" |") {
			t.Errorf("validator.md has no scoring row for the %q lens", perspective)
		}
		if !strings.Contains(quick, "`"+perspective+"`") {
			t.Errorf("quick-reviewer.md does not list the %q source name", perspective)
		}
	}
}

func TestTableMapsEveryPerspectiveToAnIcon(t *testing.T) {
	table := skillFile(t, "scripts/render-table.sh")
	for _, perspective := range perspectiveNames(t) {
		if !strings.Contains(table, perspective+`: "`) {
			t.Errorf("render-table.sh has no icon for the %q perspective", perspective)
		}
	}
}

func TestTableColumns(t *testing.T) {
	table := skillFile(t, "scripts/render-table.sh")
	if !strings.Contains(table, `["#", "File", "Sev", "Urgency", "Review", "Fix"]`) {
		t.Error("render-table.sh must draw the six columns")
	}
}

func TestUrgencyLevelsAreConsistent(t *testing.T) {
	levels := []string{"insist", "ask", "author", "optional"}
	for _, f := range []string{"references/pipeline/triage.md", "scripts/render-table.sh", "scripts/build-report.sh"} {
		doc := skillFile(t, f)
		for _, level := range levels {
			if !strings.Contains(doc, level) {
				t.Errorf("%s does not mention the urgency level %q", f, level)
			}
		}
	}
}

func TestReviewersDropNitsEarly(t *testing.T) {
	files := []string{"references/pipeline/quick-reviewer.md"}
	for _, perspective := range perspectiveNames(t) {
		files = append(files, "references/perspectives/"+perspective+".md")
	}
	for _, f := range files {
		doc := skillFile(t, f)
		if !strings.Contains(doc, "## Drop nits early") {
			t.Errorf("%s has no \"Drop nits early\" section", f)
		}
		if strings.Contains(doc, "critical | warning | suggestion") {
			t.Errorf("%s still offers reviewers a suggestion level", f)
		}
	}
}

func TestStackedChangesAreHandled(t *testing.T) {
	doc := skillFile(t, "SKILL.md")
	for _, want := range []string{"find-base.sh", "STACK_PREAMBLE", "--base", "STACKED"} {
		if !strings.Contains(doc, want) {
			t.Errorf("SKILL.md does not mention %q", want)
		}
	}
	if n := strings.Count(doc, "<CONTEXT><STACK_PREAMBLE><PRIOR_PREAMBLE>"); n != 2 {
		t.Errorf("reviewer prompts carry the stack preamble %d times, want 2", n)
	}
}
