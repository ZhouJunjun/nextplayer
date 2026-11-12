#!/usr/bin/env bash
#
# nextplayer 编译打包 —— 目标系统 Rocky Linux 9.3 (Blue Onyx)
#
# 用业务用户（默认 itdev）执行。前置条件是先由 root 跑过一次 init_env.sh。
#
# 用法：
#   sh pack.sh
#   bash pack.sh
#   PREFIX=/opt/tools sh pack.sh     # init_env.sh 装到了自定义前缀时
#   BUILD_USER=other sh pack.sh      # 业务用户名不是 itdev 时
#
# 做什么：
#   1. 检查 JDK / Gradle / Android SDK 是否已在 $PREFIX 就位，缺了就提示去跑 init_env.sh
#   2. 写 local.properties 指向 SDK
#   3. 编译 release APK，用项目根目录的 nextplayer.jks 签名，产物落在项目根
#
# 缓存去哪了：
#   Gradle 依赖、transforms、构建缓存、临时文件全部收在项目内的 .build-cache/ 下，
#   不写 ~/.gradle，换用户也不会各自下一份。
#
# 本脚本不安装任何东西，也不需要 root。用 root 跑会直接退出。
#
set -euo pipefail

# 用 sh 调起时（Rocky 的 /bin/sh 会进 POSIX 模式）切回 bash，保证数组等语法可用
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

# ============================================================ 可调参数

PREFIX="${PREFIX:-/usr/local}"
# 允许运行本脚本的业务用户。不是这个用户就直接退出。
BUILD_USER="${BUILD_USER:-itdev}"

# 必须与 init_env.sh 保持一致
JDK_DIR_NAME="jdk-17.0.21"
GRADLE_VER="9.9.0"
PLATFORM_ID="android-37.0"      # compileSdk = 37
BUILD_TOOLS_VER="37.0.0"

# 签名
KS_PASS="000777"
KS_ALIAS="nextplayer"

# ============================================================ 路径

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JDK_HOME="$PREFIX/$JDK_DIR_NAME"
GRADLE_HOME="$PREFIX/gradle-$GRADLE_VER"
SDK_HOME="$PREFIX/android-sdk"
KEYSTORE="$PROJECT_DIR/$KS_ALIAS.jks"

APK_DIR="$PROJECT_DIR/app/build/outputs/apk/release"
UNSIGNED_APK="$APK_DIR/app-arm64-v8a-release-unsigned.apk"

# 所有构建缓存都收进项目目录，不污染 ~/.gradle，也不受运行用户影响。
# Kotlin 编译守护进程的数据也在 GRADLE_USER_HOME 下，跟着一起走。
CACHE_ROOT="$PROJECT_DIR/.build-cache"
GRADLE_USER_HOME_DIR="$CACHE_ROOT/gradle"      # 依赖、transforms、构建缓存、Kotlin 数据
GRADLE_TMP_DIR="$CACHE_ROOT/tmp"               # Gradle 与子进程的临时文件

# ============================================================ 输出

if [ -t 1 ]; then
    C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'
    C_B=$'\033[36m'; C_BOLD=$'\033[1m'; C_0=$'\033[0m'
else
    C_R=''; C_G=''; C_Y=''; C_B=''; C_BOLD=''; C_0=''
fi

