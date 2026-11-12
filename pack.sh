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
#   CPU_LIMIT=2 MEM_LIMIT_MB=2048 sh pack.sh   # 临时再压低编译用的资源
#
# 资源上限（默认）：
#   内存 4G —— 拆成 Gradle 堆 2G + 元空间 0.375G、Kotlin 守护进程 0.5G + 0.25G，
#              其余留给 JVM 开销；能拿到 systemd user manager 时再加 cgroup MemoryMax 硬限
#   CPU  4 核 —— 机器共 8 核，构建只绑 0-3，另外 4 核留给别的服务；同时 Gradle 并发数 = 4
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
BUILD_TOOLS_VER="37.0.0"        # 脚本签名用这个版本
# 构建需要的 build-tools：AGP 9.5.1 默认用 36.0.0（项目没声明 buildToolsVersion），
# 所以 36.0.0 必须存在，否则 Gradle 会去下载并因许可证失败
REQUIRED_BUILD_TOOLS=("37.0.0" "36.0.0")

# 签名
KS_PASS="000777"
KS_ALIAS="nextplayer"

# 编译期资源上限（运维要求：内存最多 4G；机器 8 核，构建只许用 4 核，其余留给别的服务）
# 分两层做：JVM 堆与元空间给死上限（软限），再尽量套一层 cgroup（硬限）。
MEM_LIMIT_MB="${MEM_LIMIT_MB:-4096}"
CPU_LIMIT="${CPU_LIMIT:-4}"

# 国内镜像：把 settings.gradle.kts 里的 google()/mavenCentral()/gradlePluginPortal()
# 前置成阿里云镜像，镜像里没有的构件仍回落到原仓库。MIRROR=off 可关掉。
MIRROR="${MIRROR:-on}"

# 4G 预算怎么分（cgroup 算的是实际 RSS，比堆大：还有元空间、代码缓存、线程栈、直接内存）：
# Gradle 主进程 2G 堆 + 0.375G 元空间，Kotlin 守护进程 0.5G + 0.25G，合计 3.125G，
# 留约 0.9G 给 JVM 自身开销。上一版合计 3.5G、余量太薄，R8 阶段被 cgroup OOM 杀掉过。
GRADLE_HEAP_MB=$((MEM_LIMIT_MB / 2))
GRADLE_META_MB=$((MEM_LIMIT_MB * 3 / 32))
KOTLIN_HEAP_MB=$((MEM_LIMIT_MB / 8))
KOTLIN_META_MB=$((MEM_LIMIT_MB / 16))

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

