#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
mkdir -p build/artwork-check
swift test --package-path ios/CompanionCore --build-system native --scratch-path build/artwork-check/swift
swift_bin=$(swift build --package-path ios/CompanionCore --build-system native --scratch-path build/artwork-check/swift --show-bin-path)
swiftc -O -I "$swift_bin/Modules" "$swift_bin"/CompanionCore.build/*.swift.o "$swift_bin"/WireKit.build/*.swift.o -lz ios/TrailCompanion/Sources/OfflineMap.swift ios/TrailCompanion/Sources/OfflineRouting.swift ios/TrailCompanion/Sources/MapArtwork.swift tests/ios-artwork/main.swift -o build/artwork-check/probe
build/artwork-check/probe
uv run --python 3.13 --with pillow python tools/check_watch_artwork.py
