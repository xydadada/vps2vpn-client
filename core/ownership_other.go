//go:build !(darwin || linux) || android

package core

import "os"

func initOwnership(homeDir string) {}

func scheduleReclaimOwnership() {}

func reclaimDirOwnership(path string) {}

func ownCreatedFile(file *os.File) error { return nil }
