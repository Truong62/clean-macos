package cleaner

import (
	"clean-macos/scanner"
	"fmt"
	"os"
	"syscall"
)

type DeleteResult struct {
	Path    string `json:"path"`
	Name    string `json:"name"`
	Size    int64  `json:"size"`
	Success bool   `json:"success"`
	Error   string `json:"error,omitempty"`
}

type CleanResult struct {
	Deleted    []DeleteResult `json:"deleted"`
	TotalFreed int64          `json:"totalFreed"`
	FreedStr   string         `json:"freedStr"`
	FailCount  int            `json:"failCount"`
	OkCount    int            `json:"okCount"`
}

func DeletePaths(paths []string, rootPath string) *CleanResult {
	result := &CleanResult{}

	for _, path := range paths {
		dr := DeleteResult{
			Path: path,
			Name: basename(path),
		}

		if !scanner.IsSafeToDelete(path, rootPath) {
			dr.Success = false
			dr.Error = "path is not safe to delete"
			result.Deleted = append(result.Deleted, dr)
			result.FailCount++
			continue
		}

		info, err := os.Lstat(path)
		if err != nil {
			dr.Success = false
			dr.Error = fmt.Sprintf("cannot access: %v", err)
			result.Deleted = append(result.Deleted, dr)
			result.FailCount++
			continue
		}

		var size int64
		if info.IsDir() {
			size = getDirSize(path)
		} else {
			size = physicalSize(info)
		}
		dr.Size = size

		err = os.RemoveAll(path)
		if err != nil {
			dr.Success = false
			dr.Error = fmt.Sprintf("delete failed: %v", err)
			result.Deleted = append(result.Deleted, dr)
			result.FailCount++
			continue
		}

		dr.Success = true
		result.Deleted = append(result.Deleted, dr)
		result.TotalFreed += size
		result.OkCount++
	}

	result.FreedStr = scanner.FormatBytes(result.TotalFreed)
	return result
}

func physicalSize(info os.FileInfo) int64 {
	if sys, ok := info.Sys().(*syscall.Stat_t); ok {
		return sys.Blocks * 512
	}
	return info.Size()
}

func basename(path string) string {
	for i := len(path) - 1; i >= 0; i-- {
		if path[i] == '/' {
			return path[i+1:]
		}
	}
	return path
}

func getDirSize(path string) int64 {
	var size int64
	walkDir(path, &size)
	return size
}

func walkDir(path string, size *int64) {
	entries, err := os.ReadDir(path)
	if err != nil {
		return
	}
	for _, e := range entries {
		full := path + "/" + e.Name()
		if e.IsDir() {
			walkDir(full, size)
		} else {
			info, err := os.Lstat(full)
			if err != nil {
				continue
			}
			if info.Mode()&os.ModeSymlink != 0 {
				continue
			}
			*size += physicalSize(info)
		}
	}
}
