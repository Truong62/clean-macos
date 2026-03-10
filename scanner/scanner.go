package scanner

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

type Artifact struct {
	Path        string   `json:"path"`
	Name        string   `json:"name"`
	Size        int64    `json:"size"`
	SizeHuman   string   `json:"sizeHuman"`
	Category    Category `json:"category"`
	Description string   `json:"description"`
	NeedsSudo   bool     `json:"needsSudo"`
}

type DiskInfo struct {
	Total    uint64  `json:"total"`
	Used     uint64  `json:"used"`
	Free     uint64  `json:"free"`
	UsedPct  float64 `json:"usedPct"`
	TotalStr string  `json:"totalStr"`
	UsedStr  string  `json:"usedStr"`
	FreeStr  string  `json:"freeStr"`
	Hostname string  `json:"hostname"`
	OS       string  `json:"os"`
	Arch     string  `json:"arch"`
}

type ScanResult struct {
	Artifacts []Artifact `json:"artifacts"`
	TotalSize int64      `json:"totalSize"`
	TotalStr  string     `json:"totalStr"`
	DiskInfo  DiskInfo   `json:"diskInfo"`
	ScanPath  string     `json:"scanPath"`
	ItemCount int        `json:"itemCount"`
	Snapshots []Snapshot `json:"snapshots"`
}

type Snapshot struct {
	Name string `json:"name"`
	Date string `json:"date"`
	Size string `json:"size"`
}

var protectedPaths = map[string]bool{
	"/":             true,
	"/bin":          true,
	"/sbin":         true,
	"/usr":          true,
	"/etc":          true,
	"/var":          true,
	"/tmp":          true,
	"/System":       true,
	"/Library":      true,
	"/Applications": true,
	"/Users":        true,
	"/private":      true,
	"/cores":        true,
}

func GetDiskInfo(path string) (DiskInfo, error) {
	var stat syscall.Statfs_t
	if err := syscall.Statfs(path, &stat); err != nil {
		return DiskInfo{}, err
	}

	total := stat.Blocks * uint64(stat.Bsize)
	free := stat.Bavail * uint64(stat.Bsize)
	used := total - free
	usedPct := float64(used) / float64(total) * 100

	hostname, _ := os.Hostname()

	return DiskInfo{
		Total:    total,
		Used:     used,
		Free:     free,
		UsedPct:  usedPct,
		TotalStr: FormatBytes(int64(total)),
		UsedStr:  FormatBytes(int64(used)),
		FreeStr:  FormatBytes(int64(free)),
		Hostname: hostname,
		OS:       runtime.GOOS,
		Arch:     runtime.GOARCH,
	}, nil
}

func Scan(rootPath string, maxDepth int) (*ScanResult, error) {
	absRoot, err := filepath.Abs(rootPath)
	if err != nil {
		return nil, fmt.Errorf("invalid path: %w", err)
	}

	info, err := os.Stat(absRoot)
	if err != nil {
		return nil, fmt.Errorf("path not accessible: %w", err)
	}
	if !info.IsDir() {
		return nil, fmt.Errorf("path is not a directory: %s", absRoot)
	}

	var artifacts []Artifact
	var mu sync.Mutex
	var wg sync.WaitGroup

	wg.Add(1)
	go func() {
		defer wg.Done()
		devArtifacts := scanDevArtifacts(absRoot, maxDepth)
		mu.Lock()
		artifacts = append(artifacts, devArtifacts...)
		mu.Unlock()
	}()

	wg.Add(1)
	go func() {
		defer wg.Done()
		macArtifacts := scanFixedPaths()
		mu.Lock()
		artifacts = append(artifacts, macArtifacts...)
		mu.Unlock()
	}()

	wg.Wait()

	artifacts = deduplicateArtifacts(artifacts)

	sort.Slice(artifacts, func(i, j int) bool {
		return artifacts[i].Size > artifacts[j].Size
	})

	var totalSize int64
	for _, a := range artifacts {
		totalSize += a.Size
	}

	diskInfo, _ := GetDiskInfo("/")
	snapshots := detectSnapshots()

	return &ScanResult{
		Artifacts: artifacts,
		TotalSize: totalSize,
		TotalStr:  FormatBytes(totalSize),
		DiskInfo:  diskInfo,
		ScanPath:  absRoot,
		ItemCount: len(artifacts),
		Snapshots: snapshots,
	}, nil
}

func scanDevArtifacts(absRoot string, maxDepth int) []Artifact {
	patterns := PatternNames()
	var artifacts []Artifact
	var mu sync.Mutex
	sem := make(chan struct{}, 20)

	filepath.Walk(absRoot, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return nil
		}

		if !info.IsDir() {
			if info.Name() == ".DS_Store" {
				if p, ok := patterns[".DS_Store"]; ok {
					mu.Lock()
					artifacts = append(artifacts, Artifact{
						Path:        path,
						Name:        info.Name(),
						Size:        info.Size(),
						SizeHuman:   FormatBytes(info.Size()),
						Category:    p.Category,
						Description: p.Description,
					})
					mu.Unlock()
				}
			}
			return nil
		}

		rel, _ := filepath.Rel(absRoot, path)
		if rel == "." {
			return nil
		}
		depth := len(strings.Split(rel, string(os.PathSeparator)))
		if maxDepth > 0 && depth > maxDepth {
			return filepath.SkipDir
		}

		name := info.Name()

		if name == "Library" && depth <= 2 {
			return filepath.SkipDir
		}

		if p, ok := patterns[name]; ok {
			sem <- struct{}{}
			go func(artifactPath string, pattern Pattern) {
				defer func() { <-sem }()
				size := calculateDirSize(artifactPath)
				mu.Lock()
				artifacts = append(artifacts, Artifact{
					Path:        artifactPath,
					Name:        name,
					Size:        size,
					SizeHuman:   FormatBytes(size),
					Category:    pattern.Category,
					Description: pattern.Description,
				})
				mu.Unlock()
			}(path, p)
			return filepath.SkipDir
		}

		if strings.HasPrefix(name, ".") && path != absRoot {
			if _, ok := patterns[name]; !ok {
				return filepath.SkipDir
			}
		}

		return nil
	})

	for i := 0; i < cap(sem); i++ {
		sem <- struct{}{}
	}

	return artifacts
}

