package core

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/metacubex/mihomo/constant"
)

func withProviderHome(t *testing.T) string {
	t.Helper()
	previous := constant.Path.HomeDir()
	initialized := isInit.Load()
	home := t.TempDir()
	constant.SetHomeDir(home)
	isInit.Store(true)
	t.Cleanup(func() {
		constant.SetHomeDir(previous)
		isInit.Store(initialized)
	})
	return home
}

func TestClearEffectRemovesOnlyTheSelectedProfile(t *testing.T) {
	home := withProviderHome(t)
	_, target := providerPaths(home, 17)
	_, sibling := providerPaths(home, 18)
	for _, path := range []string{target, sibling} {
		if err := os.MkdirAll(path, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(path, "cache"), []byte("provider data"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := handleClearEffect(ClearEffectParams{ProfileID: 17}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(target); !os.IsNotExist(err) {
		t.Fatalf("selected profile was not removed: %v", err)
	}
	if _, err := os.Stat(filepath.Join(sibling, "cache")); err != nil {
		t.Fatalf("sibling profile was changed: %v", err)
	}
	if err := handleClearEffect(ClearEffectParams{ProfileID: 17}); err != nil {
		t.Fatalf("removing an already absent profile: %v", err)
	}
}

func TestClearEffectRejectsAnAncestorSymlinkOutsideTheHome(t *testing.T) {
	for _, linkedPart := range []string{"profiles", "providers"} {
		t.Run(linkedPart, func(t *testing.T) {
			home := withProviderHome(t)
			outside := t.TempDir()
			parent := home
			cache := filepath.Join(outside, "providers", "17")
			if linkedPart == "providers" {
				parent = filepath.Join(home, "profiles")
				cache = filepath.Join(outside, "17")
			}
			if err := os.MkdirAll(parent, 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.MkdirAll(cache, 0o700); err != nil {
				t.Fatal(err)
			}
			sentinel := filepath.Join(cache, "keep")
			if err := os.WriteFile(sentinel, []byte("unrelated data"), 0o600); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(outside, filepath.Join(parent, linkedPart)); err != nil {
				t.Skipf("directory symlink unavailable: %v", err)
			}
			if err := handleClearEffect(ClearEffectParams{ProfileID: 17}); err == nil {
				t.Error("accepted a provider cache outside the configured home")
			}
			data, err := os.ReadFile(sentinel)
			if err != nil || string(data) != "unrelated data" {
				t.Fatalf("external file was changed: data=%q err=%v", data, err)
			}
		})
	}
}
