#!/bin/bash
# 用 Release build 的 PulseFloatShots 產生 3D 主題的設計探索截圖與效能數據。
# 用法：scripts/shots.sh <輸出資料夾> [PulseFloatShots 的其他參數，例如 --themes blackhole --styles --perf]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:?usage: scripts/shots.sh <outDir> [args...]}"
shift
xcodegen generate --quiet
xcodebuild build -scheme PulseFloatShots -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData -quiet ONLY_ACTIVE_ARCH=YES
build/DerivedData/Build/Products/Release/PulseFloatShots "$OUT" "$@"
