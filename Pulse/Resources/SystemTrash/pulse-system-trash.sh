#!/bin/sh
# Pulse 系统级条目移进废纸篓——提权一侧的复核脚本(p7-cleaner/05;ADR-0012)。
#
# 由 Pulse 经系统脚本的管理员授权以 root 身份运行。原则:不信任 app 侧的判断——只接受
# 清单文件里的条目,逐条按**这里登记的路径形状**自行复核,不符就跳过并回传原因;
# 只做移动与改归属,不做任何删除(销毁只发生在用户点「清空废纸篓」,ADR-0010)。
#
# 入参(正好三个):
#   1 清单文件    app 在用户临时目录建的文本文件,一行一个绝对路径,属主必须是调用者
#   2 调用者 uid  移进废纸篓后把归属改成它
#   3 目标目录    调用者废纸篓下的子目录,app 先建好;必须在 <家目录>/.Trash/ 之内
# 结果:标准输出一行一条,制表符分隔——
#   MOVED<TAB>原路径<TAB>废纸篓内路径
#   SKIPPED<TAB>原路径<TAB>原因代码
# 退出码:0 = 走完(含逐条跳过);2 = 脚本级失败,整批没动(通道不可用),原因在标准错误。
#
# 登记的路径形状(与核心层 SystemLevelRuleTable 一一对应;改一处必须改另一处——不一致时
# 的表现是这里逐条跳过,不会多动):
#   · 系统崩溃报告目录直接下面的普通文件:名字不以点开头、放满 7 天、属主是 root 或系统用户
#
# 安全纪律:不走 eval;清单里的字符串只当数据,逐个严格引用,不拼进任何命令;路径先过形状
# 再碰文件系统。自测用的三个环境变量开关只在**非 root** 时生效——提权运行时形状不可改。
# 行为由 scripts/test-system-trash.sh 钉住(不提权,合成夹具)。

set -u
umask 077

REPORTS_DIR="/Library/Logs/DiagnosticReports"
MIN_AGE=604800 # 7 天(秒):与 SystemLevelRuleTable.crashReportsMinimumAge 同值
FIRST_REGULAR_UID=500 # macOS 的普通用户从 501 起;小于它的是系统用户

fail() {
    # 脚本级失败:在任何移动之前发生,整批没动。
    printf 'channel-unavailable: %s\n' "$1" >&2
    exit 2
}

skip() {
    # $1 = 原路径,$2 = 原因代码(app 侧按代码翻成人话)。
    printf 'SKIPPED\t%s\t%s\n' "$1" "$2"
}

is_uint() {
    case "$1" in
        '' | *[!0-9]*) return 1 ;;
    esac
    return 0
}

# ── 自测开关:只在非 root 时认;root 运行时见到即拒 ──
if [ "$(id -u)" -eq 0 ]; then
    if [ -n "${PULSE_SYSTEM_TRASH_TEST_REPORTS_DIR:-}" ] || [ -n "${PULSE_SYSTEM_TRASH_TEST_TRASH_ROOT:-}" ] ||
        [ -n "${PULSE_SYSTEM_TRASH_TEST_ALLOW_CALLER_OWNED:-}" ]; then
        fail "root 运行时不接受自测开关"
    fi
    allow_caller_owned=0
    trash_root_override=""
else
    REPORTS_DIR="${PULSE_SYSTEM_TRASH_TEST_REPORTS_DIR:-$REPORTS_DIR}"
    trash_root_override="${PULSE_SYSTEM_TRASH_TEST_TRASH_ROOT:-}"
    allow_caller_owned="${PULSE_SYSTEM_TRASH_TEST_ALLOW_CALLER_OWNED:-0}"
fi

# ── 入参与清单文件 ──
[ "$#" -eq 3 ] || fail "入参应当正好三个:清单文件、调用者 uid、目标目录"
manifest="$1"
caller_uid="$2"
target="$3"

is_uint "$caller_uid" || fail "调用者 uid 不是数字"
[ "$caller_uid" -ge "$FIRST_REGULAR_UID" ] || fail "调用者必须是普通用户"

