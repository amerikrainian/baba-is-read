// Adapted from the Non-Visual Calculus installer by Rashad Naqeeb (MIT),
// https://github.com/rashadnaqeeb/NonVisualCalculus

use std::path::{Path, PathBuf};

// The full release list, newest first: one call serves both the latest-version
// lookup and the per-version release notes shown after an update.
pub const GITHUB_RELEASES_URL: &str =
    "https://api.github.com/repos/amerikrainian/baba-access/releases?per_page=100";
pub const MOD_ZIP_PREFIX: &str = "BabaAccess-v";
pub const MOD_ZIP_SUFFIX: &str = ".zip";
pub const GAME_EXES: &[&str] = &["Baba Is You.exe"];
// Steam's install folder; a hand-moved copy is found through Browse.
pub const GAME_FOLDERS: &[&str] = &["Baba Is You"];
// The game ships its Lua in the clear; modsupport.lua is the engine's mod hook file, present in
// every install and the thing the mod hangs off, so together with the exe it identifies the game dir.
pub const GAME_DATA_MARKER: &str = "Data/modsupport.lua";
// The engine runs every Data/Lua/*.lua at startup (not recursive): the bootstrap sits there, the
// modules under baba_access/. Data/Lua exists, empty, in a vanilla install, so uninstall never
// removes it (see MOD_ROOT_REL).
pub const MOD_ROOT_REL: &str = "Data/Lua";
pub const BOOTSTRAP_REL: &str = "Data/Lua/baba_access.lua";
pub const MOD_DIR_REL: &str = "Data/Lua/baba_access";
pub const BRIDGE_REL: &str = "Data/Lua/baba_access/bin/babaaccess.dll";
pub const MANIFEST_REL: &str = "Data/Lua/baba_access/install.json";
pub const BACKUPS_REL: &str = "Data/Lua/baba_access/backups";

pub fn manifest_path(game_dir: &Path) -> PathBuf {
    game_dir.join(MANIFEST_REL)
}

/// The directory below which uninstall may remove emptied parents. Data/Lua is the game's own
/// (empty in a vanilla install) and must survive.
pub fn mod_root(game_dir: &Path) -> PathBuf {
    game_dir.join(MOD_ROOT_REL)
}

pub fn normalize_rel(path: &str) -> String {
    path.replace('\\', "/").trim_start_matches("./").to_string()
}

/// Files whose presence means the mod is (at least partly) installed.
pub fn required_mod_files() -> &'static [&'static str] {
    &[
        BOOTSTRAP_REL,
        "Data/Lua/baba_access/main.lua",
        BRIDGE_REL,
        "Data/Lua/baba_access/bin/prism.dll",
    ]
}
