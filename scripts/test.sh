#!/usr/bin/env bash
#
# 跑单元测试。
#
# 为什么要包一层：本机 xcode-select 可能仍指向 CommandLineTools（切换需要
# sudo），那种情况下 swift test 会报 "no such module 'XCTest'"。
# 用 DEVELOPER_DIR 临时指向 Xcode 即可，不必改系统设置。
#
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

XCODE_DEVELOPER="/Applications/Xcode.app/Contents/Developer"

if ! xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
    if [[ -d "$XCODE_DEVELOPER" ]]; then
        echo "[test] xcode-select 指向 CommandLineTools，临时改用 $XCODE_DEVELOPER"
        export DEVELOPER_DIR="$XCODE_DEVELOPER"
    else
        echo "找不到 Xcode，且 xcode-select 未指向 Xcode。" >&2
        echo "安装 Xcode 后执行：sudo xcode-select -s $XCODE_DEVELOPER" >&2
        exit 1
    fi
fi

exec swift test "$@"
