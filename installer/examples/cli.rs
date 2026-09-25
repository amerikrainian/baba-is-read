// The installer CLI without the bin's requireAdministrator manifest, for driving
// end-to-end tests on a dev box whose game dir is user-writable:
//   cargo run --release --example cli
// (build.rs embeds the elevation manifest only into the baba-is-read-installer
// bin, so this target launches without a UAC prompt.)

fn main() {
    baba_is_read_installer::cli::run();
}
