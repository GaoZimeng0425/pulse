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
# 退出码:0 = 走完(含逐条跳过);2 = 脚本级失败(通道不可用),原因在标准错误,标准输出里
# 没有 STAGING / MOVED 行。脚本级失败与被信号打断时,退出前把暂存目录里的条目放回原处;
# 被强杀(SIGKILL)放不回去的,下一次运行时按原名放回。
#
# 登记的路径形状(与核心层 SystemLevelRuleTable 一一对应;改一处必须改另一处——不一致时
# 的表现是这里逐条跳过,不会多动):
#   · 系统崩溃报告目录直接下面的普通文件:名字不以点开头、放满 7 天、属主是 root 或系统用户、
#     链接数是 1
#
# 安全纪律:不走 eval;外部命令一律写绝对路径(不靠 PATH 找命令);第一句就在干净的环境里
# 重跑自己——调用方的环境变量与导出的 shell 函数都不进来(系统脚本通道原样继承调用方的
# 环境,内建命令可以被同名函数顶替);清单里的字符串只当数据,逐个严格引用,不拼进任何
# 命令;路径先过形状再碰文件系统;清单文件先打开、再对着打开的那份核对。
# 自测用的四个环境变量开关只在**非 root** 时生效——提权运行时形状不可改。
# 行为由 scripts/test-system-trash.sh 钉住(不提权,合成夹具);哪些规则没有确定性用例,
# 写在那份自测的开头。

# ── 第一句:在干净的环境里重跑自己 ──
# 这一段只用 case、变量展开、特殊内建 exec,以及对绝对路径命令的输出做判断——它们顶替不了。
# 标记可以被调用方预先伪造,所以还要看环境里有没有函数导出、启动文件变量;有就再清一次。
case "${PULSE_SYSTEM_TRASH_REEXEC:-}" in
    yes)
        case "$(/usr/bin/env 2> /dev/null)" in
            *BASH_FUNC_* | *ENV=*) ;;
            *) clean_pass=1 ;;
        esac
        ;;
esac
case "${clean_pass:-}" in
    1) ;;
    *)
        exec /usr/bin/env -i \
            PULSE_SYSTEM_TRASH_REEXEC=yes \
            PULSE_SYSTEM_TRASH_TEST_REPORTS_DIR="${PULSE_SYSTEM_TRASH_TEST_REPORTS_DIR:-}" \
            PULSE_SYSTEM_TRASH_TEST_ALLOW_CALLER_OWNED="${PULSE_SYSTEM_TRASH_TEST_ALLOW_CALLER_OWNED:-}" \
            PULSE_SYSTEM_TRASH_TEST_STAGING_PARENT="${PULSE_SYSTEM_TRASH_TEST_STAGING_PARENT:-}" \
            PULSE_SYSTEM_TRASH_TEST_COMMANDS_DIR="${PULSE_SYSTEM_TRASH_TEST_COMMANDS_DIR:-}" \
            PATH=/usr/bin:/bin:/usr/sbin:/sbin \
            /bin/sh "$0" "$@"
        ;;
esac

set -u
umask 077
PATH=/usr/bin:/bin:/usr/sbin:/sbin

STAT=/usr/bin/stat
MV=/bin/mv
CHOWN=/usr/sbin/chown
CHOWN_FOR_RESTORE=/usr/sbin/chown # 回退用的那一份:不走替身(替身只用来造「改不了归属」)
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
stale_after=600 # 暂存目录放这么久(秒)没动静,才算上一次被打断留下的
staging=""
handed_off=0
allow_caller_owned=0
chown_log="" # 试过改归属的条目:名字<TAB>原属主:组,一行一条(放回原处前先把属主与组改回去)
moved_lines="" # 「已移走」的结果行,交接成功才回传
tab=$(printf '\t')

