#!/bin/sh
# shellcheck disable=SC2016,SC1003  # 锚点与替换串用单引号是有意的:里面要原样的 $ 与行尾反斜杠
#
# scripts/test-system-trash.sh 的变异检查(p7-cleaner/05;CODING_STANDARDS「提权纪律」)。
# 把复核脚本里的规则逐条弄坏,每弄坏一条跑一遍自测——自测必须报错。它守的不是产品,是
# 自测本身:复核规则一改、自测没跟上,这里红。
# 不提权、不要密码;全程在临时目录。改过 Pulse/Resources/SystemTrash/pulse-system-trash.sh
# 或 scripts/test-system-trash.sh 之后跑一次(不挂在 check.sh 里:一轮约两分钟)。
#
# 分三张单子:
#   · 必须被抓到——弄坏之后自测报错;没报 = 自测缺用例(或那条规则其实是被别的规则兜住的,
#     该挪去「等价」)。锚点找不到也红:规则被挪了位置,单子要跟着改;但只记一笔,接着跑完
#     余下的,免得一处锚点失配把整轮检查吞掉。
#   · 等价——单独弄坏它,另一道规则兜得住,自测照绿是应该的;互为兜底的规则另有「合起来
#     弄坏」的那一次,那一次必须红。
#   · 明知没钉住——要 root、要真管道才测得到的;如实列在这里,不算通过。哪天被自测抓到了,
#     就挪去「必须被抓到」。
#
# Usage: sh scripts/test-system-trash-mutations.sh
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
original="$root/Pulse/Resources/SystemTrash/pulse-system-trash.sh"
self_test="$root/scripts/test-system-trash.sh"

tmp_parent="${TMPDIR:-/tmp}"
tmp=$(mktemp -d "${tmp_parent%/}/pulse-system-trash-mutations.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
trap 'rm -rf "$tmp"; exit 1' HUP INT TERM

mutated="$tmp/pulse-system-trash.sh"
pass=0
fail=0

# 把 $1 里恰好出现一次的 $2 换成 $3(按 $4 = exact 时认整行相等,用来挑出本身是别的行的子串的
# 那一行)。字面量替换:锚点经环境变量交给 awk,不走 awk -v(它会解释转义)。不是恰好一次就
# 返回非零——不中止整轮。
replace_once() {
    if [ "${4:-}" = "exact" ]; then
        if ! OLD="$2" NEW="$3" awk '
            { if ($0 == ENVIRON["OLD"]) { n++; $0 = ENVIRON["NEW"] } print }
            END { if (n != 1) exit 3 }' "$1" > "$1.tmp"; then
            echo "❌ 整行锚点不是恰好一处: $2" >&2
            rm -f "$1.tmp"
            return 3
        fi
    elif ! OLD="$2" NEW="$3" awk '
        { i = index($0, ENVIRON["OLD"]); if (i > 0) { n++; $0 = substr($0, 1, i - 1) ENVIRON["NEW"] substr($0, i + length(ENVIRON["OLD"])) } print }
        END { if (n != 1) exit 3 }' "$1" > "$1.tmp"; then
        echo "❌ 锚点不是恰好一处(在 $(grep -cF -- "$2" "$1") 行里出现): $2" >&2
        rm -f "$1.tmp"
        return 3
    fi
    mv "$1.tmp" "$1"
}

# $1 = 标签  $2 = caught(自测必须报错)| unpinned(明知没钉住)| equivalent(等价,自测照绿是应该的)
# 余下成对给出 锚点 替换,按顺序逐个替换(一条变异可以同时弄坏几处);三元组「锚点 替换 exact」
# 表示整行相等。
mutate() {
    label="$1"
    expectation="$2"
    shift 2
    cp "$original" "$mutated"
    while [ "$#" -ge 2 ]; do
        if ! replace_once "$mutated" "$1" "$2" "${3:-}"; then
            fail=$((fail + 1))
            return
        fi
        if [ "${3:-}" = "exact" ]; then shift 1; fi
        shift 2
    done
    if PULSE_SYSTEM_TRASH_SCRIPT="$mutated" sh "$self_test" > "$tmp/out.log" 2>&1; then
        case "$expectation" in
            caught)
                fail=$((fail + 1))
                echo "❌ 弄坏了「${label}」,自测照样全绿——缺用例" >&2
                ;;
            equivalent)
                pass=$((pass + 1))
                echo "· 等价:「${label}」单独弄坏,另有规则兜住"
                ;;
            unpinned)
                pass=$((pass + 1))
                echo "· 明知没钉住:「${label}」"
                ;;
        esac
    else
        case "$expectation" in
            caught) pass=$((pass + 1)) ;;
            unpinned)
                fail=$((fail + 1))
                echo "❌「${label}」被自测抓到了——把它从「没钉住」挪到「必须被抓到」: $(tail -n 1 "$tmp/out.log")" >&2
                ;;
            equivalent)
                fail=$((fail + 1))
                echo "❌「${label}」标成了等价,却自测报错了——核对后挪单子: $(tail -n 1 "$tmp/out.log")" >&2
                ;;
        esac
    fi
}

