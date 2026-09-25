// Adapted from the Non-Visual Calculus installer by Rashad Naqeeb (MIT),
// https://github.com/rashadnaqeeb/NonVisualCalculus

use std::fs;
use std::path::Path;

use super::install::ensure_writable;
use super::manifest::InstallManifest;
use super::paths;

pub fn uninstall(game_dir: &Path, manifest: &InstallManifest) -> Result<(), String> {
    for rel in manifest.installed_files.iter().rev() {
        let path = game_dir.join(rel);
        if path.exists() {
            ensure_writable(&path)?;
            fs::remove_file(&path)
                .map_err(|e| format!("Failed to remove {}: {e}", path.display()))?;
        }
        remove_empty_parents(game_dir, path.parent());
    }

    for (target_rel, backup_rel) in &manifest.backups {
        let backup = game_dir.join(backup_rel);
        if !backup.exists() {
            continue;
        }
        let target = game_dir.join(target_rel);
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)
                .map_err(|e| format!("Failed to create restore parent: {e}"))?;
        }
        fs::copy(&backup, &target)
            .map_err(|e| format!("Failed to restore {}: {e}", target.display()))?;
        ensure_writable(&backup)?;
        fs::remove_file(&backup)
            .map_err(|e| format!("Failed to remove backup {}: {e}", backup.display()))?;
        remove_empty_parents(game_dir, backup.parent());
    }

    let manifest_path = paths::manifest_path(game_dir);
    if manifest_path.exists() {
        ensure_writable(&manifest_path)?;
        fs::remove_file(&manifest_path)
            .map_err(|e| format!("Failed to remove manifest: {e}"))?;
    }
    remove_empty_parents(game_dir, manifest_path.parent());

    // A zip may carry directory entries with no files in them. The manifest records files only,
    // so the walks above never visit such a dir; sweep the mod's own tree for leftover empty
    // dirs. Data/Lua itself is the game's and stays.
    remove_empty_dirs(&game_dir.join(paths::MOD_DIR_REL));
    Ok(())
}

/// Remove `root` and everything below it that is an empty directory, deepest first. A dir
/// holding any file survives, so this can never delete data.
fn remove_empty_dirs(root: &Path) {
    if !root.is_dir() {
        return;
    }
    if let Ok(entries) = fs::read_dir(root) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                remove_empty_dirs(&path);
            }
        }
    }
    let _ = fs::remove_dir(root);
}

/// Remove `current` and its parents while they are empty, stopping at the game dir and at
/// Data/Lua, which a vanilla install has (empty) and the engine expects.
pub(crate) fn remove_empty_parents(game_dir: &Path, mut current: Option<&Path>) {
    let mod_root = paths::mod_root(game_dir);
    while let Some(dir) = current {
        if dir == game_dir || dir == mod_root {
            break;
        }
        match fs::remove_dir(dir) {
            Ok(_) => current = dir.parent(),
            Err(_) => break,
        }
    }
}
