package main

import (
	"crypto/sha1"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func mustGit(t *testing.T, directory string, args ...string) string {
	t.Helper()
	output, err := gitOutput(directory, args...)
	if err != nil {
		t.Fatal(err)
	}
	return output
}

func writeFixture(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0644); err != nil {
		t.Fatal(err)
	}
}

func fixtureBlob(content string) string {
	input := fmt.Sprintf("blob %d\x00%s", len(content), content)
	return fmt.Sprintf("%x", sha1.Sum([]byte(input)))
}

func patchFixture(t *testing.T) (string, patchSpec) {
	t.Helper()
	root := t.TempDir()
	core := filepath.Join(root, filepath.FromSlash(coreSubmodule))
	if err := os.MkdirAll(core, 0755); err != nil {
		t.Fatal(err)
	}
	for _, directory := range []string{root, core} {
		mustGit(t, directory, "init", "-q")
		mustGit(t, directory, "config", "user.email", "fixture@example.invalid")
		mustGit(t, directory, "config", "user.name", "Fixture")
		mustGit(t, directory, "config", "core.autocrlf", "false")
		mustGit(t, directory, "config", "commit.gpgSign", "false")
	}
	before := "package route\n\nvar value = 1\n"
	after := "package route\n\nvar value = 2\n"
	writeFixture(t, filepath.Join(core, filepath.FromSlash(controllerSource)), before)
	mustGit(t, core, "add", controllerSource)
	mustGit(t, core, "commit", "-qm", "fixture")
	revision := mustGit(t, core, "rev-parse", "HEAD")
	mustGit(t, root, "update-index", "--add", "--cacheinfo", "160000,"+revision+","+coreSubmodule)
	mustGit(t, root, "commit", "-qm", "fixture")
	diff := "diff --git a/hub/route/server.go b/hub/route/server.go\n" +
		"--- a/hub/route/server.go\n+++ b/hub/route/server.go\n" +
		"@@ -1,3 +1,3 @@\n package route\n \n-var value = 1\n+var value = 2\n"
	writeFixture(t, filepath.Join(root, filepath.FromSlash(controllerDiff)), diff)
	return root, patchSpec{revision: revision, diff: fixtureBlob(diff), before: fixtureBlob(before), after: fixtureBlob(after)}
}

func TestControllerPatchAppliesOnceAndVerifiesTheResult(t *testing.T) {
	root, spec := patchFixture(t)
	for range 2 {
		if err := applyControllerPatch(root, spec); err != nil {
			t.Fatal(err)
		}
	}
	actual := mustGit(t, filepath.Join(root, coreSubmodule), "hash-object", controllerSource)
	if actual != spec.after {
		t.Fatalf("got blob %s, want %s", actual, spec.after)
	}
}

func TestControllerPatchDoesNotOverwriteSourceDrift(t *testing.T) {
	root, spec := patchFixture(t)
	path := filepath.Join(root, coreSubmodule, controllerSource)
	drift := "package route\n\nvar value = 3\n"
	writeFixture(t, path, drift)
	if err := applyControllerPatch(root, spec); err == nil {
		t.Fatal("unexpected source was accepted")
	}
	actual, err := os.ReadFile(path)
	if err != nil || string(actual) != drift {
		t.Fatalf("source drift was overwritten: %q, %v", actual, err)
	}
}

func TestControllerPatchRefusesAnotherGitlink(t *testing.T) {
	root, spec := patchFixture(t)
	spec.revision = strings.Repeat("0", 40)
	if err := applyControllerPatch(root, spec); err == nil {
		t.Fatal("unreviewed gitlink was accepted")
	}
}

func TestControllerPatchRefusesAnotherCheckout(t *testing.T) {
	root, spec := patchFixture(t)
	core := filepath.Join(root, coreSubmodule)
	mustGit(t, core, "commit", "--allow-empty", "-qm", "another revision")
	if err := applyControllerPatch(root, spec); err == nil {
		t.Fatal("checkout differing from the gitlink was accepted")
	}
}

func TestConcurrentControllerPatchCallsShareOneApplication(t *testing.T) {
	root, spec := patchFixture(t)
	var wait sync.WaitGroup
	errors := make(chan error, 4)
	for range 4 {
		wait.Add(1)
		go func() {
			defer wait.Done()
			errors <- applyControllerPatch(root, spec)
		}()
	}
	wait.Wait()
	close(errors)
	for err := range errors {
		if err != nil {
			t.Fatal(err)
		}
	}
}

func TestControllerPatchRefusesAnAdditionalUnreviewedFile(t *testing.T) {
	for _, alreadyApplied := range []bool{false, true} {
		t.Run(fmt.Sprintf("alreadyApplied=%t", alreadyApplied), func(t *testing.T) {
			root, spec := patchFixture(t)
			if alreadyApplied {
				if err := applyControllerPatch(root, spec); err != nil {
					t.Fatal(err)
				}
			}
			core := filepath.Join(root, coreSubmodule)
			before := mustGit(t, core, "hash-object", controllerSource)
			path := filepath.Join(root, controllerDiff)
			diff, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			extra := "diff --git a/unreviewed.txt b/unreviewed.txt\n" +
				"new file mode 100644\n--- /dev/null\n+++ b/unreviewed.txt\n" +
				"@@ -0,0 +1 @@\n+unreviewed\n"
			writeFixture(t, path, string(diff)+extra)
			if err := applyControllerPatch(root, spec); err == nil {
				t.Fatal("unreviewed extra hunk was accepted")
			}
			if after := mustGit(t, core, "hash-object", controllerSource); after != before {
				t.Fatal("source was changed before rejecting the extra hunk")
			}
			if _, err := os.Stat(filepath.Join(core, "unreviewed.txt")); !os.IsNotExist(err) {
				t.Fatalf("extra file was created: %v", err)
			}
		})
	}
}