step() { printf '\n%s==> %s%s\n' "$C_B$C_BOLD" "$*" "$C_0"; }
ok()   { printf '  %s[ ok ]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '  %s[warn]%s %s\n' "$C_Y" "$C_0" "$*"; }
die()  { printf '\n%s[FAIL]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
say()  { printf '  %s\n' "$*"; }

# ============================================================ 身份闸门

# 最前面就卡身份，不允许 root 或别的用户往下走。
# root 构建会把 build/、.build-cache/ 写成 root 所有，之后 itdev 再也构建不了。
require_build_user() {
    local me; me="$(id -un)"

    if [ "$me" = "root" ]; then
        printf '\n%s[FAIL]%s 不能用 root 运行 pack.sh\n' "$C_R" "$C_0" >&2
        printf '  root 构建会让产物归 root 所有，之后 %s 就无法再构建。\n' "$BUILD_USER" >&2
        printf '\n  正确做法：\n' >&2
        printf '    su - %s\n' "$BUILD_USER" >&2
        printf '    cd %s && sh pack.sh\n' "$PROJECT_DIR" >&2
        printf '\n  或者一步到位：\n' >&2
        printf '    runuser -u %s -- sh %s/pack.sh\n\n' "$BUILD_USER" "$PROJECT_DIR" >&2
        exit 1
    fi

    if [ "$me" != "$BUILD_USER" ]; then
        printf '\n%s[FAIL]%s 本脚本必须由 %s 运行，当前用户是 %s\n' \
            "$C_R" "$C_0" "$BUILD_USER" "$me" >&2
        printf '\n  请切换用户后重试：\n' >&2
        printf '    su - %s\n' "$BUILD_USER" >&2
        printf '    cd %s && sh pack.sh\n\n' "$PROJECT_DIR" >&2
        exit 1
    fi

    ok "当前用户：$me"
}

# ============================================================ 前置检查

check_host() {
    step "检查系统"
    if [ -f /etc/redhat-release ]; then
        say "系统：$(cat /etc/redhat-release)"
    fi
    local arch; arch="$(uname -m)"
    say "架构：$arch"
    [ "$arch" = "x86_64" ] || die "只准备了 x86_64 工具链，当前是 $arch"

    command -v unzip >/dev/null 2>&1 ||
        die "缺少命令 unzip，请联系管理员：dnf install -y unzip"
}

# 工具链由 init_env.sh 装好，这里只检查、不安装
check_toolchain() {
    step "检查工具链"

    local missing=0
    if [ -x "$JDK_HOME/bin/javac" ]; then
        ok "JDK      $JDK_HOME"
    else
        warn "缺 JDK：$JDK_HOME"; missing=1
    fi

    if [ -x "$GRADLE_HOME/bin/gradle" ]; then
        ok "Gradle   $GRADLE_HOME"
    else
        warn "缺 Gradle：$GRADLE_HOME"; missing=1
    fi

    if [ -f "$SDK_HOME/platforms/$PLATFORM_ID/android.jar" ]; then
        ok "platform $PLATFORM_ID"
    else
        warn "缺 platform：$SDK_HOME/platforms/$PLATFORM_ID"; missing=1
    fi

    if [ -x "$SDK_HOME/build-tools/$BUILD_TOOLS_VER/apksigner" ]; then
        ok "build-tools $BUILD_TOOLS_VER"
    else
        warn "缺 build-tools：$SDK_HOME/build-tools/$BUILD_TOOLS_VER"; missing=1
    fi

    if [ "$missing" = 1 ]; then
        die "工具链不完整，请先用 root 运行 init_env.sh：
  sudo bash $PROJECT_DIR/init_env.sh"
    fi
}

# 项目目录得能写，缓存和产物都放这里
check_project_writable() {
    step "检查项目目录"
    [ -f "$PROJECT_DIR/settings.gradle.kts" ] ||
        die "$PROJECT_DIR 不是项目根目录（没有 settings.gradle.kts）"

    if [ ! -w "$PROJECT_DIR" ]; then
        die "项目目录不可写：$PROJECT_DIR
  当前用户：$(id -un)  目录所有者：$(stat -c %U "$PROJECT_DIR" 2>/dev/null)
  请让 root 修一下归属：
    chown -R $(id -un): '$PROJECT_DIR'"
    fi
    ok "可写：$PROJECT_DIR"
}

# ============================================================ 项目准备

prepare_project() {
    step "准备项目配置"

    # 显式告诉 AGP SDK 位置。local.properties 被 .gitignore 忽略，写它最安全
    local props="$PROJECT_DIR/local.properties"
    local want="sdk.dir=$SDK_HOME"
    if [ -f "$props" ]; then
        if grep -q '^sdk\.dir=' "$props"; then
            if grep -qxF "$want" "$props"; then
                ok "local.properties 已指向 $SDK_HOME"
            else
                sed -i "s|^sdk\.dir=.*|$want|" "$props"
                ok "已更新 local.properties 的 sdk.dir"
            fi
        else
            printf '\n%s\n' "$want" >> "$props"
            ok "已向 local.properties 追加 sdk.dir"
        fi
    else
        printf '%s\n' "$want" > "$props"
        ok "已创建 local.properties"
    fi

    [ -f "$KEYSTORE" ] ||
        die "找不到签名库 $KEYSTORE
  请把 $KS_ALIAS.jks 放到项目根目录：$PROJECT_DIR/"
    ok "签名库：$KEYSTORE"
}

# ============================================================ 构建

build_apk() {
    step "编译 release"

    export JAVA_HOME="$JDK_HOME"
    export ANDROID_HOME="$SDK_HOME"
    export ANDROID_SDK_ROOT="$SDK_HOME"

    # 依赖与各类缓存全部落在项目目录
    mkdir -p "$GRADLE_USER_HOME_DIR" "$GRADLE_TMP_DIR"
    export GRADLE_USER_HOME="$GRADLE_USER_HOME_DIR"
    export TMPDIR="$GRADLE_TMP_DIR"

    say "JAVA_HOME        = $JAVA_HOME"
    say "ANDROID_HOME     = $ANDROID_HOME"
    say "GRADLE_USER_HOME = $GRADLE_USER_HOME"
    say "TMPDIR           = $TMPDIR"
    say "gradle           = $GRADLE_HOME/bin/gradle"
    say ""

    cd "$PROJECT_DIR"
    "$GRADLE_HOME/bin/gradle" assembleRelease --console=plain --no-daemon

    [ -f "$UNSIGNED_APK" ] || die "构建结束但没找到产物：$UNSIGNED_APK"
    ok "产物：$(basename "$UNSIGNED_APK")"
}

# ============================================================ 签名

sign_apk() {
    step "签名"

    local bt="$SDK_HOME/build-tools/$BUILD_TOOLS_VER"
    local apksigner="$bt/apksigner"
    local aapt2="$bt/aapt2"
    [ -x "$apksigner" ] || die "找不到 apksigner：$apksigner"

    # 版本号从构建脚本里读，不写死在脚本里
    local version="unknown"
    local v
    v="$(sed -n 's/.*versionName *= *"\([^"]*\)".*/\1/p' \
        "$PROJECT_DIR/app/build.gradle.kts" 2>/dev/null | head -1)"
    [ -n "$v" ] && version="$v"

    local stamp out
    stamp="$(date +%y%m%d_%H%M%S)"
    out="$PROJECT_DIR/nextplayer_${stamp}_appRelease_${version}_arm64.apk"

    export JAVA_HOME="$JDK_HOME"

    "$apksigner" sign \
        --ks "$KEYSTORE" \
        --ks-key-alias "$KS_ALIAS" \
        --ks-pass "pass:$KS_PASS" \
        --key-pass "pass:$KS_PASS" \
        --v1-signing-enabled true \
        --v2-signing-enabled true \
        --v3-signing-enabled true \
        --out "$out" \
        "$UNSIGNED_APK"

    # apksigner 会顺带写 .idsig，不留
    rm -f "$out.idsig"

    say "校验签名"
    "$apksigner" verify --print-certs "$out" | head -3

    if [ -x "$aapt2" ]; then
        say "APK 信息"
        "$aapt2" dump badging "$out" 2>/dev/null |
            grep -E '^package:|^native-code' || true
    fi

    printf '\n%s产物：%s%s\n\n' "$C_BOLD" "$out" "$C_0"
}

# ============================================================ main

main() {
    printf '\n%snextplayer 编译打包%s\n' "$C_BOLD" "$C_0"
    printf '项目目录：%s\n' "$PROJECT_DIR"
    printf '安装前缀：%s\n' "$PREFIX"

    # 身份闸门放最前面，不合格立刻退出
    step "检查运行身份"
    require_build_user

    check_host
    check_toolchain
    check_project_writable
    prepare_project
    build_apk
    sign_apk

    printf '%s完成%s\n\n' "$C_G$C_BOLD" "$C_0"
}

main "$@"
