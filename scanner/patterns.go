package scanner

import (
	"os"
	"path/filepath"
)

type Category string

const (
	CategoryDependencies   Category = "dependencies"
	CategoryBuild          Category = "build"
	CategoryCache          Category = "cache"
	CategoryCoverage       Category = "coverage"
	CategoryInfrastructure Category = "infrastructure"
	CategoryLogs           Category = "logs"
	CategoryMisc           Category = "misc"
	CategorySystem         Category = "system"
	CategoryXcode          Category = "xcode"
	CategoryDocker         Category = "docker"
	CategoryBackup         Category = "backup"
	CategoryMail           Category = "mail"
	CategoryMedia          Category = "media"
	CategoryVM             Category = "vm"
	CategoryDownloads      Category = "downloads"
	CategoryCrash          Category = "crash"
)

type Pattern struct {
	Name        string   `json:"name"`
	Category    Category `json:"category"`
	Description string   `json:"description"`
}

type FixedPath struct {
	Path        string   `json:"path"`
	Name        string   `json:"name"`
	Category    Category `json:"category"`
	Description string   `json:"description"`
	NeedsSudo   bool     `json:"needsSudo"`
}

func DefaultPatterns() []Pattern {
	return []Pattern{
		{Name: "node_modules", Category: CategoryDependencies, Description: "npm/yarn/pnpm dependencies"},
		{Name: ".pnpm", Category: CategoryDependencies, Description: "pnpm store"},
		{Name: "bower_components", Category: CategoryDependencies, Description: "Bower dependencies"},
		{Name: "vendor", Category: CategoryDependencies, Description: "Vendored dependencies (Go/PHP/Ruby)"},
		{Name: ".venv", Category: CategoryDependencies, Description: "Python virtual environment"},
		{Name: "venv", Category: CategoryDependencies, Description: "Python virtual environment"},
		{Name: ".bundle", Category: CategoryDependencies, Description: "Ruby bundler"},
		{Name: "Pods", Category: CategoryDependencies, Description: "CocoaPods dependencies"},

		{Name: "dist", Category: CategoryBuild, Description: "Distribution build output"},
		{Name: "build", Category: CategoryBuild, Description: "Build output directory"},
		{Name: ".next", Category: CategoryBuild, Description: "Next.js build output"},
		{Name: ".nuxt", Category: CategoryBuild, Description: "Nuxt.js build output"},
		{Name: ".output", Category: CategoryBuild, Description: "Nuxt 3 build output"},
		{Name: "target", Category: CategoryBuild, Description: "Rust/Java/Scala build output"},
		{Name: ".svelte-kit", Category: CategoryBuild, Description: "SvelteKit build output"},
		{Name: ".angular", Category: CategoryBuild, Description: "Angular cache/build"},
		{Name: "storybook-static", Category: CategoryBuild, Description: "Storybook build output"},

		{Name: ".parcel-cache", Category: CategoryCache, Description: "Parcel bundler cache"},
		{Name: ".turbo", Category: CategoryCache, Description: "Turborepo cache"},
		{Name: ".pytest_cache", Category: CategoryCache, Description: "Pytest cache"},
		{Name: "__pycache__", Category: CategoryCache, Description: "Python bytecode cache"},
		{Name: ".eslintcache", Category: CategoryCache, Description: "ESLint cache"},
		{Name: ".sass-cache", Category: CategoryCache, Description: "Sass preprocessor cache"},
		{Name: ".webpack", Category: CategoryCache, Description: "Webpack cache"},
		{Name: ".gradle", Category: CategoryCache, Description: "Gradle cache"},
		{Name: ".dart_tool", Category: CategoryCache, Description: "Dart tool cache"},

		{Name: "coverage", Category: CategoryCoverage, Description: "Code coverage reports"},
		{Name: ".nyc_output", Category: CategoryCoverage, Description: "NYC coverage output"},
		{Name: "htmlcov", Category: CategoryCoverage, Description: "Python HTML coverage reports"},

		{Name: ".terraform", Category: CategoryInfrastructure, Description: "Terraform provider cache"},

		{Name: ".DS_Store", Category: CategoryMisc, Description: "macOS directory metadata"},
	}
}

