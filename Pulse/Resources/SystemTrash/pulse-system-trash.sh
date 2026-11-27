#!/bin/sh
# Pulse 系统级条目移进废纸篓——提权一侧的复核脚本(p7-cleaner/05;ADR-0012)。
#
# 由 Pulse 经系统脚本的管理员授权以 root 身份运行。原则:不信任 app 侧的判断——只接受
# 清单文件里的条目,逐条按**这里登记的路径形状**自行复核,不符就跳过并回传原因。
# 不做任何删除(销毁只发生在用户点「清空废纸篓」,ADR-0010)。
#
# 两段式:root 只在自己的私有暂存目录里动文件,不往任何用户可控的目录里写,也不按那里的
# 路径改归属。
#   第一段(本脚本,root):条目从登记目录移进暂存目录 → 在暂存目录里核对文件本身
#     (类型 / 链接数 / 属主 / 年龄)→ 把归属改成调用者 → 把暂存目录交给调用者。
#   第二段(app,以调用者身份):把暂存目录里的文件挪进废纸篓的专属子目录。
# 为什么不直接移进废纸篓:登记目录对某个用户组可写,那个组里的用户能把 root 文件的
# 硬链接放进去;root 若「移过去再按路径改归属」,改到的是那个 inode 本身——等于把
# /etc/sudoers 这类文件交给用户。废纸篓目录又归用户所有,root 按路径往里移,用户中途把
# 目录换成链接就能把 root 的移动引到别处。所以:链接数不为 1 的条目一律不碰;核对与改归属
# 只在 root 私有的暂存目录里做;进废纸篓这一步由用户自己做。
#
# 入参(正好两个):
#   1 清单文件   app 在用户临时目录建的文本文件,一行一个绝对路径,属主必须是调用者
#   2 调用者 uid 暂存目录里的文件、以及暂存目录本身,归属改成它
# 结果:标准输出一行一条,制表符分隔——
#   SKIPPED<TAB>原路径<TAB>原因代码   (边处理边回传,与清单同序)
#   STAGING<TAB>暂存目录路径          (交接成功后才有;app 从这里取文件)
#   MOVED<TAB>原路径<TAB>暂存目录里的路径
# 退出码:0 = 走完(含逐条跳过);2 = 脚本级失败,整批没动(通道不可用),原因在标准错误,
# 此时标准输出里没有 STAGING / MOVED 行。
#
# 登记的路径形状(与核心层 SystemLevelRuleTable 一一对应;改一处必须改另一处——不一致时
# 的表现是这里逐条跳过,不会多动):
#   · 系统崩溃报告目录直接下面的普通文件:名字不以点开头、放满 7 天、属主是 root 或系统用户、
#     链接数是 1
#
# 安全纪律:不走 eval;外部命令一律写绝对路径(不靠 PATH 找命令——不带授权的 do shell script
# 实测原样继承调用方的 PATH,首位就是用户可写目录;也不吃从环境里导入的同名 shell 函数);
# 清单里的字符串只当数据,逐个严格引用,不拼进任何命令;路径先过形状再碰文件系统。
# 自测用的四个环境变量开关只在**非 root** 时生效——提权运行时形状不可改。
# 行为由 scripts/test-system-trash.sh 钉住(不提权,合成夹具)。

set -u
umask 077
PATH=/usr/bin:/bin:/usr/sbin:/sbin

STAT=/usr/bin/stat
MV=/bin/mv
CHOWN=/usr/sbin/chown
CHMOD=/bin/chmod
DATE=/bin/date
MKTEMP=/usr/bin/mktemp
ID=/usr/bin/id
TR=/usr/bin/tr
RMDIR=/bin/rmdir

REPORTS_DIR="/Library/Logs/DiagnosticReports"
MIN_AGE=604800 # 7 天(秒):与 SystemLevelRuleTable.crashReportsMinimumAge 同值
FIRST_REGULAR_UID=500 # macOS 的普通用户从 501 起;小于它的是系统用户
staging_parent=/var/tmp # 粘滞位 + root 所有:别人换不掉这里面的暂存目录
staging=""
handed_off=0
chown_command=$CHOWN
allow_caller_owned=0
ownership_log="" # 已改过归属的条目:名字<TAB>原属主:组,一行一条(放回原处时先改回去)
moved_lines="" # 「已移走」的结果行,交接成功才回传
tab=$(printf '\t')

