#!/usr/bin/env bash
# Compiles the pure logic files together with Tests/main.swift and runs them.
# Needs Xcode 26 or later (the sources use `nonisolated` on types).
set -euo pipefail
cd "$(dirname "$0")/.."

out="$(mktemp -d)/tests"
swiftc -o "$out" \
  Awayke/Modules/Sleep/AutoOffPolicy.swift \
  Awayke/Modules/Sleep/LidSessionTracker.swift \
  Awayke/Modules/Sensors/SMCTypes.swift \
  Awayke/Modules/Sensors/SensorCatalog.swift \
  Tests/main.swift
"$out"
