package main

import (
	"clean-macos/web"
	"flag"
	"fmt"
	"os"
	"path/filepath"
)

func main() {
	port := flag.Int("port", 8080, "Server port")
	scanPath := flag.String("path", "", "Default scan path")
	flag.Parse()

	if *scanPath == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			home = "/"
		}
		*scanPath = filepath.Dir(home) // e.g. /Users
	}

	fmt.Println("Clean macOS - Development Artifact Cleaner")
	if err := web.Start(*port, *scanPath); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}
