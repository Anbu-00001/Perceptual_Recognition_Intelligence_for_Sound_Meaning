// Build script for flutter_rust_bridge v2.
// Forces a rebuild when API source changes, so the generated bindings stay in sync
// with Rust-side signatures.
fn main() {
    println!("cargo:rerun-if-changed=src/api");
    println!("cargo:rerun-if-changed=src/ffi");
    println!("cargo:rerun-if-changed=src/ring.rs");
    println!("cargo:rerun-if-changed=src/lib.rs");
}