func MacOSFixedPaths() []FixedPath {
	home, _ := os.UserHomeDir()

	paths := []FixedPath{
		{
			Path:        filepath.Join(home, "Library/Caches"),
			Name:        "User Caches",
			Category:    CategorySystem,
			Description: "All application caches (Safari, Chrome, Spotify, Homebrew, pip, etc.)",
		},
		{
			Path:        filepath.Join(home, "Library/Logs"),
			Name:        "User Logs",
			Category:    CategoryLogs,
			Description: "Application log files",
		},
		{
			Path:        filepath.Join(home, ".Trash"),
			Name:        "Trash",
			Category:    CategorySystem,
			Description: "Files in Trash (not yet permanently deleted)",
		},
		{
			Path:        "/Library/Caches",
			Name:        "System Caches",
			Category:    CategorySystem,
			Description: "System-level application caches",
			NeedsSudo:   true,
		},
		{
			Path:        "/var/log",
			Name:        "System Logs",
			Category:    CategoryLogs,
			Description: "System log files (asl, install, wifi, etc.)",
			NeedsSudo:   true,
		},
		{
			Path:        "/private/var/folders",
			Name:        "Temporary Items",
			Category:    CategorySystem,
			Description: "Per-user temporary files & caches (managed by macOS)",
			NeedsSudo:   true,
		},
		{
			Path:        filepath.Join(home, "Library/Logs/DiagnosticReports"),
			Name:        "User Crash Reports",
			Category:    CategoryCrash,
			Description: "Application crash logs (.ips, .crash files)",
		},
		{
			Path:        "/Library/Logs/DiagnosticReports",
			Name:        "System Crash Reports",
			Category:    CategoryCrash,
			Description: "System-level crash & hang reports",
			NeedsSudo:   true,
		},
		{
			Path:        "/cores",
			Name:        "Core Dumps",
			Category:    CategoryCrash,
			Description: "Process core dump files (can be 1-10GB each)",
			NeedsSudo:   true,
		},
		{
			Path:        filepath.Join(home, "Library/Logs/JetBrains"),
			Name:        "JetBrains Logs",
			Category:    CategoryCrash,
			Description: "IntelliJ/WebStorm/PyCharm IDE logs",
		},
		{
			Path:        filepath.Join(home, "Library/Developer/Xcode/DerivedData"),
			Name:        "Xcode DerivedData",
			Category:    CategoryXcode,
			Description: "Build intermediates & indexes (often 10-50GB+)",
		},
		{
			Path:        filepath.Join(home, "Library/Developer/Xcode/Archives"),
			Name:        "Xcode Archives",
			Category:    CategoryXcode,
			Description: "Archived app builds (.xcarchive)",
		},
		{
			Path:        filepath.Join(home, "Library/Developer/Xcode/iOS DeviceSupport"),
			Name:        "iOS DeviceSupport",
			Category:    CategoryXcode,
			Description: "Debug symbols for connected iOS devices (2-5GB per iOS version)",
		},
		{
			Path:        filepath.Join(home, "Library/Developer/Xcode/watchOS DeviceSupport"),
			Name:        "watchOS DeviceSupport",
			Category:    CategoryXcode,
			Description: "Debug symbols for connected Apple Watch",
		},
		{
			Path:        filepath.Join(home, "Library/Developer/Xcode/tvOS DeviceSupport"),
			Name:        "tvOS DeviceSupport",
			Category:    CategoryXcode,
			Description: "Debug symbols for Apple TV",
		},
		{
			Path:        filepath.Join(home, "Library/Developer/CoreSimulator/Devices"),
			Name:        "iOS Simulators",
			Category:    CategoryXcode,
			Description: "iOS/watchOS/tvOS simulator data (can be 20GB+)",
		},
		{
			Path:        filepath.Join(home, "Library/Developer/CoreSimulator/Caches"),
			Name:        "Simulator Caches",
			Category:    CategoryXcode,
			Description: "Simulator runtime caches",
		},
		{
			Path:        filepath.Join(home, "Library/Developer/Xcode/UserData/IB Support"),
			Name:        "Xcode IB Support",
			Category:    CategoryXcode,
			Description: "Interface Builder support cache",
		},
		{
			Path:        filepath.Join(home, "Library/Developer/Xcode/Products"),
			Name:        "Xcode Products",
			Category:    CategoryXcode,
			Description: "Built products from Xcode",
		},
		{
			Path:        filepath.Join(home, "Library/Containers/com.docker.docker/Data"),
			Name:        "Docker Data",
			Category:    CategoryDocker,
			Description: "Docker images, containers, volumes",
		},
		{
			Path:        filepath.Join(home, ".docker"),
			Name:        "Docker Config & Cache",
			Category:    CategoryDocker,
			Description: "Docker CLI config, buildx cache",
		},
		{
			Path:        filepath.Join(home, "Library/Application Support/MobileSync/Backup"),
			Name:        "iPhone/iPad Backups",
			Category:    CategoryBackup,
			Description: "Local iOS device backups (10-50GB each!)",
		},
		{
			Path:        filepath.Join(home, ".android/avd"),
			Name:        "Android Emulator AVDs",
			Category:    CategoryVM,
			Description: "Android emulator virtual device images (2-10GB each)",
		},
		{
			Path:        filepath.Join(home, "Library/Android/sdk"),
			Name:        "Android SDK",
			Category:    CategoryInfrastructure,
			Description: "Android SDK, build tools, platform images",
		},
		{
			Path:        filepath.Join(home, "Parallels"),
			Name:        "Parallels VMs",
			Category:    CategoryVM,
			Description: "Parallels Desktop virtual machine images (20-60GB each)",
		},
		{
			Path:        filepath.Join(home, "Virtual Machines.localized"),
			Name:        "VMware VMs",
			Category:    CategoryVM,
			Description: "VMware Fusion virtual machine images",
		},
		{
			Path:        filepath.Join(home, "VirtualBox VMs"),
			Name:        "VirtualBox VMs",
			Category:    CategoryVM,
			Description: "VirtualBox virtual machine images",
		},
		{
			Path:        filepath.Join(home, "Library/Mail"),
			Name:        "Apple Mail Data",
			Category:    CategoryMail,
			Description: "Mail messages & attachments (can grow to many GB over years)",
		},
		{
			Path:        filepath.Join(home, "Library/Mail Downloads"),
			Name:        "Mail Downloads",
			Category:    CategoryMail,
			Description: "Opened mail attachment files",
		},
		{
			Path:        filepath.Join(home, "Library/Group Containers/243LU875E5.groups.com.apple.podcasts"),
			Name:        "Apple Podcasts",
			Category:    CategoryMedia,
			Description: "Downloaded podcast episodes",
		},
		{
			Path:        filepath.Join(home, "Library/Group Containers/group.com.apple.music"),
			Name:        "Apple Music Cache",
			Category:    CategoryMedia,
			Description: "Offline Apple Music downloads & cache",
		},
		{
			Path:        filepath.Join(home, "Library/Application Support/Spotify/PersistentCache"),
			Name:        "Spotify Cache",
			Category:    CategoryMedia,
			Description: "Spotify offline/streaming cache",
		},
		{
			Path:        filepath.Join(home, "Downloads"),
			Name:        "Downloads",
			Category:    CategoryDownloads,
			Description: "Your Downloads folder (review before deleting!)",
		},
		{
			Path:        filepath.Join(home, ".npm/_cacache"),
			Name:        "npm Cache",
			Category:    CategoryCache,
			Description: "npm content-addressable cache",
		},
		{
			Path:        filepath.Join(home, ".cache/pnpm"),
			Name:        "pnpm Cache",
			Category:    CategoryCache,
			Description: "pnpm global store cache",
		},
		{
			Path:        filepath.Join(home, ".pnpm-store"),
			Name:        "pnpm Store",
			Category:    CategoryCache,
			Description: "pnpm global content-addressable store",
		},
		{
			Path:        filepath.Join(home, "go/pkg/mod/cache"),
			Name:        "Go Module Cache",
			Category:    CategoryCache,
			Description: "Go module download cache",
		},
		{
			Path:        filepath.Join(home, ".cargo/registry"),
			Name:        "Cargo Registry",
			Category:    CategoryCache,
			Description: "Rust cargo crate registry cache",
		},
		{
			Path:        filepath.Join(home, ".cargo/git"),
			Name:        "Cargo Git Cache",
			Category:    CategoryCache,
			Description: "Rust cargo git dependency cache",
		},
		{
			Path:        filepath.Join(home, ".m2/repository"),
			Name:        "Maven Cache",
			Category:    CategoryCache,
			Description: "Maven local repository cache",
		},
		{
			Path:        filepath.Join(home, ".gradle/caches"),
			Name:        "Gradle Caches",
			Category:    CategoryCache,
			Description: "Gradle build caches",
		},
		{
			Path:        filepath.Join(home, ".gradle/wrapper/dists"),
			Name:        "Gradle Wrapper Dists",
			Category:    CategoryCache,
			Description: "Downloaded Gradle wrapper distributions",
		},
		{
			Path:        filepath.Join(home, ".composer/cache"),
			Name:        "Composer Cache",
			Category:    CategoryCache,
			Description: "PHP Composer cache",
		},
		{
			Path:        filepath.Join(home, ".gem/cache"),
			Name:        "RubyGems Cache",
			Category:    CategoryCache,
			Description: "RubyGems download cache",
		},
		{
			Path:        filepath.Join(home, ".cocoapods/repos"),
			Name:        "CocoaPods Repos",
			Category:    CategoryCache,
			Description: "CocoaPods spec repositories (~1-3GB)",
		},
		{
			Path:        filepath.Join(home, ".pub-cache"),
			Name:        "Dart/Flutter Cache",
			Category:    CategoryCache,
			Description: "Dart pub package cache",
		},
		{
			Path:        filepath.Join(home, ".nuget/packages"),
			Name:        "NuGet Cache",
			Category:    CategoryCache,
			Description: ".NET NuGet package cache",
		},
		{
			Path:        filepath.Join(home, "Library/Application Support/Code/Cache"),
			Name:        "VS Code Cache",
			Category:    CategoryCache,
			Description: "Visual Studio Code cache",
		},
		{
			Path:        filepath.Join(home, "Library/Application Support/Code/CachedData"),
			Name:        "VS Code CachedData",
			Category:    CategoryCache,
			Description: "VS Code cached bytecode",
		},
		{
			Path:        filepath.Join(home, "Library/Application Support/Code/CachedExtensionVSIXs"),
			Name:        "VS Code Extension Cache",
			Category:    CategoryCache,
			Description: "VS Code cached extension downloads",
		},
		{
			Path:        filepath.Join(home, "Library/Application Support/Code/User/workspaceStorage"),
			Name:        "VS Code Workspace Storage",
			Category:    CategoryCache,
			Description: "VS Code per-workspace data (search index, etc.)",
		},
		{
			Path:        filepath.Join(home, "Library/Application Support/Slack/Cache"),
			Name:        "Slack Cache",
			Category:    CategoryCache,
			Description: "Slack app cache",
		},
		{
			Path:        filepath.Join(home, "Library/Application Support/Slack/Service Worker/CacheStorage"),
			Name:        "Slack Service Worker",
			Category:    CategoryCache,
			Description: "Slack service worker cache",
		},
		{
			Path:        filepath.Join(home, "Library/Application Support/discord/Cache"),
			Name:        "Discord Cache",
			Category:    CategoryCache,
			Description: "Discord app cache",
		},
		{
			Path:        filepath.Join(home, "Library/Application Support/Microsoft Teams/Cache"),
			Name:        "Teams Cache",
			Category:    CategoryCache,
			Description: "Microsoft Teams cache",
		},
		{
			Path:        filepath.Join(home, "Library/Application Support/Figma/Cache"),
			Name:        "Figma Cache",
			Category:    CategoryCache,
			Description: "Figma desktop app cache",
		},
		{
			Path:        filepath.Join(home, "Library/Application Support/notion-enhancer/Cache"),
			Name:        "Notion Cache",
			Category:    CategoryCache,
			Description: "Notion app cache",
		},
		{
			Path:        filepath.Join(home, "Library/Application Support/Zoom/data"),
			Name:        "Zoom Data",
			Category:    CategoryCache,
			Description: "Zoom recordings, cache and data",
		},
		{
			Path:        filepath.Join(home, "Library/Application Support/Telegram Desktop/tdata/user_data"),
			Name:        "Telegram Cache",
			Category:    CategoryCache,
			Description: "Telegram media & message cache",
		},
		{
			Path:        filepath.Join(home, "Library/Application Support/AddressBook/Sources"),
			Name:        "Contacts Images",
			Category:    CategoryMisc,
			Description: "Contact photo cache",
		},
		{
			Path:        filepath.Join(home, "Library/Containers/com.apple.Safari/Data/Library/Caches"),
			Name:        "Safari Container Cache",
			Category:    CategorySystem,
			Description: "Safari sandboxed cache",
		},
		{
			Path:        filepath.Join(home, "Library/Saved Application State"),
			Name:        "Saved App State",
			Category:    CategoryMisc,
			Description: "Window positions & states of closed apps",
		},
		{
			Path:        filepath.Join(home, "Library/Application Support/CrashReporter"),
			Name:        "App Crash Reporter",
			Category:    CategoryCrash,
			Description: "Application crash report data",
		},
		{
			Path:        "/tmp",
			Name:        "System Temp",
			Category:    CategorySystem,
			Description: "System temporary files",
			NeedsSudo:   true,
		},
		{
			Path:        "/private/var/tmp",
			Name:        "Private Temp",
			Category:    CategorySystem,
			Description: "Persistent temporary files (survive reboot)",
			NeedsSudo:   true,
		},

		{
			Path:        filepath.Join(home, "Library/Messages"),
			Name:        "iMessage Data",
			Category:    CategorySystem,
			Description: "iMessage/SMS history, photos, videos, attachments",
		},
		{
			Path:        filepath.Join(home, "Library/Messages/Attachments"),
			Name:        "iMessage Attachments",
			Category:    CategorySystem,
			Description: "Photos/videos/files received via iMessage",
		},
		{
			Path:        filepath.Join(home, "Movies"),
			Name:        "Movies",
			Category:    CategoryMedia,
			Description: "Movie files, screen recordings, Final Cut projects",
		},
		{
			Path:        filepath.Join(home, "Music"),
			Name:        "Music Library",
			Category:    CategoryMedia,
			Description: "Music files, GarageBand projects, Logic Pro data",
		},
		{
			Path:        filepath.Join(home, "Pictures/Photos Library.photoslibrary"),
			Name:        "Photos Library",
			Category:    CategoryMedia,
			Description: "Apple Photos library (originals + thumbnails)",
		},
		{
			Path:        filepath.Join(home, "Library/Application Support/Steam"),
			Name:        "Steam Games",
			Category:    CategoryMedia,
			Description: "Steam game installations and data",
		},
		{
			Path:        "/Library/Updates",
			Name:        "System Updates",
			Category:    CategorySystem,
			Description: "Downloaded macOS update files",
			NeedsSudo:   true,
		},
		{
			Path:        "/private/var/db/diagnostics",
			Name:        "System Diagnostics",
			Category:    CategorySystem,
			Description: "Unified logging diagnostics data",
			NeedsSudo:   true,
		},
		{
			Path:        "/private/var/db/uuidtext",
			Name:        "UUID Text Data",
			Category:    CategorySystem,
			Description: "Unified logging text data",
			NeedsSudo:   true,
		},
		{
			Path:        filepath.Join(home, "Library/Caches/com.apple.helpd"),
			Name:        "Help Cache",
			Category:    CategorySystem,
			Description: "macOS Help Viewer cache",
		},
		{
			Path:        filepath.Join(home, "Library/Application Support/iLifeMediaBrowser"),
			Name:        "iLife Media Browser",
			Category:    CategorySystem,
			Description: "Media browser thumbnail cache",
		},
		{
			Path:        filepath.Join(home, "Library/Metadata/CoreSpotlight"),
			Name:        "Spotlight Index",
			Category:    CategorySystem,
			Description: "Spotlight search index data",
		},
		{
			Path:        "/private/var/db/receipts",
			Name:        "Install Receipts",
			Category:    CategorySystem,
			Description: "Package installation receipts (BOM files)",
			NeedsSudo:   true,
		},
		{
			Path:        "/Library/Application Support/Apple/AssetCache/Data",
			Name:        "Content Cache",
			Category:    CategorySystem,
			Description: "Apple Content Caching data (shared updates/apps)",
			NeedsSudo:   true,
		},
		{
			Path:        filepath.Join(home, "Library/Safari"),
			Name:        "Safari Data",
			Category:    CategorySystem,
			Description: "Safari history, bookmarks, local storage, databases",
		},
		{
			Path:        filepath.Join(home, "Library/WebKit"),
			Name:        "WebKit Data",
			Category:    CategorySystem,
			Description: "WebKit local storage, databases, service workers",
		},
		{
			Path:        filepath.Join(home, "Library/Cookies"),
			Name:        "Cookies",
			Category:    CategorySystem,
			Description: "Browser and app cookies",
		},
		{
			Path:        "/usr/local/Cellar",
			Name:        "Homebrew Cellar",
			Category:    CategoryInfrastructure,
			Description: "Installed Homebrew formula versions",
		},
		{
			Path:        "/usr/local/Caskroom",
			Name:        "Homebrew Caskroom",
			Category:    CategoryInfrastructure,
			Description: "Installed Homebrew cask app versions",
		},
		{
			Path:        "/opt/homebrew/Cellar",
			Name:        "Homebrew Cellar (ARM)",
			Category:    CategoryInfrastructure,
			Description: "Installed Homebrew formula versions (Apple Silicon)",
		},
		{
			Path:        "/opt/homebrew/Caskroom",
			Name:        "Homebrew Caskroom (ARM)",
			Category:    CategoryInfrastructure,
			Description: "Installed Homebrew cask versions (Apple Silicon)",
		},
		{
			Path:        filepath.Join(home, "Library/Application Support/Google/Chrome"),
			Name:        "Chrome Profile Data",
			Category:    CategorySystem,
			Description: "Chrome profiles, extensions, local storage",
		},
		{
			Path:        filepath.Join(home, "Library/Application Support/Firefox"),
			Name:        "Firefox Profile Data",
			Category:    CategorySystem,
			Description: "Firefox profiles, extensions, local storage",
		},
		{
			Path:        "/private/var/db/timezone",
			Name:        "Timezone Data",
			Category:    CategorySystem,
			Description: "Timezone ICU data",
			NeedsSudo:   true,
		},
		{
			Path:        "/Library/Developer/CommandLineTools",
			Name:        "Xcode CLI Tools",
			Category:    CategoryXcode,
			Description: "Command Line Tools for Xcode (~1-2GB)",
			NeedsSudo:   true,
		},
		{
			Path:        "/Library/Developer/CoreSimulator",
			Name:        "Simulator Runtimes",
			Category:    CategoryXcode,
			Description: "Downloaded iOS/watchOS/tvOS simulator runtimes (5-10GB each)",
			NeedsSudo:   true,
		},
	}

	return paths
}

func PatternNames() map[string]Pattern {
	m := make(map[string]Pattern)
	for _, p := range DefaultPatterns() {
		m[p.Name] = p
	}
	return m
}