# ── 必须被抓到:暂存目录里的核对 ──
mutate "链接数不为 1 不碰" caught \
    '    if [ "$links" -ne 1 ]; then' \
    '    if false; then'
mutate "暂存目录里的类型判定" caught \
    '    if [ "$("$STAT" -f %HT "$staged" 2> /dev/null)" != "Regular File" ]; then' \
    '    if false; then'
mutate "状态读取的数值守卫" caught \
    '    if ! is_uint "$links" || ! is_uint "$owner" || ! is_uint "$group" || ! is_uint "$modified"; then' \
    '    if false; then'
mutate "属主规则" caught \
    '    if [ "$owner" -ne 0 ] && [ "$owner" -ge "$FIRST_REGULAR_UID" ]; then' \
    '    if false; then'
mutate "年龄复核" caught \
    '    if [ "$((now - modified))" -lt "$MIN_AGE" ]; then' \
    '    if false; then'
mutate "往前改归属" caught \
    '    if "$CHOWN" -h "$caller_uid:$caller_gid" "$staged"; then' \
    '    if false; then'
mutate "改归属带 -h" caught \
    '    if "$CHOWN" -h "$caller_uid:$caller_gid" "$staged"; then' \
    '    if "$CHOWN" "$caller_uid:$caller_gid" "$staged"; then'
mutate "回退时把属主与组改回去" caught \
    '            "$CHOWN_FOR_RESTORE" -h "$logged_owner" "$staging/$logged_name" 2> /dev/null || :' \
    '            :'
mutate "交接时把暂存目录交给调用者" caught \
    '    if "$CHOWN" -h "$caller_uid:$caller_gid" "$staging" && "$CHMOD" 700 "$staging"; then' \
    '    if true; then'
mutate "同名条目不覆盖" caught \
    '    if [ -e "$staged" ] || [ -L "$staged" ]; then' \
    '    if false; then'
mutate "放不回原处如实报" caught \
    '    if [ -e "$staging/$2" ] || [ -L "$staging/$2" ]; then' \
    '    if false; then'
mutate "放回原处不覆盖原处的同名条目" caught \
    '    "$MV" -n "$staging/$1" "$REPORTS_DIR/" 2> /dev/null || :' \
    '    "$MV" "$staging/$1" "$REPORTS_DIR/" 2> /dev/null || :'

# ── 必须被抓到:自愈 ──
mutate "被打断留下的暂存目录自愈" caught \
    'for stale in "$staging_parent"/pulse-system-trash.*; do' \
    'for stale in ""; do'
mutate "自愈只认放了一阵子的" caught \
    '    [ "$((now - stale_modified))" -ge "$stale_after" ] || continue' \
    '    :'
mutate "自愈不跟随符号链接" caught \
    '    [ -L "$stale" ] && continue' \
    '    false && continue'
mutate "自愈只认自己名下的暂存目录" caught \
    '    [ "$("$STAT" -f %u "$stale")" = "$("$ID" -u)" ] || continue' \
    '    :'
mutate "自愈放回时不覆盖原处的同名条目" caught \
    '        "$MV" -n "$entry" "$REPORTS_DIR/" 2> /dev/null || :' \
    '        "$MV" "$entry" "$REPORTS_DIR/" 2> /dev/null || :'

# ── 必须被抓到:清单、调用者、环境 ──
mutate "清单文件不能是符号链接" caught \
    '[ -L "$manifest" ] && fail "清单文件是符号链接"' \
    'false && fail "清单文件是符号链接"'
mutate "清单文件是普通文件(对着打开的那份)" caught \
    '[ "$("$STAT" -f %HT /dev/fd/3)" != "Regular File" ] && fail "清单文件不是普通文件"' \
    'false && fail "清单文件不是普通文件"'
