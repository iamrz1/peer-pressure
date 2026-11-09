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

	// Every file under references/ must be mentioned in SKILL.md. A script may be
	// mentioned by SKILL.md, by a reference, or by another script that calls it.
	var others []string
	err := fs.WalkDir(FS, Name, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		if rel := strings.TrimPrefix(p, Name+"/"); rel != "SKILL.md" {
			others = append(others, rel)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, rel := range others {
		base := rel[strings.LastIndex(rel, "/")+1:]
		mentioned := strings.Contains(doc, base)
		if !mentioned && strings.HasPrefix(rel, "scripts/") {
			for _, other := range others {
				if other != rel && strings.Contains(skillFile(t, other), base) {
					mentioned = true
					break
				}
			}
		}
		if !mentioned {
			t.Errorf("%s is never mentioned in SKILL.md", rel)
		}
	}

	// Every references/ or scripts/ path in SKILL.md must exist.
	for _, m := range regexp.MustCompile("(?:references|scripts)/[A-Za-z0-9_./-]+\\.(?:md|sh)").FindAllString(doc, -1) {
		if _, err := fs.Stat(FS, Name+"/"+m); err != nil {
			t.Errorf("SKILL.md mentions %s, which does not exist", m)
		}
	}
}

func TestBabysitProcedureUsesItsScripts(t *testing.T) {
	if !strings.Contains(skillFile(t, "SKILL.md"), "references/babysit.md") {
		t.Error("SKILL.md does not route babysit to references/babysit.md")
	}
	procedure := skillFile(t, "references/babysit.md")
	scripts, err := fs.Glob(FS, Name+"/scripts/babysit-*.sh")
	if err != nil || len(scripts) == 0 {
		t.Fatalf("no babysit scripts found: %v", err)
	}
	for _, p := range scripts {
		if base := p[strings.LastIndex(p, "/")+1:]; !strings.Contains(procedure, base) {
			t.Errorf("references/babysit.md never uses %s", base)
		}
	}
	for _, rule := range []string{"what it never does", "merge, push", "submit a review", "pending review"} {
		if !strings.Contains(strings.ToLower(procedure), rule) {
			t.Errorf("references/babysit.md does not state %q", rule)
		}
	}
}

func TestToiAndMoiAreRouted(t *testing.T) {
	doc := skillFile(t, "SKILL.md")
	for _, want := range []string{"`toi`", "`moi`", "references/moi.md", "references/babysit.md"} {
		if !strings.Contains(doc, want) {
			t.Errorf("SKILL.md does not mention %s", want)
		}
	}
	if !strings.Contains(skillFile(t, "references/babysit.md"), "toi") {
		t.Error("references/babysit.md does not mention its alias toi")
	}

	procedure := skillFile(t, "references/moi.md")
	if !strings.Contains(procedure, "moi-track.sh") {
		t.Error("references/moi.md never uses moi-track.sh")
	}
	for _, want := range []string{"babysit-poll.sh", "babysit-wait.sh", "babysit-post.sh", "--as author", "--replies-now"} {
		if !strings.Contains(procedure, want) {
			t.Errorf("references/moi.md never uses %s", want)
		}
	}
	for _, name := range []string{"references/babysit.md", "references/moi.md"} {
		for _, want := range []string{"workdir.sh", "remove"} {
			if !strings.Contains(skillFile(t, name), want) {
				t.Errorf("%s does not use workdir.sh %s", name, want)
			}
		}
	}
	for _, rule := range []string{"what it never does", "force-push or amend", "merge the pr", "submit a review", "resolve a thread that someone else started", "clean"} {
		if !strings.Contains(strings.ToLower(procedure), rule) {
			t.Errorf("references/moi.md does not state %q", rule)
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
	verifier := skillFile(t, "references/pipeline/verifier.md")
	bar := skillFile(t, "references/bar.md")
	quick := skillFile(t, "references/pipeline/quick-reviewer.md")
	cluster := skillFile(t, "scripts/cluster-findings.sh")
	score := skillFile(t, "scripts/score-findings.sh")
	for _, perspective := range perspectiveNames(t) {
		if !strings.Contains(verifier, "`"+perspective+"`") {
			t.Errorf("verifier.md does not list the %q source name", perspective)
		}
		if !strings.Contains(bar, "| "+perspective+" |") {
			t.Errorf("bar.md has no score row for the %q lens", perspective)
		}
		if !strings.Contains(quick, "`"+perspective+"`") {
			t.Errorf("quick-reviewer.md does not list the %q source name", perspective)
		}
		for name, script := range map[string]string{"cluster-findings.sh": cluster, "score-findings.sh": score} {
			if !strings.Contains(script, `"`+perspective+`"`) {
				t.Errorf("%s does not know the %q lens", name, perspective)
			}
		}
	}
}

func TestEveryPerspectiveHasAReviewer(t *testing.T) {
	doc := skillFile(t, "SKILL.md")
	rows := regexp.MustCompile("(?m)^\\| (behavior|contracts|structure) \\| (.+?) \\|").FindAllStringSubmatch(doc, -1)
	if len(rows) != 3 {
		t.Fatalf("SKILL.md has %d reviewer rows, want 3", len(rows))
	}
	seen := map[string]int{}
	for _, row := range rows {
		for _, f := range regexp.MustCompile("`([a-z]+)\\.md`").FindAllStringSubmatch(row[2], -1) {
			seen[f[1]]++
		}
	}
	for _, perspective := range perspectiveNames(t) {
		if seen[perspective] != 1 {
			t.Errorf("perspective %q is owned by %d reviewers, want 1", perspective, seen[perspective])
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
	for _, f := range []string{"references/pipeline/urgency.md", "scripts/render-table.sh", "scripts/build-report.sh"} {
		doc := skillFile(t, f)
		for _, level := range levels {
			if !strings.Contains(doc, level) {
				t.Errorf("%s does not mention the urgency level %q", f, level)
			}
		}
	}
}

func TestReviewersApplyTheBar(t *testing.T) {
	files := []string{"references/pipeline/quick-reviewer.md"}
	for _, perspective := range perspectiveNames(t) {
		files = append(files, "references/perspectives/"+perspective+".md")
	}
	for _, f := range files {
		doc := skillFile(t, f)
		if !strings.Contains(doc, "## Review bar") || !strings.Contains(doc, "`bar.md`") {
			t.Errorf("%s has no \"Review bar\" section pointing at bar.md", f)
		}
		if strings.Contains(doc, "## Drop nits early") {
			t.Errorf("%s has its own copy of the nit rules; they live in bar.md", f)
		}
		if strings.Contains(doc, "critical | warning | suggestion") {
			t.Errorf("%s still offers reviewers a suggestion level", f)
		}
	}
	for _, perspective := range perspectiveNames(t) {
		if !strings.Contains(skillFile(t, "references/perspectives/"+perspective+".md"), "`reviewer.md`") {
			t.Errorf("%s.md does not point at reviewer.md for its output format", perspective)
		}
	}
	// The quick reviewer, the full reviewers and the verifier each get the bar in their prompt.
	if n := strings.Count(skillFile(t, "SKILL.md"), "references/bar.md"); n != 3 {
		t.Errorf("SKILL.md names bar.md in %d prompts, want 3", n)
	}
	bar := skillFile(t, "references/bar.md")
	for _, want := range []string{"## Evidence", "## Scores", "`unsound`", "`regression`", "`intent`", "`convention`", "`docs`"} {
		if !strings.Contains(bar, want) {
			t.Errorf("bar.md does not contain %q", want)
		}
	}
}

func TestVerifierDefinesTheVerdicts(t *testing.T) {
	verifier := skillFile(t, "references/pipeline/verifier.md")
	for _, want := range []string{"`confirmed`", "`plausible`", "`nit`", "`disproved`", "`confidence`", "`argument`", "`urgency`"} {
		if !strings.Contains(verifier, want) {
			t.Errorf("verifier.md does not contain %q", want)
		}
	}
	apply := skillFile(t, "scripts/apply-verdicts.sh")
	for _, want := range []string{"confirmed", "plausible", "nit", "disproved"} {
		if !strings.Contains(apply, want) {
			t.Errorf("apply-verdicts.sh does not handle the %q verdict", want)
		}
	}
}

func TestStackedChangesAreHandled(t *testing.T) {
	doc := skillFile(t, "SKILL.md")
	for _, want := range []string{"find-base.sh", "find-stack.sh", "stack-context.sh", "assign-prs.sh", "STACK_PREAMBLE", "--base", "--stack", "--single", "STACKED"} {
		if !strings.Contains(doc, want) {
			t.Errorf("SKILL.md does not mention %q", want)
		}
	}
	if n := strings.Count(doc, "<CONTEXT><STACK_PREAMBLE><PRIOR_PREAMBLE>"); n != 2 {
		t.Errorf("reviewer prompts carry the stack preamble %d times, want 2", n)
	}
}
