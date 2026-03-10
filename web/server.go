package web

import (
	"clean-macos/cleaner"
	"clean-macos/scanner"
	"embed"
	"encoding/json"
	"fmt"
	"io/fs"
	"log"
	"net/http"
	"os"
	"os/exec"
	"runtime"
)

//go:embed static/*
var staticFiles embed.FS

var currentScanPath string

func Start(port int, scanPath string) error {
	currentScanPath = scanPath

	staticFS, err := fs.Sub(staticFiles, "static")
	if err != nil {
		return err
	}
	http.Handle("/", http.FileServer(http.FS(staticFS)))

	http.HandleFunc("/api/scan", handleScan)
	http.HandleFunc("/api/clean", handleClean)
	http.HandleFunc("/api/disk", handleDisk)
	http.HandleFunc("/api/snapshot/delete", handleDeleteSnapshot)

	addr := fmt.Sprintf(":%d", port)
	url := fmt.Sprintf("http://localhost:%d", port)

	fmt.Printf("\n  Clean macOS is running!\n")
	fmt.Printf("  Local: %s\n\n", url)

	go openBrowser(url)

	return http.ListenAndServe(addr, nil)
}

func handleDisk(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	diskInfo, err := scanner.GetDiskInfo("/")
	if err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	jsonResponse(w, diskInfo)
}

func handleScan(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		Path     string `json:"path"`
		MaxDepth int    `json:"maxDepth"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		req.Path = currentScanPath
		req.MaxDepth = 10
	}
	if req.Path == "" {
		req.Path = currentScanPath
	}
	if req.MaxDepth == 0 {
		req.MaxDepth = 10
	}

	result, err := scanner.Scan(req.Path, req.MaxDepth)
	if err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	jsonResponse(w, result)
}

func handleClean(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		Paths []string `json:"paths"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		jsonError(w, "invalid request body", http.StatusBadRequest)
		return
	}
	if len(req.Paths) == 0 {
		jsonError(w, "no paths specified", http.StatusBadRequest)
		return
	}

	result := cleaner.DeletePaths(req.Paths, currentScanPath)
	jsonResponse(w, result)
}

func handleDeleteSnapshot(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		Date string `json:"date"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Date == "" {
		jsonError(w, "date is required", http.StatusBadRequest)
		return
	}

	if err := scanner.DeleteSnapshot(req.Date); err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}

	jsonResponse(w, map[string]string{"status": "ok", "deleted": req.Date})
}

func jsonResponse(w http.ResponseWriter, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(data)
}

func jsonError(w http.ResponseWriter, msg string, code int) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(map[string]string{"error": msg})
}

func openBrowser(url string) {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.Command("open", url)
	case "linux":
		cmd = exec.Command("xdg-open", url)
	default:
		return
	}
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		log.Printf("Failed to open browser: %v", err)
	}
}
