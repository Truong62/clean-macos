use rayon::prelude::*;
use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::Instant;

const BLOCK_BYTES: u64 = 512;
const PACKAGE_EXTENSIONS: &[&str] = &[
    "app", "appex", "bundle", "framework", "plugin", "kext", "xpc", "photoslibrary", "photolibrary", "musiclibrary",
    "tvlibrary", "imovielibrary", "fcpbundle", "logicx", "band", "sparsebundle", "rtfd", "pages", "numbers", "key",
    "xcarchive", "playground", "scptd", "mpkg", "prefPane", "saver", "qlgenerator", "mdimporter", "wdgt",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DirSize {
    pub bytes: u64,
    pub timed_out: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LargeFile {
    pub path: String,
    pub bytes: u64,
    pub modified: i64,
}

#[derive(Clone)]
pub struct LargeFileQuery {
    pub min_bytes: u64,
    pub older_than: Option<i64>,
    pub limit: usize,
    pub deadline: Instant,
    pub excluded_dirs: Vec<PathBuf>,
    pub excluded_names: Vec<String>,
}

pub fn allocated_bytes(meta: &fs::Metadata) -> u64 {
    meta.blocks() * BLOCK_BYTES
}

pub fn dir_size(root: &Path, deadline: Instant, max_depth: usize) -> DirSize {
    let timed_out = AtomicBool::new(false);
    let bytes = match fs::symlink_metadata(root) {
        Ok(meta) if meta.is_dir() => size_of_children(root, 0, max_depth, deadline, &timed_out),
        Ok(meta) if meta.is_file() => allocated_bytes(&meta),
        _ => 0,
    };
    DirSize { bytes, timed_out: timed_out.load(Ordering::Relaxed) }
}

fn size_of_children(dir: &Path, depth: usize, max_depth: usize, deadline: Instant, timed_out: &AtomicBool) -> u64 {
    if depth + 1 > max_depth || timed_out.load(Ordering::Relaxed) {
        return 0;
    }
    if Instant::now() >= deadline {
        timed_out.store(true, Ordering::Relaxed);
        return 0;
    }
    let Ok(entries) = fs::read_dir(dir) else { return 0 };
    let mut files = 0;
    let mut folders = Vec::new();
    for entry in entries.flatten() {
        let Ok(meta) = entry.metadata() else { continue };
        let kind = meta.file_type();
        if kind.is_dir() {
            folders.push(entry.path());
        } else if kind.is_file() {
            files += allocated_bytes(&meta);
        }
    }
    files + folders.par_iter().map(|folder| size_of_children(folder, depth + 1, max_depth, deadline, timed_out)).sum::<u64>()
}

pub fn large_files(root: &Path, query: &LargeFileQuery) -> Vec<LargeFile> {
    let found = Mutex::new(Vec::new());
    collect_large(root, query, &found);
    let mut files = found.into_inner().unwrap_or_default();
    files.sort_by(|a: &LargeFile, b: &LargeFile| b.bytes.cmp(&a.bytes).then_with(|| a.path.cmp(&b.path)));
    files.truncate(query.limit);
    files
}

fn is_package(path: &Path) -> bool {
    path.extension()
        .and_then(|ext| ext.to_str())
        .is_some_and(|ext| PACKAGE_EXTENSIONS.iter().any(|known| known.eq_ignore_ascii_case(ext)))
}

fn collect_large(dir: &Path, query: &LargeFileQuery, found: &Mutex<Vec<LargeFile>>) {
    if Instant::now() >= query.deadline {
        return;
    }
    let Ok(entries) = fs::read_dir(dir) else { return };
    let mut folders = Vec::new();
    for entry in entries.flatten() {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if name.starts_with('.') {
            continue;
        }
        let Ok(meta) = entry.metadata() else { continue };
        let kind = meta.file_type();
        let path = entry.path();
        if kind.is_dir() {
            let excluded = query.excluded_names.iter().any(|excluded| excluded == name.as_ref())
                || query.excluded_dirs.iter().any(|excluded| excluded == &path);
            if !excluded && !is_package(&path) {
                folders.push(path);
            }
        } else if kind.is_file() {
            let bytes = allocated_bytes(&meta);
            let modified = meta.mtime();
            if bytes >= query.min_bytes && query.older_than.map_or(true, |cutoff| modified <= cutoff) {
                if let Ok(mut list) = found.lock() {
                    list.push(LargeFile { path: path.to_string_lossy().into_owned(), bytes, modified });
                }
            }
        }
    }
    folders.par_iter().for_each(|folder| collect_large(folder, query, found));
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("mackit-fswalk-{}-{}", name, std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn later() -> Instant {
        Instant::now() + Duration::from_secs(30)
    }

    #[test]
    fn sums_allocated_bytes_of_nested_files_and_skips_symlinks() {
        let root = scratch("size");
        fs::create_dir_all(root.join("a/b/c")).unwrap();
        fs::write(root.join("one.bin"), vec![1u8; 100_000]).unwrap();
        fs::write(root.join("a/b/c/two.bin"), vec![2u8; 300_000]).unwrap();
        std::os::unix::fs::symlink(root.join("one.bin"), root.join("a/link")).unwrap();
        let expected: u64 = ["one.bin", "a/b/c/two.bin"]
            .iter()
            .map(|file| allocated_bytes(&fs::metadata(root.join(file)).unwrap()))
            .sum();
        let size = dir_size(&root, later(), 50);
        assert_eq!(size, DirSize { bytes: expected, timed_out: false });
        assert!(size.bytes >= 400_000);
        assert_eq!(dir_size(&root.join("one.bin"), later(), 50).bytes, allocated_bytes(&fs::metadata(root.join("one.bin")).unwrap()));
        assert_eq!(dir_size(&root.join("missing"), later(), 50).bytes, 0);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn stops_at_the_depth_limit_and_reports_a_timeout() {
        let root = scratch("depth");
        fs::create_dir_all(root.join("a/b")).unwrap();
        fs::write(root.join("top.bin"), vec![0u8; 50_000]).unwrap();
        fs::write(root.join("a/b/deep.bin"), vec![0u8; 50_000]).unwrap();
        let top = allocated_bytes(&fs::metadata(root.join("top.bin")).unwrap());
        assert_eq!(dir_size(&root, later(), 1).bytes, top);
        assert!(dir_size(&root, Instant::now(), 50).timed_out);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn finds_the_largest_files_and_skips_hidden_excluded_and_package_folders() {
        let root = scratch("large");
        for dir in ["docs", "node_modules", ".hidden", "Big.app/Contents", "Library"] {
            fs::create_dir_all(root.join(dir)).unwrap();
        }
        fs::write(root.join("docs/movie.mov"), vec![0u8; 900_000]).unwrap();
        fs::write(root.join("docs/small.txt"), vec![0u8; 1_000]).unwrap();
        fs::write(root.join("disk.img"), vec![0u8; 600_000]).unwrap();
        fs::write(root.join("node_modules/dep.bin"), vec![0u8; 900_000]).unwrap();
        fs::write(root.join(".hidden/secret.bin"), vec![0u8; 900_000]).unwrap();
        fs::write(root.join("Big.app/Contents/binary"), vec![0u8; 900_000]).unwrap();
        fs::write(root.join("Library/cache.bin"), vec![0u8; 900_000]).unwrap();
        let query = LargeFileQuery {
            min_bytes: 500_000,
            older_than: None,
            limit: 10,
            deadline: later(),
            excluded_dirs: vec![root.join("Library")],
            excluded_names: vec!["node_modules".into()],
        };
        let found = large_files(&root, &query);
        let names: Vec<_> = found.iter().map(|file| Path::new(&file.path).file_name().unwrap().to_string_lossy().into_owned()).collect();
        assert_eq!(names, ["movie.mov", "disk.img"]);
        assert_eq!(large_files(&root, &LargeFileQuery { limit: 1, ..query.clone() }).len(), 1);
        assert!(large_files(&root, &LargeFileQuery { older_than: Some(0), ..query }).is_empty());
        fs::remove_dir_all(root).unwrap();
    }
}