# 依赖仓库前置国内镜像的 init 脚本（不改 settings.gradle.kts）
MIRROR_INIT="$PROJECT_DIR/gradle/domestic-mirrors.init.gradle"

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
# 在 $PREFIX 下找可用的 JDK 17。不写死目录名：机器上可能装的是
# jdk-17.0.15、jdk-17.0.21+9 之类，只要 bin/javac 在、大版本是 17 就用它。
find_existing_jdk() {
    local d ver major

    # 候选顺序：约定的目录名优先（多个 JDK 17 并存时行为确定），
    # 之后才是其他 jdk-17* 目录。注意直接写 jdk-17.0.21 时 java 读不到，
    # 因为它没有 bin/，会被下面的检查挡掉，所以不用特判。
    local candidates=(
        "$PREFIX/$JDK_DIR_NAME"
        "$PREFIX"/jdk-17*
        "$PREFIX"/jdk17*
        "$PREFIX"/*/jdk-17*
    )

    for d in "${candidates[@]}"; do
        [ -d "$d" ] || continue
        # javac 和 java 都要在，缺一个就不是完整 JDK
        [ -x "$d/bin/javac" ] && [ -x "$d/bin/java" ] || continue

        # 按 java -version 的实际版本判断，不看目录名 —— 目录名可能和真实版本不一致
        ver="$("$d/bin/java" -version 2>&1 | head -1)"
        major="$(printf '%s\n' "$ver" | sed -n 's/.*version "\([0-9]*\)[."].*/\1/p')"
        [ "$major" = "17" ] || continue

        printf '%s' "$d"
        return 0
    done
    return 1
}

check_toolchain() {
    step "检查工具链"

    local missing=0

    # JDK：先在 $PREFIX 里扫一遍，命中哪个用哪个
    local found
    if found="$(find_existing_jdk)"; then
        JDK_HOME="$found"
        ok "JDK      $JDK_HOME"
        say "         $("$JDK_HOME/bin/java" -version 2>&1 | head -1)"
    else
        JDK_HOME="$PREFIX/$JDK_DIR_NAME"
        warn "缺 JDK 17：$PREFIX 下没找到可用的 jdk-17*"; missing=1
    fi

    if [ -x "$GRADLE_HOME/bin/gradle" ]; then
        ok "Gradle   $GRADLE_HOME"
    else
        warn "缺 Gradle：$GRADLE_HOME"; missing=1
    fi

    # 光有 android.jar 不够：缺 package.xml 时 Gradle 会认为组件没装，
    # 进而尝试写入只读的 SDK 目录，报 "The SDK directory is not writable"
    if [ -f "$SDK_HOME/platforms/$PLATFORM_ID/android.jar" ] &&
        [ -f "$SDK_HOME/platforms/$PLATFORM_ID/package.xml" ]; then
        ok "platform $PLATFORM_ID"
    else
        warn "platform $PLATFORM_ID 缺失或不完整（缺 android.jar 或 package.xml）"; missing=1
    fi

    local v
    for v in "${REQUIRED_BUILD_TOOLS[@]}"; do
        if [ -x "$SDK_HOME/build-tools/$v/apksigner" ] &&
            [ -f "$SDK_HOME/build-tools/$v/package.xml" ]; then
            ok "build-tools $v"
        else
            warn "build-tools $v 缺失或不完整（缺 apksigner 或 package.xml）"; missing=1
        fi
    done

    # 没有许可证文件，Gradle 会在装缺失组件时直接报 "licences have not been accepted"
    if [ -f "$SDK_HOME/licenses/android-sdk-license" ]; then
        ok "SDK 许可证"
    else
        warn "缺 SDK 许可证：$SDK_HOME/licenses/android-sdk-license"; missing=1
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

# 构建命令的前缀。能设 cgroup 就套一层硬上限，设不了就是空数组（软限兜底）。
LIMITER=()
TASKSET=()

# 把整个构建进程树罩进 scope 单元，MemoryMax / CPUQuota 由内核执行，
# 这样即使 Gradle 的堆外开销冲过预算，也不会把机器拖死。
# 用户会话里拿不到 user manager（没有 XDG_RUNTIME_DIR、会话总线不可用）时跳过。
setup_limits() {
    step "设置资源上限"

    local cgroup_ok=0
    if command -v systemd-run >/dev/null 2>&1 && [ -n "${XDG_RUNTIME_DIR:-}" ] &&
        systemctl --user show-environment >/dev/null 2>&1; then
        # 先空跑一次，确认这个账户真的能往自己的 slice 里写限额
        if systemd-run --user --scope --collect -q \
            -p "MemoryMax=${MEM_LIMIT_MB}M" \
            -p "CPUQuota=$((CPU_LIMIT * 100))%" -- true >/dev/null 2>&1; then
            LIMITER=(
                systemd-run --user --scope --collect -q
                -p "MemoryMax=${MEM_LIMIT_MB}M"
                -p "CPUQuota=$((CPU_LIMIT * 100))%"
                --
            )
            cgroup_ok=1
        fi
    fi
    if [ "$cgroup_ok" = 1 ]; then
        ok "cgroup 硬上限：MemoryMax=${MEM_LIMIT_MB}M  CPUQuota=$((CPU_LIMIT * 100))%"
    else
        warn "拿不到 user manager 的 cgroup，跳过硬限，只靠 JVM 参数（软限）"
    fi

    local total
    total="$(nproc 2>/dev/null || echo 0)"
    if [ "$total" -gt "$CPU_LIMIT" ] && command -v taskset >/dev/null 2>&1; then
        TASKSET=(taskset -c "0-$((CPU_LIMIT - 1))")
        ok "CPU 绑核：0-$((CPU_LIMIT - 1))（本机 $total 核，只给构建 $CPU_LIMIT 核）"
    elif [ "$total" -gt 0 ] && [ "$total" -le "$CPU_LIMIT" ]; then
        say "本机 $total 核，没超过上限，不绑核"
    else
        warn "没有 taskset，只用 Gradle 并发数（$CPU_LIMIT）限制 CPU"
    fi

    say "内存：Gradle 堆 ${GRADLE_HEAP_MB}M + 元空间 ${GRADLE_META_MB}M，" \
        "Kotlin 守护进程 ${KOTLIN_HEAP_MB}M + ${KOTLIN_META_MB}M"
}

# 把 Gradle 的任务名翻译成人话，心跳时显示更有用
friendly_task() {
    case "$1" in
        *minifyReleaseWithR8*|*minifyRelease*)
            printf 'R8 压缩代码（最慢的一步）' ;;
        *lintVital*|*lint*)
            printf 'lint 检查' ;;
        *compileReleaseKotlin*)
            printf '编译 Kotlin' ;;
        *kspReleaseKotlin*|*Ksp*)
            printf 'KSP 注解处理' ;;
        *processReleaseResources*|*mergeReleaseResources*)
            printf '处理资源' ;;
        *dexBuilder*|*mergeDex*|*Dex*)
            printf '生成 dex' ;;
        *packageRelease*)
            printf '打包 APK' ;;
        *test*Release*)
            printf '跑测试' ;;
        *Resolve*|*download*)
            printf '解析/下载依赖' ;;
        *)
            printf '%s' "$1" ;;
    esac
}

