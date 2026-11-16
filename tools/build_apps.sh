#!/usr/bin/env bash
set -euo pipefail
workbench_root=$(cd "$(dirname "$0")/.." && pwd)
workbench_host=$(rustc -vV | sed -n 's/^host: //p')
if ! command -v llvm-objcopy >/dev/null; then
    export LLVM_OBJCOPY="$(rustc --print sysroot)/lib/rustlib/$workbench_host/bin/llvm-objcopy"
else
    export LLVM_OBJCOPY=llvm-objcopy
fi
cd "$workbench_root/firmware/wp2-apps"
for app in trail-map stopwatch intervals counter; do scripts/build-app "$app" 10; done
# Normalize diagnostic paths embedded by dependencies in the loader image.
workbench_flags=$(printf '%s\037' -C link-arg=-Tlink.ld -C link-arg=--emit-relocs -C target-feature=+no-movt "--remap-path-prefix=$workbench_root=workbench" "--remap-path-prefix=$HOME=home")
workbench_flags=${workbench_flags%$'\037'}
(cd fw && CARGO_ENCODED_RUSTFLAGS="$workbench_flags" cargo build --release -p wp2-loader)
"$LLVM_OBJCOPY" -O binary --set-section-flags .data=alloc,load,contents \
  fw/target/thumbv7em-none-eabi/release/wp2-loader target/loader.bin
python3 - <<'PY'
from pathlib import Path
Path('target/loader.wp2app').unlink(missing_ok=True)
PY
uv run --locked wp2apps pack target/loader.bin \
  --elf fw/target/thumbv7em-none-eabi/release/wp2-loader \
  --kind loader --name loader --version 4 --output target/loader.wp2app
echo 'Built packages. Run runtime verification before staging them into a companion.'