# 清单文件:绝对路径、普通文件、不是符号链接、属主 = 调用者——把这份请求和调用者绑在一起。
case "$manifest" in
    /*) ;;
    *) fail "清单文件必须是绝对路径" ;;
esac
[ -L "$manifest" ] && fail "清单文件是符号链接"
[ -f "$manifest" ] || fail "清单文件不存在或不是普通文件"
[ "$(stat -f %u "$manifest")" = "$caller_uid" ] || fail "清单文件不属于调用者"
[ -r "$manifest" ] || fail "清单文件读不了"

# ── 登记的目录:本身不能是符号链接(换了个去处就不再是登记过的形状)──
[ -L "$REPORTS_DIR" ] && fail "登记的目录是符号链接"
[ -d "$REPORTS_DIR" ] || fail "登记的目录不存在"

# ── 废纸篓与目标目录 ──
if [ -n "$trash_root_override" ]; then
    trash_root="$trash_root_override"
else
    home=$(dscacheutil -q user -a uid "$caller_uid" | sed -n 's/^dir: //p')
    [ -n "$home" ] || fail "查不到调用者的家目录"
    trash_root="$home/.Trash"
fi
[ -L "$trash_root" ] && fail "废纸篓是符号链接"
[ -d "$trash_root" ] || fail "调用者的废纸篓不存在"
[ "$(stat -f %u "$trash_root")" = "$caller_uid" ] || fail "废纸篓不属于调用者"
caller_gid=$(stat -f %g "$trash_root")

case "$target" in
    "$trash_root"/*) ;;
    *) fail "目标目录不在调用者的废纸篓里" ;;
esac
case "/$target/" in
    */../*) fail "目标目录含 .." ;;
esac
[ -L "$target" ] && fail "目标目录是符号链接"
[ -d "$target" ] || fail "目标目录不存在(app 应先建好)"
[ "$(stat -f %u "$target")" = "$caller_uid" ] || fail "目标目录不属于调用者"

# ── 逐条复核 ──
tab=$(printf '\t')
now=$(date +%s)
moved=0
exec 3< "$manifest"
while IFS= read -r path <&3 || [ -n "$path" ]; do
    [ -n "$path" ] || continue

    # 形状:绝对路径、不含 ..。
    case "$path" in
        /*) ;;
        *) skip "$path" not-absolute; continue ;;
    esac
    case "/$path/" in
        */../*) skip "$path" contains-dotdot; continue ;;
    esac
    # 含制表符的路径:结果行就是用制表符分隔的,这类条目没法如实回传。不进标准输出
    # (调用方对「没有回执的条目」按失败记),只在标准错误留一行。
    case "$path" in
        *"$tab"*)
            printf 'warning: unsupported-name (tab): %s\n' "$(printf '%s' "$path" | tr "$tab" '?')" >&2
            continue
            ;;
    esac

    # 形状:登记目录的直接下面,名字不以点开头。
    case "$path" in
        "$REPORTS_DIR"/*) ;;
        *) skip "$path" outside-registered-directory; continue ;;
    esac
    name="${path#"$REPORTS_DIR"/}"
    case "$name" in
        */*) skip "$path" not-direct-child; continue ;;
    esac
    case "$name" in
        .*) skip "$path" hidden-file; continue ;;
    esac

    # 文件系统:不是符号链接、是普通文件(不存在的也落在这里)。
    [ -L "$path" ] && {
        skip "$path" symlink
        continue
    }
    [ -f "$path" ] || {
        skip "$path" not-a-regular-file
        continue
    }

    # 属主:root 或系统用户。自测开关下也认调用者自己的文件(普通用户建不出 root 属主的夹具)。
    owner=$(stat -f %u "$path")
    if [ "$owner" -ne 0 ] && [ "$owner" -ge "$FIRST_REGULAR_UID" ]; then
        if [ "$allow_caller_owned" = "1" ] && [ "$owner" = "$caller_uid" ]; then
            :
        else
            skip "$path" owner-not-system
            continue
        fi
    fi

    # 年龄:移动前再核一次(扫描之后文件可能被重写)。修改时间在未来的同样算太新。
    modified=$(stat -f %m "$path")
    age=$((now - modified))
    [ "$age" -ge "$MIN_AGE" ] || {
        skip "$path" too-young
        continue
    }

    # 目标已存在则加序号,绝不覆盖。
    destination="$target/$name"
    if [ -e "$destination" ] || [ -L "$destination" ]; then
        sequence=1
        while [ "$sequence" -lt 10000 ] && { [ -e "$destination.$sequence" ] || [ -L "$destination.$sequence" ]; }; do
            sequence=$((sequence + 1))
        done
        destination="$destination.$sequence"
    fi

    if mv "$path" "$destination"; then
        # 归属改成调用者:用户不用权限就能查看、恢复、清空。改不成不影响「已移走」的事实,
        # 只在标准错误留一行。
        chown "$caller_uid:$caller_gid" "$destination" 2> /dev/null ||
            printf 'warning: ownership-not-changed: %s\n' "$destination" >&2
        printf 'MOVED\t%s\t%s\n' "$path" "$destination"
        moved=$((moved + 1))
    else
        skip "$path" move-failed
    fi
done
exec 3<&-

# 一个都没移走:目标目录是空的,收掉,别在废纸篓里留空文件夹。
if [ "$moved" -eq 0 ]; then
    rmdir "$target" 2> /dev/null || :
fi
exit 0