fail() {
    # 脚本级失败:退出前由 restore_all 把暂存目录里的条目放回原处。
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

# 放回原处后回传跳过。放不回去(原处又有了同名条目)回传 not-restored,不谎报「没动」。
restore_and_skip() { # $1 = 原路径  $2 = 暂存目录里的条目名  $3 = 本来要回传的原因代码
    restore "$2"
    if [ -e "$staging/$2" ] || [ -L "$staging/$2" ]; then
        skip "$1" not-restored
    else
        skip "$1" "$3"
    fi
}

# shellcheck disable=SC2329  # 由下面的 trap 调用
restore_all() {
    # 没交接就退出(脚本级失败 / 被信号打断):暂存目录里的条目都放回原处,再收掉空目录。
    # 试过改归属的先把属主与组改回去(逐条记着原来的),不留「回到原处、却归了用户」的文件。
    [ -n "$staging" ] || return 0
    [ "$handed_off" = "1" ] && return 0
    if [ -n "$chown_log" ]; then
        printf '%s\n' "$chown_log" | while IFS="$tab" read -r logged_name logged_owner; do
            [ -n "$logged_name" ] || continue
            "$CHOWN_FOR_RESTORE" -h "$logged_owner" "$staging/$logged_name" 2> /dev/null || :
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
        [ -n "${PULSE_SYSTEM_TRASH_TEST_STAGING_PARENT:-}" ] || [ -n "${PULSE_SYSTEM_TRASH_TEST_COMMANDS_DIR:-}" ]; then
        fail "root 运行时不接受自测开关"
    fi
else
    REPORTS_DIR="${PULSE_SYSTEM_TRASH_TEST_REPORTS_DIR:-$REPORTS_DIR}"
    allow_caller_owned="${PULSE_SYSTEM_TRASH_TEST_ALLOW_CALLER_OWNED:-0}"
    staging_parent="${PULSE_SYSTEM_TRASH_TEST_STAGING_PARENT:-$staging_parent}"
    # 替身命令:目录里有同名的 stat / mv / chown 就用它(造「读不到状态」「改不了归属」这类
    # 普通用户造不出来的情形)。
    if [ -n "${PULSE_SYSTEM_TRASH_TEST_COMMANDS_DIR:-}" ]; then
        [ -x "$PULSE_SYSTEM_TRASH_TEST_COMMANDS_DIR/stat" ] && STAT="$PULSE_SYSTEM_TRASH_TEST_COMMANDS_DIR/stat"
        [ -x "$PULSE_SYSTEM_TRASH_TEST_COMMANDS_DIR/mv" ] && MV="$PULSE_SYSTEM_TRASH_TEST_COMMANDS_DIR/mv"
        [ -x "$PULSE_SYSTEM_TRASH_TEST_COMMANDS_DIR/chown" ] && CHOWN="$PULSE_SYSTEM_TRASH_TEST_COMMANDS_DIR/chown"
    fi
fi

# ── 入参、调用者 ──
[ "$#" -eq 2 ] || fail "入参应当正好两个:清单文件、调用者 uid"
manifest="$1"
caller_uid="$2"

is_uint "$caller_uid" || fail "调用者 uid 不是数字"
[ "$caller_uid" -ge "$FIRST_REGULAR_UID" ] || fail "调用者必须是普通用户"
caller_gid=$("$ID" -g "$caller_uid" 2> /dev/null)
is_uint "$caller_gid" || fail "查不到调用者"

# ── 清单文件:先打开,再对着打开的那份核对 ──
# 路径上的检查只是早筛;「属主 = 调用者」必须对着真正读到的那份做——检查与打开之间,
# 路径可以被换成别的文件。这份核对把请求和调用者绑在一起。
case "$manifest" in
    /*) ;;
    *) fail "清单文件必须是绝对路径" ;;
esac
[ -L "$manifest" ] && fail "清单文件是符号链接"
[ -r "$manifest" ] || fail "清单文件读不了"
exec 3< "$manifest"
[ "$("$STAT" -f %HT /dev/fd/3)" != "Regular File" ] && fail "清单文件不是普通文件"
[ "$("$STAT" -f %u /dev/fd/3)" = "$caller_uid" ] || fail "清单文件不属于调用者"

# ── 登记的目录:本身不能是符号链接;必须和暂存目录在同一个卷(移动只是改名,不产生副本)──
[ -L "$REPORTS_DIR" ] && fail "登记的目录是符号链接"
[ -d "$REPORTS_DIR" ] || fail "登记的目录不存在"
reports_device=$("$STAT" -f %d "$REPORTS_DIR")
now=$("$DATE" +%s)

# ── 自愈:上一次被打断留下的暂存目录 ──
# 只认没交接的(属主是现在跑脚本的这个身份——root)、放了一阵子的。里面的条目按原名放回
# 登记目录;放完了空目录收掉。交接出去的归调用者,由 app 那边收。
for stale in "$staging_parent"/pulse-system-trash.*; do
    [ -d "$stale" ] || continue
    [ -L "$stale" ] && continue
    [ "$("$STAT" -f %u "$stale")" = "$("$ID" -u)" ] || continue
    stale_modified=$("$STAT" -f %m "$stale") || continue
    is_uint "$stale_modified" || continue
    [ "$((now - stale_modified))" -ge "$stale_after" ] || continue
    for entry in "$stale"/*; do
        [ -e "$entry" ] || continue
        "$MV" -n "$entry" "$REPORTS_DIR/" 2> /dev/null || :
    done
    "$RMDIR" "$stale" 2> /dev/null || :
done

staging=$("$MKTEMP" -d "$staging_parent/pulse-system-trash.XXXXXX") || fail "建不了暂存目录"
[ "$("$STAT" -f %d "$staging")" = "$reports_device" ] || fail "暂存目录与登记的目录不在同一个卷"

# ── 逐条复核 ──
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
    # 暂存目录里已经有同名条目(清单里同一个路径出现不止一次,原处又被补上了同名文件):
    # 再移进来会把已经处理过的那份盖掉。不碰。
    if [ -e "$staged" ] || [ -L "$staged" ]; then
        skip "$path" duplicate
        continue
    fi

    # 进暂存目录。此后的一切核对都对着这份条目做——它在 root 私有的目录里,别人换不了。
    if ! "$MV" "$path" "$staged"; then
        skip "$path" move-failed
        continue
    fi
    if [ "$("$STAT" -f %HT "$staged" 2> /dev/null)" != "Regular File" ]; then
        restore_and_skip "$path" "$name" not-a-regular-file
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
        restore_and_skip "$path" "$name" stat-failed
        continue
    fi
    # 链接数:不为 1 说明别的路径还指着这个文件(放进来的硬链接)——改归属会连那份一起改。
    if [ "$links" -ne 1 ]; then
        restore_and_skip "$path" "$name" hard-linked
        continue
    fi
    # 属主:root 或系统用户。自测开关下也认调用者自己的文件(普通用户建不出 root 属主的夹具)。
    if [ "$owner" -ne 0 ] && [ "$owner" -ge "$FIRST_REGULAR_UID" ]; then
        if [ "$allow_caller_owned" = "1" ] && [ "$owner" = "$caller_uid" ]; then
            :
        else
            restore_and_skip "$path" "$name" owner-not-system
            continue
        fi
    fi
    # 年龄:移动前再核一次(扫描之后文件可能被重写)。修改时间在未来的同样算太新。
    if [ "$((now - modified))" -lt "$MIN_AGE" ]; then
        restore_and_skip "$path" "$name" too-young
        continue
    fi

    # 改归属成调用者。先登记再改:登记与改之间被信号打断,退出时也知道要把属主改回去
    # (改归属本来就失败的话,改回去是无操作)。改不成就放回原处、按跳过报——不留
    # 「文件离开了原处、归属却不对」的状态。「已移走」的结果行先攒着,交接成功才一起回传:
    # 退出码非 0 时标准输出里不该有它。
    chown_log="${chown_log}${name}${tab}${owner}:${group}
"
    if "$CHOWN" -h "$caller_uid:$caller_gid" "$staged"; then
        moved_lines="${moved_lines}MOVED${tab}${path}${tab}${staged}
"
    else
        restore_and_skip "$path" "$name" ownership-not-changed
    fi
done
exec 3<&-

if [ -n "$moved_lines" ]; then
    # 交接:暂存目录交给调用者(只有它进得来),app 以它的身份把文件挪进废纸篓。
    if "$CHOWN" -h "$caller_uid:$caller_gid" "$staging" && "$CHMOD" 700 "$staging"; then
        handed_off=1
        printf 'STAGING\t%s\n%s' "$staging" "$moved_lines"
    else
        fail "暂存目录交不给调用者"
    fi
else
    # 一条都没移走:空目录收掉。放不回原处的条目留在里面,下一次运行时自愈会再试着放回。
    "$RMDIR" "$staging" 2> /dev/null || :
fi
exit 0