# 跑 gradle，同时把任务行实时刷出来，并每 30 秒打一行心跳。
# 之所以自己接管输出：Gradle 打完 "Daemon will be stopped" 之后，
# Kotlin 编译 / R8 / lint 会安静好几分钟，看起来像卡死。
gradle_with_progress() {
    local log="$CACHE_ROOT/gradle-build.log"
    mkdir -p "$CACHE_ROOT"
    : > "$log"

    local start pid rc
    start="$(date +%s)"

    # 镜像前置：settings.gradle.kts 里的仓库顺序由 init 脚本改写，工程文件不动
    local mirror_args=()
    if [ "$MIRROR" != "off" ] && [ -f "$MIRROR_INIT" ]; then
        mirror_args=(--init-script "$MIRROR_INIT")
    fi

    "${LIMITER[@]}" "${TASKSET[@]}" "$GRADLE_HOME/bin/gradle" assembleRelease \
        --console=plain --no-daemon \
        "--max-workers=$CPU_LIMIT" \
        "${mirror_args[@]}" \
        "-Dorg.gradle.jvmargs=-Xmx${GRADLE_HEAP_MB}m -XX:MaxMetaspaceSize=${GRADLE_META_MB}m -Dfile.encoding=UTF-8" \
        "-Dkotlin.daemon.jvm.options=-Xmx${KOTLIN_HEAP_MB}m,-XX:MaxMetaspaceSize=${KOTLIN_META_MB}m" \
        >>"$log" 2>&1 &
    pid=$!

    # 输出被重定向（CI 或 `> file`）时不刷心跳，避免污染日志
    if [ ! -t 1 ]; then
        set +e
        wait "$pid"; rc=$?
        set -e
        cat "$log"
        return "$rc"
    fi

    local printed=0 now elapsed total label last_task_line="" last_report="$start"
    # 心跳不能只说"进程还活着"：还要能看出是卡在下载，还是已经报错了。
    local log_size=0 last_grow="$start" silent=0 cache_mb=0
    local err_printed=0 stuck_hinted=0

    while kill -0 "$pid" 2>/dev/null; do
        sleep 2
        kill -0 "$pid" 2>/dev/null || break

        # 把新出现的任务行刷到终端
        total="$(grep -c '^> Task ' "$log" 2>/dev/null || true)"
        [ -z "$total" ] && total=0
        if [ "$total" -gt "$printed" ]; then
            grep '^> Task ' "$log" | tail -n "$((total - printed))" |
                sed 's/^> Task /     · /'
            printed="$total"
            # 记下最后一个任务名，心跳时一起显示
            last_task_line="$(grep '^> Task ' "$log" | tail -1 | sed 's/^> Task //')"
        fi

        now="$(date +%s)"

        # 日志不再增长时记静默时长；增长过就归零
        local cur_size
        cur_size="$(wc -c <"$log" 2>/dev/null || echo 0)"
        if [ "$cur_size" -gt "$log_size" ]; then
            log_size="$cur_size"
            last_grow="$now"
            stuck_hinted=0
        fi
        silent="$((now - last_grow))"

        # 日志里出现硬错误就立刻亮出来，不必等进程收尾
        if [ "$err_printed" = 0 ]; then
            local first_err
            first_err="$(grep -m1 -E '^(FAILURE:|e: |> Task .* FAILED)' "$log" 2>/dev/null || true)"
            if [ -n "$first_err" ]; then
                printf '   %s[构建已报错]%s %s\n' "$C_R" "$C_0" "$first_err"
                err_printed=1
            fi
        fi

        # 每 30 秒打一行心跳，说明没卡死（不管有没有新任务都打）
        if [ "$((now - last_report))" -ge 30 ]; then
            elapsed="$((now - start))"
            cache_mb="$(du -sm "$GRADLE_USER_HOME_DIR" 2>/dev/null | cut -f1)"
            [ -z "$cache_mb" ] && cache_mb=0
            printf '   %s⏳ 已运行 %dm%02ds%s' \
                "$C_Y" "$((elapsed / 60))" "$((elapsed % 60))" "$C_0"
            if [ -n "$last_task_line" ]; then
                label="$(friendly_task "$last_task_line")"
                printf '   当前：%s' "$label"
            else
                printf '   正在配置项目 / 下载依赖'
            fi
            printf '   依赖缓存 %sM   日志静默 %ss\n' "$cache_mb" "$silent"

            # 3 分钟没有任何输出：多半是卡在下载，给出可操作的提示（只提示一次）
            if [ "$silent" -ge 180 ] && [ "$stuck_hinted" = 0 ]; then
                warn "已经 ${silent}s 没有新输出，多半卡在下载依赖：$CACHE_ROOT/gradle-build.log"
                stuck_hinted=1
            fi
            last_report="$now"
        fi
    done

    set +e
    wait "$pid"; rc=$?
    set -e

    # 收尾：把循环里还没刷出来的任务行补上
    total="$(grep -c '^> Task ' "$log" 2>/dev/null || true)"
    [ -z "$total" ] && total=0
    if [ "$total" -gt "$printed" ]; then
        grep '^> Task ' "$log" | tail -n "$((total - printed))" |
            sed 's/^> Task /     · /'
    fi

    elapsed="$(( $(date +%s) - start ))"
    BUILD_SECONDS="$elapsed"
    BUILD_TASKS="$total"

    return "$rc"
}

