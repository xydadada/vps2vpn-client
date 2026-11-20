// Applies the reviewed controller fix to the pinned Core dependency.
package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

type patchSpec struct {
	revision string
	diff     string
	before   string
	after    string
}

var fallbackPatch = patchSpec{
	revision: "5b453f80dbcee6b3ecfb0415bcace24a48c88707",
	diff:     "bed09cb88c6e1f9f8fa8d945ced19a76e9aea0c0",
	before:   "d6f61348844ca88c64bd017a8bb8255dfadfe8a6",
	after:    "c712aee4c8ee69dcfb15e674addb330bf4bed589",
}

var controllerPatch = patchSpec{
	revision: "5b453f80dbcee6b3ecfb0415bcace24a48c88707",
	diff:     "7e5d6c980ab7f5e514fde3e43ba4be8e46346442",
	before:   "b1659cd085d278193a94ed860e3bfd9a8721d95e",
	after:    "edae0d6beff38ebf3df994da317a4fac7d6944c1",
}

const coreSubmodule = "core/Clash.Meta"
const controllerSource = "hub/route/server.go"
const controllerDiff = "tool/patches/clash-meta-controller-lifecycle.patch"
const fallbackSource = "adapter/outboundgroup/fallback.go"
const fallbackDiff = "tool/patches/clash-meta-fallback-concurrency.patch"

func gitOutput(directory string, args ...string) (string, error) {
	command := exec.Command("git", args...)
	command.Dir = directory
	output, err := command.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("git %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(string(output)))
	}
	return strings.TrimSpace(string(output)), nil
}

func applyControllerPatch(root string, expected patchSpec) error {
	return applyVerifiedCorePatch(root, expected, controllerSource, controllerDiff)
}

func applyVerifiedCorePatch(root string, expected patchSpec, sourcePath, diffPath string) error {
	link, err := gitOutput(root, "rev-parse", "HEAD:"+coreSubmodule)
	if err != nil {
		return err
	}
	if link != expected.revision {
		return fmt.Errorf("Core gitlink %s is not the reviewed revision %s", link, expected.revision)
	}
	core := filepath.Join(root, filepath.FromSlash(coreSubmodule))
	revision, err := gitOutput(core, "rev-parse", "HEAD")
	if err != nil {
		return err
	}
	if revision != expected.revision {
		return fmt.Errorf("Core checkout %s does not match the gitlink %s", revision, expected.revision)
	}
	patch := filepath.Join(root, filepath.FromSlash(diffPath))
	patchHash, err := gitOutput(root, "hash-object", "--path="+diffPath, diffPath)
	if err != nil {
		return err
	}
	if patchHash != expected.diff {
		return fmt.Errorf("Core controller patch %s is not the reviewed patch %s; refusing to apply it", patchHash, expected.diff)
	}
	gitDir, err := gitOutput(core, "rev-parse", "--absolute-git-dir")
	if err != nil {
		return err
	}
	lock := filepath.Join(gitDir, "vps2vpn-controller-patch.lock")
	deadline := time.Now().Add(30 * time.Second)
	for {
		err = os.Mkdir(lock, 0700)
		if err == nil {
			break
		}
		if !os.IsExist(err) || time.Now().After(deadline) {
			return fmt.Errorf("cannot acquire Core patch lock %s: %w", lock, err)
		}
		time.Sleep(50 * time.Millisecond)
	}
	defer os.Remove(lock)

	hash, err := gitOutput(core, "hash-object", "--path="+sourcePath, sourcePath)
	if err != nil {
		return err
	}
	if hash == expected.after {
		fmt.Println("Core controller patch already verified")
		return nil
	}
	if hash != expected.before {
		return fmt.Errorf("Core controller source %s matches neither reviewed input nor output; refusing to overwrite it", hash)
	}
	if _, err = gitOutput(core, "apply", "--check", "--ignore-space-change", patch); err != nil {
		return err
	}
	if _, err = gitOutput(core, "apply", "--ignore-space-change", patch); err != nil {
		return err
	}
	hash, err = gitOutput(core, "hash-object", "--path="+sourcePath, sourcePath)
	if err != nil {
		return err
	}
	if hash != expected.after {
		return fmt.Errorf("Core controller patch produced unexpected source %s; build stopped", hash)
	}
	fmt.Println("Core controller patch applied and verified")
	return nil
}

func main() {
	root, err := gitOutput("", "rev-parse", "--show-toplevel")
	if err == nil {
		err = applyControllerPatch(root, controllerPatch)
		if err == nil {
			err = applyVerifiedCorePatch(root, fallbackPatch, fallbackSource, fallbackDiff)
		}
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
