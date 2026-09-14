#!/usr/bin/env bash
#
# 组装 VrPico.app。
#
# 本机只装了 CommandLineTools、没有完整 Xcode，所以不能用 xcodebuild，
# 这里手工拼 .app bundle，再用 ad-hoc 签名。
#
# 用法:
#   scripts/build_app.sh            # 构建 .app
#   scripts/build_app.sh --run      # 构建并启动
#   scripts/build_app.sh --zip      # 构建并打包成可分发的 zip
#
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="VrPico"
CONFIG="${CONFIG:-release}"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
ADB_VERSION="37.0.1"
ADB_SOURCE="$ROOT/Vendor/android-platform-tools/$ADB_VERSION/adb"
ADB_SHA256="1811e253b21b12cbfda7201ebaf86c10e7ddcb5c606a7a81f7c82b4c429c2d3b"

DO_RUN=0
DO_ZIP=0
for arg in "$@"; do
    case "$arg" in
        --run) DO_RUN=1 ;;
        --zip) DO_ZIP=1 ;;
        *) echo "未知参数: $arg" >&2; exit 2 ;;
    esac
done

cd "$ROOT"

if [[ ! -f "$ROOT/Resources/Info.plist" ]]; then
    echo "缺少 Resources/Info.plist" >&2
    exit 1
fi

if [[ ! -x "$ADB_SOURCE" ]]; then
    echo "缺少内置 ADB: $ADB_SOURCE" >&2
    exit 1
fi

ACTUAL_ADB_SHA256="$(shasum -a 256 "$ADB_SOURCE" | awk '{print $1}')"
if [[ "$ACTUAL_ADB_SHA256" != "$ADB_SHA256" ]]; then
    echo "内置 ADB 校验失败，期望 $ADB_SHA256，实际 $ACTUAL_ADB_SHA256" >&2
    exit 1
fi

codesign --verify --strict --verbose=2 "$ADB_SOURCE"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --product "$APP_NAME"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"

if [[ ! -x "$BIN" ]]; then
    echo "找不到可执行文件: $BIN" >&2
    exit 1
fi

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp -X "$ADB_SOURCE" "$APP/Contents/Helpers/adb"
chmod 755 "$APP/Contents/Helpers/adb"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> ad-hoc 签名"
# ADB 已由 Google 签名。保留内层签名，最后签外层 App。
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> 完成: $APP"

if (( DO_ZIP )); then
    ZIP="$BUILD_DIR/$APP_NAME.zip"
    rm -f "$ZIP"
    # ditto 保留资源分叉和权限，比 zip 更适合分发 .app。
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
    echo "==> 分发包: $ZIP"
    echo "    同事首次打开需要: xattr -d com.apple.quarantine $APP_NAME.app"
fi

if (( DO_RUN )); then
    echo "==> 启动（日志直接打到当前终端）"
    exec "$APP/Contents/MacOS/$APP_NAME"
fi
