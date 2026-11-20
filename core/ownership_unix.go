//go:build (darwin || linux) && !android

package core

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/metacubex/mihomo/log"
)

const reclaimDebounce = 2 * time.Second

var (
	realUid = os.Getuid()
	realGid = os.Getgid()

	reclaimPending atomic.Bool
	reclaimHomeDir atomic.Value
)

func isElevated() bool {
	return os.Geteuid() == 0 && realUid != 0
}

func canReclaim(homeDir string, uid int) bool {
	if homeDir == "" {
		return false
	}
	info, err := os.Lstat(homeDir)
	if err != nil || !info.IsDir() {
		return false
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	return ok && int(stat.Uid) == uid
}

func openReclaimRoot(homeDir string, uid int) (*os.Root, error) {
	if !canReclaim(homeDir, uid) {
		return nil, fs.ErrPermission
	}
	root, err := os.OpenRoot(homeDir)
	if err != nil {
		return nil, err
	}
	info, err := root.Stat(".")
	if err == nil {
		stat, ok := info.Sys().(*syscall.Stat_t)
		if !ok || int(stat.Uid) != uid {
			err = fs.ErrPermission
		}
	}
	if err != nil {
		_ = root.Close()
		return nil, err
	}
	return root, nil
}

func shouldReclaimEntry(info fs.FileInfo, uid int) bool {
	if info.Mode()&fs.ModeSymlink != 0 {
		return false
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return false
	}
	if int(stat.Uid) == uid {
		return false
	}
	return info.IsDir() || stat.Nlink <= 1
}

type reclaimTarget struct {
	path string
	dev  uint64
	ino  uint64
}

func collectReclaimTargets(root *os.Root, uid int) []reclaimTarget {
	var targets []reclaimTarget
	_ = fs.WalkDir(root.FS(), ".", func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		info, infoErr := d.Info()
		if infoErr != nil {
			return nil
		}
		if !shouldReclaimEntry(info, uid) {
			return nil
		}
		stat, ok := info.Sys().(*syscall.Stat_t)
		if !ok {
			return nil
		}
		targets = append(targets, reclaimTarget{
			path: path,
			dev:  uint64(stat.Dev),
			ino:  uint64(stat.Ino),
		})
		return nil
	})
	return targets
}

func isReclaimableStat(stat *syscall.Stat_t, uid int) bool {
	switch stat.Mode & syscall.S_IFMT {
	case syscall.S_IFDIR:
	case syscall.S_IFREG:
		if stat.Nlink > 1 {
			return false
		}
	default:
		return false
	}
	return int(stat.Uid) != uid
}

func reclaimEntry(root *os.Root, target reclaimTarget, uid int, gid int) (bool, error) {
	file, err := root.OpenFile(
		target.path,
		syscall.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK|syscall.O_CLOEXEC,
		0,
	)
	if err != nil {
		return false, err
	}
	defer file.Close()
	var stat syscall.Stat_t
	if err := syscall.Fstat(int(file.Fd()), &stat); err != nil {
		return false, err
	}
	if uint64(stat.Dev) != target.dev || uint64(stat.Ino) != target.ino {
		return false, nil
	}
	if !isReclaimableStat(&stat, uid) {
		return false, nil
	}
	if err := file.Chown(uid, gid); err != nil {
		return false, err
	}
	return true, nil
}

func reclaimOwnership(homeDir string) {
	if !isElevated() {
		return
	}
	root, err := openReclaimRoot(homeDir, realUid)
	if err != nil {
		return
	}
	defer root.Close()
	targets := collectReclaimTargets(root, realUid)
	if len(targets) == 0 {
		return
	}
	reclaimed := 0
	for _, target := range targets {
		ok, err := reclaimEntry(root, target, realUid, realGid)
		if err != nil {
			if !errors.Is(err, fs.ErrNotExist) {
				log.Warnln("[APP] reclaim %s: %v", target.path, err)
			}
			continue
		}
		if ok {
			reclaimed++
		}
	}
	log.Infoln("[APP] reclaimed %d of %d elevated entries under %s", reclaimed, len(targets), homeDir)
}

func reclaimDirOwnership(path string) {
	homeDir, _ := reclaimHomeDir.Load().(string)
	if !isElevated() {
		return
	}
	root, err := openReclaimRoot(homeDir, realUid)
	if err != nil {
		return
	}
	defer root.Close()
	relative, err := filepath.Rel(homeDir, path)
	if err != nil {
		return
	}
	info, err := root.Lstat(relative)
	if err != nil || !info.IsDir() || !shouldReclaimEntry(info, realUid) {
		return
	}
	stat := info.Sys().(*syscall.Stat_t)
	target := reclaimTarget{path: relative, dev: uint64(stat.Dev), ino: uint64(stat.Ino)}
	if _, err := reclaimEntry(root, target, realUid, realGid); err != nil {
		log.Warnln("[APP] reclaim %s: %v", path, err)
	}
}

func initOwnership(homeDir string) {
	reclaimHomeDir.Store(homeDir)
	reclaimOwnership(homeDir)
}

func scheduleReclaimOwnership() {
	if !isElevated() {
		return
	}
	homeDir, _ := reclaimHomeDir.Load().(string)
	if homeDir == "" {
		return
	}
	if !reclaimPending.CompareAndSwap(false, true) {
		return
	}
	go func() {
		time.Sleep(reclaimDebounce)
		reclaimPending.Store(false)
		reclaimOwnership(homeDir)
	}()
}

func ownCreatedFile(file *os.File) error {
	if isElevated() {
		return file.Chown(realUid, realGid)
	}
	return nil
}