fail() {
    # 脚本级失败:退出前由 restore_all 把暂存目录里的条目放回原处,整批没动。
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

# 把暂存目录里的一个条目放回原处;原处已有同名条目时不覆盖。
restore() {
    "$MV" -n "$staging/$1" "$REPORTS_DIR/" 2> /dev/null || :
}

# shellcheck disable=SC2329  # 由下面的 trap 调用
restore_all() {
    # 没交接就退出(脚本级失败 / 被信号打断):暂存目录里的条目都放回原处,再收掉空目录。
    # 已改过归属的先把属主与组改回去(逐条记着原来的),不留「回到原处、却归了用户」的文件。
    [ -n "$staging" ] || return 0
    [ "$handed_off" = "1" ] && return 0
    if [ -n "$ownership_log" ]; then
        printf '%s\n' "$ownership_log" | while IFS="$tab" read -r logged_name logged_owner; do
            [ -n "$logged_name" ] || continue
            "$CHOWN" -h "$logged_owner" "$staging/$logged_name" 2> /dev/null || :
        done
    fi
    for staged in "$staging"/*; do
        [ -e "$staged" ] || continue
        "$MV" -n "$staged" "$REPORTS_DIR/" 2> /dev/null || :
    done
    "$RMDIR" "$staging" 2> /dev/null || :
}
trap 'restore_all' EXIT
trap 'exit 2' HUP INT TERM

# ── 自测开关:只在非 root 时认;root 运行时见到即拒 ──
if [ "$("$ID" -u)" -eq 0 ]; then
    if [ -n "${PULSE_SYSTEM_TRASH_TEST_REPORTS_DIR:-}" ] || [ -n "${PULSE_SYSTEM_TRASH_TEST_ALLOW_CALLER_OWNED:-}" ] ||
        [ -n "${PULSE_SYSTEM_TRASH_TEST_STAGING_PARENT:-}" ] || [ -n "${PULSE_SYSTEM_TRASH_TEST_CHOWN:-}" ]; then
        fail "root 运行时不接受自测开关"
    fi
else
    REPORTS_DIR="${PULSE_SYSTEM_TRASH_TEST_REPORTS_DIR:-$REPORTS_DIR}"
    allow_caller_owned="${PULSE_SYSTEM_TRASH_TEST_ALLOW_CALLER_OWNED:-0}"
    staging_parent="${PULSE_SYSTEM_TRASH_TEST_STAGING_PARENT:-$staging_parent}"
    chown_command="${PULSE_SYSTEM_TRASH_TEST_CHOWN:-$chown_command}"
fi

# ── 入参、调用者、清单文件 ──
[ "$#" -eq 2 ] || fail "入参应当正好两个:清单文件、调用者 uid"
manifest="$1"
caller_uid="$2"

is_uint "$caller_uid" || fail "调用者 uid 不是数字"
[ "$caller_uid" -ge "$FIRST_REGULAR_UID" ] || fail "调用者必须是普通用户"
caller_gid=$("$ID" -g "$caller_uid" 2> /dev/null)
is_uint "$caller_gid" || fail "查不到调用者"

# 清单文件:绝对路径、普通文件、不是符号链接、属主 = 调用者——把这份请求和调用者绑在一起。
case "$manifest" in
    /*) ;;
    *) fail "清单文件必须是绝对路径" ;;
esac
[ -L "$manifest" ] && fail "清单文件是符号链接"
[ -f "$manifest" ] || fail "清单文件不存在或不是普通文件"
[ "$("$STAT" -f %u "$manifest")" = "$caller_uid" ] || fail "清单文件不属于调用者"
[ -r "$manifest" ] || fail "清单文件读不了"

# ── 登记的目录:本身不能是符号链接;必须和暂存目录在同一个卷(移动只是改名,不产生副本)──
[ -L "$REPORTS_DIR" ] && fail "登记的目录是符号链接"
[ -d "$REPORTS_DIR" ] || fail "登记的目录不存在"
reports_device=$("$STAT" -f %d "$REPORTS_DIR")

staging=$("$MKTEMP" -d "$staging_parent/pulse-system-trash.XXXXXX") || fail "建不了暂存目录"
[ "$("$STAT" -f %d "$staging")" = "$reports_device" ] || fail "暂存目录与登记的目录不在同一个卷"

# ── 逐条复核 ──
now=$("$DATE" +%s)
exec 3< "$manifest"
while IFS= read -r path <&3 || [ -n "$path" ]; do
    [ -n "$path" ] || continue

    # 形状(只看字符串):绝对路径、不含 ..、登记目录的直接下面、名字不以点开头。
    case "$path" in
        /*) ;;
        *) skip "$path" not-absolute; continue ;;
    esac
    case "/$path/" in
        */../*) skip "$path" contains-dotdot; continue ;;
    esac
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
    # 含制表符的路径:结果行就是用制表符分隔的,没法如实回传。不进标准输出(调用方对
    # 「没有回执的条目」按失败记),只在标准错误留一行。
    case "$path" in
        *"$tab"*)
            printf 'warning: unsupported-name (tab): %s\n' "$(printf '%s' "$path" | "$TR" "$tab" '?')" >&2
            continue
            ;;
    esac

    # 符号链接不往暂存目录里拿;不存在的也不是普通文件。
    [ -L "$path" ] && {
        skip "$path" symlink
        continue
    }
    [ -f "$path" ] || {
        skip "$path" not-a-regular-file
        continue
    }
    staged="$staging/$name"

    # 进暂存目录。此后的一切核对都对着这份条目做——它在 root 私有的目录里,别人换不了。
    if ! "$MV" "$path" "$staged"; then
        skip "$path" move-failed
        continue
    fi
    if [ "$("$STAT" -f %HT "$staged" 2> /dev/null)" != "Regular File" ]; then
        restore "$name"
        skip "$path" not-a-regular-file
        continue
    fi
    facts=$("$STAT" -f '%l %u %g %m' "$staged" 2> /dev/null) || facts=""
    links=${facts%% *}
    rest=${facts#* }
    owner=${rest%% *}
    rest=${rest#* }
    group=${rest%% *}
    modified=${rest#* }
    if ! is_uint "$links" || ! is_uint "$owner" || ! is_uint "$group" || ! is_uint "$modified"; then
        restore "$name"
        skip "$path" stat-failed
        continue
    fi
    # 链接数:不为 1 说明别的路径还指着这个文件(放进来的硬链接)——改归属会连那份一起改。
    if [ "$links" -ne 1 ]; then
        restore "$name"
        skip "$path" hard-linked
        continue
    fi
    # 属主:root 或系统用户。自测开关下也认调用者自己的文件(普通用户建不出 root 属主的夹具)。
    if [ "$owner" -ne 0 ] && [ "$owner" -ge "$FIRST_REGULAR_UID" ]; then
        if [ "$allow_caller_owned" = "1" ] && [ "$owner" = "$caller_uid" ]; then
            :
        else
            restore "$name"
            skip "$path" owner-not-system
            continue
        fi
    fi
    # 年龄:移动前再核一次(扫描之后文件可能被重写)。修改时间在未来的同样算太新。
    age=$((now - modified))
    if [ "$age" -lt "$MIN_AGE" ]; then
        restore "$name"
        skip "$path" too-young
        continue
    fi

    # 改归属成调用者。改不成就放回原处、按跳过报——不留「文件离开了原处、归属却不对」的状态。
    # 「已移走」的结果行先攒着,交接成功才一起回传:退出码非 0 时标准输出里不该有它。
    if "$chown_command" -h "$caller_uid:$caller_gid" "$staged"; then
        ownership_log="$ownership_log$name$tab$owner:$group
"
        moved_lines="${moved_lines}MOVED${tab}${path}${tab}${staged}
"
    else
        restore "$name"
        skip "$path" ownership-not-changed
    fi
done
exec 3<&-

if [ -n "$moved_lines" ]; then
    # 交接:暂存目录交给调用者(只有它进得来),app 以它的身份把文件挪进废纸篓。
    if "$chown_command" -h "$caller_uid:$caller_gid" "$staging" && "$CHMOD" 700 "$staging"; then
        handed_off=1
        printf 'STAGING\t%s\n%s' "$staging" "$moved_lines"
    else
        fail "暂存目录交不给调用者"
    fi
else
    "$RMDIR" "$staging" 2> /dev/null || :
fi
exit 0