build_apk() {
    step "编译 release"

    # 先把内存/CPU 上限定下来，再启动构建进程
    setup_limits

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

    # 第一次构建要拉全量依赖，提前打招呼，免得以为卡住
    if [ ! -d "$GRADLE_USER_HOME_DIR/caches/modules-2" ]; then
        warn "首次构建会下载全部依赖（几个 GB），耗时长属正常，不要中断"
        say ""
    fi
    if [ "$MIRROR" != "off" ] && [ -f "$MIRROR_INIT" ]; then
        ok "依赖镜像：阿里云（google / mavenCentral / gradle-plugin 前置，jitpack 保持直连）"
    elif [ "$MIRROR" = "off" ]; then
        warn "依赖镜像：已按 MIRROR=off 关闭，直连 google / mavenCentral（国内很慢）"
    else
        warn "依赖镜像：找不到 $MIRROR_INIT，直连 google / mavenCentral（国内很慢）"
    fi

    say "开始编译，下面会实时显示 Gradle 任务；长时间无任务输出时会打心跳"

    # 预置给 gradle_with_progress 回填，set -u 下也能安全引用
    BUILD_SECONDS=0
    BUILD_TASKS=0

    cd "$PROJECT_DIR"
    local rc=0
    gradle_with_progress || rc=$?

    if [ "$rc" -ne 0 ]; then
        # 失败时把日志尾部捞出来，别让人自己去翻文件
        printf '\n%s---- 构建失败，日志末 30 行 ----%s\n' "$C_R" "$C_0" >&2
        tail -n 30 "$CACHE_ROOT/gradle-build.log" >&2

        # 日志被硬切断（没有 BUILD FAILED 也没有编译错误）说明进程是被信号杀掉的，
        # 最常见的是 cgroup MemoryMax 触发 OOM。这种情况 Gradle 来不及写任何错误。
        local hint=""
        case "$rc" in
            137)
                hint="退出码 137 = 被 SIGKILL 杀掉，最常见的原因是 cgroup 内存超限（MemoryMax=${MEM_LIMIT_MB}M）。
  确认方式：
    sudo journalctl -k | grep -i -E 'oom|killed process' | tail -5
  确实是被杀：把上限放宽再试一次
    MEM_LIMIT_MB=6144 sh pack.sh
  要守住 4G：把 R8 阶段的并发降下来
    CPU_LIMIT=2 sh pack.sh" ;;
            143)
                hint="退出码 143 = 被 SIGTERM 杀掉，多半是手工 Ctrl+C 或 SSH 会话断开导致整棵进程树被回收。" ;;
            1)
                hint="退出码 1 = Gradle 自己报错，原因见上面日志里的 FAILURE 段。" ;;
        esac

        if [ -n "$hint" ]; then
            printf '\n%s诊断：%s\n' "$C_Y" "$C_0" >&2
            printf '  %s\n' "$hint" >&2
        fi

        die "构建失败（退出码 $rc）
  完整日志：$CACHE_ROOT/gradle-build.log"
    fi

    ok "构建完成（${BUILD_TASKS:-0} 个任务，耗时 $((BUILD_SECONDS / 60))m$((BUILD_SECONDS % 60))s）"

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
