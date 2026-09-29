//! The engine's C ABI, made reachable from this crate.
//!
//! Every entry point lives in `quieditor_ffi`, in the engine's repository,
//! beside the engine it wraps and compiled for wasm from that same source.
//! Nothing is reimplemented here and nothing should be.
//!
//! The re-export below is the whole of this file, and it is load-bearing rather
//! than tidy. A crate that only *depends* on another one is a crate the linker
//! is free to find nothing in: `#[no_mangle]` functions are for callers outside
//! Rust, so nothing inside this crate names them, and a symbol nothing refers to
//! is a symbol that can be dropped. Naming them here is what gives the linker a
//! reason to keep them, and the symbols that come out are the ones Dart
//! resolves by name.
//!
//! Everything this crate exports is therefore `unsafe` or documented as safe by
//! the crate it came from. The safety notes travel with `pub use`, which is why
//! there is nothing to repeat here.

pub use quieditor_ffi::*;
