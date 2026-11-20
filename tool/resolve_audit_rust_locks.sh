#!/usr/bin/env bash
set -euo pipefail
# Resolve only the dependency families implicated by the audit. The committed
# Cargo.lock files remain the inputs to every normal build (--locked).
cd "$(dirname "$0")/.."
cargo update --manifest-path services/helper/Cargo.toml --package warp --precise 0.4.4
cargo update --manifest-path services/helper/Cargo.toml --package h2 --precise 0.4.16
cargo update --manifest-path services/helper/Cargo.toml --package tokio --precise 1.53.3
cargo update --manifest-path plugins/rust_api/rust/Cargo.toml --package tokio --precise 1.53.3
cargo update --manifest-path plugins/rust_api/rust/Cargo.toml --package rustix --precise 1.1.6