mutate "清单文件属主 = 调用者(对着打开的那份)" caught \
    '[ "$("$STAT" -f %u /dev/fd/3)" = "$caller_uid" ] || fail "清单文件不属于调用者"' \
    ' :'
mutate "清单文件读不了就停" caught \
    '[ -r "$manifest" ] || fail "清单文件读不了"' \
    ' :'
mutate "登记目录不能是符号链接" caught \
    '[ -L "$REPORTS_DIR" ] && fail "登记的目录是符号链接"' \
    'false && fail "登记的目录是符号链接"'
mutate "暂存目录与登记目录同一个卷" caught \
    '[ "$("$STAT" -f %d "$staging")" = "$reports_device" ] || fail "暂存目录与登记的目录不在同一个卷"' \
    ' :'
mutate "只收登记目录的直接下面" caught \
    '        */*) skip "$path" not-direct-child; continue ;;' \
    '        */*) ;;'
mutate "隐藏文件不收" caught \
    '        .*) skip "$path" hidden-file; continue ;;' \
    '        .*) ;;'
mutate "含 .. 的路径不收" caught \
    '        */../*) skip "$path" contains-dotdot; continue ;;' \
    '        */../*) ;;'
mutate "登记目录之外的不收" caught \
    '        *) skip "$path" outside-registered-directory; continue ;;' \
    '        *) ;;'
mutate "原处的符号链接不往暂存目录里拿" caught \
    '    [ -L "$path" ] && {' \
    '    false && {'
mutate "第一句在干净的环境里重跑自己" caught \
    '        exec /usr/bin/env -i \' \
    '        : \'
mutate "标记可伪造,还要看环境里有没有函数导出 / 启动文件变量" caught \
    '            *BASH_FUNC_* | *"${newline}ENV="* | *"${newline}BASH_ENV="*) ;;' \
    '            *) clean_pass=1 ;;'
# 互为兜底的规则合起来弄坏的那一次:不在干净环境里重跑、PATH 又不固定、命令又不写绝对路径
# → 调用方 PATH 上的假命令会被用到。
mutate "干净环境重跑 + PATH 固定 + 绝对路径(三道一起去掉)" caught \
    '        exec /usr/bin/env -i \' \
    '        : \' \
    'PATH=/usr/bin:/bin:/usr/sbin:/sbin' \
    ':' exact \
    'STAT=/usr/bin/stat' \
    'STAT=stat'
mutate "调用者 uid 范围 + 查得到调用者 + 清单属主核对(三道一起去掉)" caught \
    '[ "$caller_uid" -ge "$FIRST_REGULAR_UID" ] || fail "调用者必须是普通用户"' \
    ' :' \
    'is_uint "$caller_gid" || fail "查不到调用者"' \
    ' :' \
    '[ "$("$STAT" -f %u /dev/fd/3)" = "$caller_uid" ] || fail "清单文件不属于调用者"' \
    ' :'

# ── 等价:单独弄坏,另有规则兜住 ──
mutate "外部命令写绝对路径(PATH 固定兜住)" equivalent \
    'STAT=/usr/bin/stat' \
    'STAT=stat'
mutate "PATH 固定(外部命令写了绝对路径兜住)" equivalent \
    'PATH=/usr/bin:/bin:/usr/sbin:/sbin' \
    ':' exact
mutate "调用者 uid 是数字(范围核对与查得到调用者兜住)" equivalent \
    'is_uint "$caller_uid" || fail "调用者 uid 不是数字"' \
    ' :'
mutate "调用者 uid 范围(查得到调用者与清单属主核对兜住)" equivalent \
    '[ "$caller_uid" -ge "$FIRST_REGULAR_UID" ] || fail "调用者必须是普通用户"' \
    ' :'

# ── 明知没钉住(如实列出)──
mutate "root 运行时拒收自测开关" unpinned \
    '        fail "root 运行时不接受自测开关"' \
    '        :'
mutate "打开清单前早筛「是普通文件」(防的是命名管道卡死;目录那种由对着打开那份的核对兜住)" unpinned \
    '[ -f "$manifest" ] || fail "清单文件不存在或不是普通文件"' \
    ' :'

echo "test-system-trash-mutations: $pass 如预期,$fail 不如预期"
[ "$fail" -eq 0 ]
