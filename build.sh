#!/bin/bash
#
# Max2Ps2 构建脚本
#
# 用法：
#   ./build.sh            # Release 构建，产物复制到 Dist/Max2Ps2.app
#   ./build.sh debug      # Debug 构建，产物留在 .build/dd
#   ./build.sh run        # Release 构建后直接启动
#
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="Release"
RUN=0
case "${1:-}" in
    debug) CONFIG="Debug" ;;
    run)   RUN=1 ;;
    "")    ;;
    *)     echo "未知参数：${1}（可用：debug / run）"; exit 2 ;;
esac

# 沙箱环境里 module cache 默认位置不可写，统一放到工程内
export TMPDIR="$PWD/.build/tmp"
mkdir -p "$TMPDIR" .build/modulecache Dist

echo "==> 构建 Max2Ps2（${CONFIG}）"
xcodebuild \
    -project Max2Ps2.xcodeproj \
    -scheme Max2Ps2 \
    -configuration "$CONFIG" \
    -derivedDataPath .build/dd \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    build

APP=".build/dd/Build/Products/$CONFIG/Max2Ps2.app"
test -d "$APP" || { echo "构建产物不存在：$APP"; exit 1; }

rm -rf "Dist/Max2Ps2.app"
cp -R "$APP" "Dist/Max2Ps2.app"
xattr -cr "Dist/Max2Ps2.app"
codesign --force --deep --sign - "Dist/Max2Ps2.app" >/dev/null

# 附一份 zip，方便拷给别人
rm -f "Dist/Max2Ps2.zip"
ditto -c -k --keepParent "Dist/Max2Ps2.app" "Dist/Max2Ps2.zip"

echo "==> 完成：Dist/Max2Ps2.app（以及 Dist/Max2Ps2.zip）"
if [ "$RUN" = "1" ]; then
    open "Dist/Max2Ps2.app"
fi