func scanFixedPaths() []Artifact {
	fixedPaths := MacOSFixedPaths()
	var artifacts []Artifact
	var mu sync.Mutex
	var wg sync.WaitGroup
	sem := make(chan struct{}, 10)

	for _, fp := range fixedPaths {
		wg.Add(1)
		go func(fp FixedPath) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()

			fi, err := os.Stat(fp.Path)
			if err != nil {
				return
			}

			var size int64
			if fi.IsDir() {
				size = calculateDirSize(fp.Path)
			} else {
				size = physicalSize(fi)
			}

			if size < 1024*1024 {
				return
			}

			mu.Lock()
			artifacts = append(artifacts, Artifact{
				Path:        fp.Path,
				Name:        fp.Name,
				Size:        size,
				SizeHuman:   FormatBytes(size),
				Category:    fp.Category,
				Description: fp.Description,
				NeedsSudo:   fp.NeedsSudo,
			})
			mu.Unlock()
		}(fp)
	}

	wg.Wait()
	return artifacts
}

func detectSnapshots() []Snapshot {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	out, err := exec.CommandContext(ctx, "tmutil", "listlocalsnapshots", "/").CombinedOutput()
	if err != nil {
		return nil
	}

	var snapshots []Snapshot
	lines := strings.Split(string(out), "\n")
	re := regexp.MustCompile(`(\d{4}-\d{2}-\d{2}-\d{6})`)
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		match := re.FindString(line)
		if match == "" {
			continue
		}
		snapshots = append(snapshots, Snapshot{
			Name: line,
			Date: match,
		})
	}

	if len(snapshots) > 0 {
		sizeOut, err := exec.CommandContext(ctx, "tmutil", "listlocalsnapshots", "/", "-purgeable").CombinedOutput()
		if err == nil {
			sizeRe := regexp.MustCompile(`(\d+)\s+bytes`)
			for _, line := range strings.Split(string(sizeOut), "\n") {
				if m := sizeRe.FindStringSubmatch(line); len(m) > 1 {
					if bytes, err := strconv.ParseInt(m[1], 10, 64); err == nil && bytes > 0 {
						for i := range snapshots {
							snapshots[i].Size = FormatBytes(bytes / int64(len(snapshots)))
						}
					}
				}
			}
		}
	}

	return snapshots
}

func IsSafeToDelete(path, rootPath string) bool {
	absPath, err := filepath.Abs(path)
	if err != nil {
		return false
	}

	if protectedPaths[absPath] {
		return false
	}

	home, _ := os.UserHomeDir()
	if absPath == home {
		return false
	}

	fi, err := os.Lstat(absPath)
	if err != nil {
		return false
	}
	if fi.Mode()&os.ModeSymlink != 0 {
		return false
	}

	return true
}

func DeleteSnapshot(name string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "tmutil", "deletelocalsnapshots", name).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s: %w", strings.TrimSpace(string(out)), err)
	}
	return nil
}

func calculateDirSize(path string) int64 {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	var size atomic.Int64
	calcDirSizeRecursive(ctx, path, 0, 50, &size)
	return size.Load()
}

func calcDirSizeRecursive(ctx context.Context, dir string, depth, maxDepth int, size *atomic.Int64) {
	select {
	case <-ctx.Done():
		return
	default:
	}

	if depth > maxDepth {
		return
	}

	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}

	for _, entry := range entries {
		select {
		case <-ctx.Done():
			return
		default:
		}

		fullPath := filepath.Join(dir, entry.Name())

		info, err := os.Lstat(fullPath)
		if err != nil {
			continue
		}

		if info.Mode()&os.ModeSymlink != 0 {
			continue
		}

		if !info.IsDir() {
			size.Add(physicalSize(info))
		} else {
			calcDirSizeRecursive(ctx, fullPath, depth+1, maxDepth, size)
		}
	}
}

func physicalSize(info os.FileInfo) int64 {
	if sys, ok := info.Sys().(*syscall.Stat_t); ok {
		return sys.Blocks * 512
	}
	return info.Size()
}

func deduplicateArtifacts(artifacts []Artifact) []Artifact {
	sort.Slice(artifacts, func(i, j int) bool {
		return len(artifacts[i].Path) < len(artifacts[j].Path)
	})

	var result []Artifact
	for _, a := range artifacts {
		nested := false
		for _, existing := range result {
			if strings.HasPrefix(a.Path, existing.Path+string(os.PathSeparator)) {
				nested = true
				break
			}
		}
		if !nested {
			result = append(result, a)
		}
	}
	return result
}

func FormatBytes(bytes int64) string {
	const unit = 1024
	if bytes < unit {
		return fmt.Sprintf("%d B", bytes)
	}
	div, exp := int64(unit), 0
	for n := bytes / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %s", float64(bytes)/float64(div), []string{"KB", "MB", "GB", "TB"}[exp])
}
