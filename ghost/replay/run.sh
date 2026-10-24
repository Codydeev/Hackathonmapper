#!/bin/sh
# Replays ghost/fixtures/*.json through Ghost Mode and writes ghost/results/replay-table.md.
# Offline, no data downloads; exits non-zero if any scenario check fails.
set -e
cd "$(dirname "$0")/../.."
mkdir -p ghost/replay/.build
find ios/MeshCore/Sources/MeshCore -name '*.swift' > ghost/replay/.build/sources.txt
echo ghost/replay/main.swift >> ghost/replay/.build/sources.txt
xargs swiftc -O -o ghost/replay/.build/replay < ghost/replay/.build/sources.txt
ghost/replay/.build/replay ghost/fixtures ghost/results
