#!/bin/bash
# posctrl.sh — prove each guard can actually go red. / 逐条证明守卫会红。
#
# WHY THIS FILE EXISTS / 为什么有这个文件
# ----------------------------------------------------------------------
# `quota-sentinel.test.sh` being green tells you that nothing is currently broken. It
# does not tell you that any of it would notice if something were. A guard that cannot
# fail is indistinguishable, on a green run, from a guard that is working — and every
# guard in this project exists because something once actually broke.
# 回归全绿只说明「此刻没坏」，不说明「坏了会被发现」。在一次绿色运行里，一条**不可能失败**
# 的守卫和一条正常工作的守卫长得一模一样——而本项目每一条守卫背后都有一次真实事故。
#
# So: for each guard, take a copy of the repository, break exactly the thing that guard
# is watching, re-run the suite against the copy, and require that the **named** case
# goes red. Not "the run failed" — that could be anything; the specific assertion has to
# be the one that fires.
# 因此：逐条守卫，复制一份仓库，**只**弄坏它盯着的那件事，对副本重跑回归，并要求**点名的**
# 那条用例变红。不是「这次跑挂了」——那可能是任何原因；必须是那一条断言响。
#
# ⚠️ Nothing here touches the working repository. Every mutation happens inside a
#    throwaway copy under $TMP, and the copy is what gets run.
# ⚠️ 本文件不碰工作仓：每一处改动都发生在 $TMP 下的一次性副本里，跑的也是那份副本。
#
# ⚠️ Read the negative control at the bottom before trusting any of it: an unmutated
#    copy must come out GREEN. Without that, "everything went red" would look like
#    perfect discriminating power while actually meaning the harness breaks every copy.
# ⚠️ 信任本文件之前先看末尾那条负控：**未改动的副本必须全绿**。没有它，「全都红了」
#    看起来像分辨力满分，实际可能只是说明这套脚手架把每一份副本都弄坏了。
#
# Usage / 用法:
#   bash test/posctrl.sh            run every ablation / 跑全部消融
#   bash test/posctrl.sh <id>...    run only these / 只跑这几条

set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/quota-sentinel-posctrl.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
WANT=("$@")

OK=0; BAD=0
declare -a ROWS=()

# ablate <id> <guard being proved> <layer> <expected text in the FAIL line> <mutator...>
# The mutator runs with $C set to the copy's root and may edit anything inside it.
ablate() {
  local id="$1" guard="$2" layer="$3" expect="$4"; shift 4
  if (( ${#WANT[@]} )); then
    local want found=0 w
    for w in "${WANT[@]}"; do [[ "$w" == "$id" ]] && found=1; done
    (( found )) || return 0
  fi
  local C="$TMP/$id"
  rm -rf "$C"; mkdir -p "$C"
  cp -r "$ROOT/lib" "$ROOT/test" "$ROOT/quota-sentinel" "$ROOT/account-probe" "$ROOT/account-switch" "$C/" 2>/dev/null
  ( C="$C"; "$@" ) || { printf 'ERROR %-22s the mutation itself failed to apply\n' "$id"; BAD=$((BAD+1)); return 0; }
  local out rc
  out=$(cd "$C" && bash "$C/test/quota-sentinel.test.sh" "$layer" 2>&1); rc=$?
  local hit=""
  if printf '%s' "$out" | grep -Fq -- "$expect"; then hit=1; fi
  if (( rc != 0 )) && [[ -n "$hit" ]]; then
    printf 'RED   %-22s %s\n' "$id" "$guard"
    ROWS+=("$id|$guard|RED (rc=$rc)")
    OK=$((OK+1))
  else
    printf 'MISS  %-22s %s\n' "$id" "$guard"
    printf '        expected a failure mentioning: %s\n' "$expect"
    printf '        run exit code: %s ; matched: %s\n' "$rc" "${hit:-no}"
    printf '        tail: %s\n' "$(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
    ROWS+=("$id|$guard|MISS")
    BAD=$((BAD+1))
  fi
}

# ── mutators / 改动手法 ────────────────────────────────────────────────
m_sed()  { local f="$1" from="$2" to="$3"
           grep -Fq -- "$from" "$C/$f" || { echo "anchor not found in $f: $from" >&2; return 1; }
           python3 - "$C/$f" "$from" "$to" <<'PY'
import sys
p,a,b=sys.argv[1],sys.argv[2],sys.argv[3]
s=open(p).read(); assert a in s
open(p,'w').write(s.replace(a,b,1))
PY
         }
m_drop() { local f="$1" pat="$2"
           grep -qE -- "$pat" "$C/$f" || { echo "nothing to drop in $f: $pat" >&2; return 1; }
           grep -vE -- "$pat" "$C/$f" > "$C/$f.new" && mv "$C/$f.new" "$C/$f"; }
m_append(){ printf '%s\n' "$2" >> "$C/$1"; }
m_sed_all(){ local f="$1" from="$2" to="$3"
           grep -Fq -- "$from" "$C/$f" || { echo "anchor not found in $f: $from" >&2; return 1; }
           python3 - "$C/$f" "$from" "$to" <<'EDIT'
import sys
p,a,b=sys.argv[1],sys.argv[2],sys.argv[3]
s=open(p).read(); assert a in s
open(p,'w').write(s.replace(a,b))
EDIT
         }
# ⚠️ After editing the frozen control group, the copy's declared checksum has to be
#    recomputed -- otherwise the hash guard fires first and the run never reaches the
#    detector assertion we are trying to prove. That is not a workaround, it is the
#    documented boundary of what a checksum proves: it catches an edit, it cannot catch
#    an edit that was accompanied by a matching hash update. These ablations deliberately
#    play the second role, so that the DETECTOR assertions get exercised too.
# ⚠️ 改完冻结对照组必须把副本里声明的哈希一起重算——否则哈希闸先响，跑不到我们要证明的
#    那条判据。这不是绕过，正是「哈希能证明什么」的边界：它抓得住「被改过」，抓不住
#    「改了并且顺手把哈希也改对了」。这几条消融刻意扮演后者，好让**判据本身**也被验到。
m_refreeze(){
  local f="$C/test/fixtures/legacy-detectors.sh" new
  new=$(bash -c 'source "$1"; printf "%s\n" "$QS_LEGACY_SRC" | sha256sum | cut -d" " -f1' _ "$f")
  python3 - "$f" "$new" <<'REFREEZE'
import sys,re
p,h=sys.argv[1],sys.argv[2]
s=open(p).read()
s=re.sub(r'QS_LEGACY_SHA256=[0-9a-f]{64}', 'QS_LEGACY_SHA256='+h, s)
open(p,'w').write(s)
REFREEZE
}
# m_frozen <from> <to> — edit the frozen control group AND update its declared hash,
# so the run gets past the integrity guard and reaches the detector assertion.
m_frozen(){ m_sed test/fixtures/legacy-detectors.sh "$1" "$2" && m_refreeze; }
# m_switch_noreadback — take out BOTH post-switch identity checks. Removing only one
# leaves the other still catching the case, and the ablation would come out green while
# the guard it is meant to prove is half gone. "Ablate the guard" means the whole guard.
# m_switch_noreadback —— 把切号后的**两条**身份校验一起拿掉。只拿掉一条时另一条仍抓得住，
# 消融会绿，而它要证明的那道守卫其实已经少了一半。「消融这道守卫」指的是整道。
m_switch_noreadback(){
  m_sed lib/switch.sh \
    'if [[ "$now_email" != "$to" || -z "$now_uuid" ]]; then' \
    'if false; then' || return 1
  m_sed lib/switch.sh \
    'if [[ -n "$before_email" && "$before_email" != "$to"' \
    'if false && [[ -n "$before_email" && "$before_email" != "$to"' || return 1
}

# ══ 1. the frozen control group / 冻结对照组 ══════════════════════════════
ablate frozen-control-edited \
  "冻结对照组被改动时整套回归拒绝开跑（哈希断言）" --fast \
  "the frozen control group has been modified" \
  m_sed test/fixtures/legacy-detectors.sh \
    "USAGE_MENU_FOOTER_REGEX='Enter to confirm.*Esc to cancel'" \
    "USAGE_MENU_FOOTER_REGEX='Enter to confirm.*Esc to CANCEL'"

# ══ 2–4. the three incident reproductions / 三次事故的复现 ═══════════════
# 让旧判据也认得出新文案 ⇒「28 天哑掉」那条复现不出来，用例必须自己报「没复现原缺陷」
ablate p1-menu-wording \
  "P1 选单文案事故：对照组必须在新文案上失效" --fast \
  "对照组应当在新文案上失效" \
  m_frozen \
    "USAGE_MENU_OPT2_REGEX='2\\.[[:space:]]+Switch to usage credits'" \
    "USAGE_MENU_OPT2_REGEX='2\\.[[:space:]]+'"

# 让旧横幅判据抓不到用户消息 ⇒ 自激事故复现不出来
ablate p3-banner-selftrigger \
  "P3 横幅自激事故：对照组必须被用户消息触发" --fast \
  "对照组没被触发" \
  m_frozen \
    'USAGE_BANNER_REGEX="You.{0,3}ve hit your [A-Za-z0-9 -]*limit"' \
    'USAGE_BANNER_REGEX="__never_matches_anything__"'

# 给旧解析器一个能解析的时区 ⇒ 8 小时偏差复现不出来
ablate p5-timezone-offset \
  "P5 缺时区 8 小时偏差：对照组必须复现它" --fast \
  "对照组未复现 8 小时偏差" \
  m_frozen \
    '[[ -n "$tz" ]] || tz=$(date +%Z)' \
    '[[ -n "$tz" ]] || tz=CST-8'

# ══ 5. the construction-time leak assertion / 构造期泄漏断言 ═════════════
ablate state-dir-leak \
  "构造期断言：任何 QUOTA_* 路径指进真状态目录就中止" --fast \
  "point into the REAL state directory" \
  m_append lib/config.sh 'QUOTA_POSCTRL_LEAK_PROBE="${XDG_STATE_HOME:-$HOME/.local/state}/quota-sentinel/posctrl-probe"'

# ══ 6. the tmux gate / tmux 隔离闸 ═══════════════════════════════════════
ablate tmux-gate-blind \
  "隔离闸必须抓得住 send-keys（2026-08-19 动了生产会话）" --fast \
  "闸抓不住 send-keys" \
  m_sed_all test/quota-sentinel.test.sh \
    '>> "$TMUX_VIOLATIONS"' \
    '>> /dev/null'

# ══ 7. extraction integrity / 抽取完整性 ═════════════════════════════════
ablate config-symbol-missing \
  "被读到的配置变量必须真的有定义（缺了会在 set -u 下杀进程）" --fast \
  "set -u 下会当场退出" \
  m_drop lib/config.sh '^QUOTA_ACCOUNT_DRIFT_LOG_INTERVAL='

ablate outparam-in-subshell \
  "靠全局回传的函数不许写在命令替换里（bash 语言陷阱）" --fast \
  "这些调用在子 shell 里跑" \
  m_append lib/state.sh 'posctrl_probe=$(quota_account_guard "posctrl-injected")'

# ══ 8. the decision gates / 决策闸 ═══════════════════════════════════════
ablate decide-stale-open \
  "决策对陈旧台账 fail closed" --slow \
  "拿超期读数切号" \
  m_sed lib/switch.sh \
    'if (( age < 0 || age > QUOTA_FETCH_MAX_AGE )); then' \
    'if false; then'

ablate blocked-no-throttle \
  "「无处可切」不得每拍刷日志与刷流水账" --slow \
  "每拍重试会把两者都刷满" \
  m_sed lib/switch.sh \
    'if [[ "$blocked_ts" =~ ^[0-9]+$ ]] && (( now - blocked_ts < QUOTA_SWITCH_MIN_INTERVAL )); then' \
    'if false; then'

# ══ 9. the switch itself / 切号本身 ══════════════════════════════════════
ablate switch-no-readback \
  "切号后必须回读身份，退出码 0 不算证据" --slow \
  "只看退出码就宣称切成了" \
  m_switch_noreadback

ablate switch-fence-not-moved \
  "切号成功后身份 fence 必须挪到新账号（否则永久 fail closed）" --slow \
  "下一拍守卫会判 account-drift" \
  m_sed lib/switch.sh \
    '      .account_guard.expected_email = $e' \
    '      .account_guard.expected_email_disabled_by_posctrl = $e'

# ══ 10. candidate selection / 候选选择 ═══════════════════════════════════
ablate roster-exclusion-off \
  "退役与暂停的账号不得进候选" --slow \
  "已退役/已暂停的账号仍在候选里" \
  m_sed lib/reading.sh \
    "jq -Rc 'split(\" \") | map(select(length > 0))'" \
    "jq -Rc 'split(\" \") | map(select(length > 99))'"

ablate switch-line-not-enforced \
  "恰好在切换线上的候选不得被接纳（否则切过去立刻再切走）" --fast \
  "正好在切换线上的候选被接纳了" \
  m_sed lib/switch.sh \
    '>= QUOTA_SWITCH_PCT_FIVE )) && continue' \
    '>= 100000 )) && continue'

# ══ 10b. the pipefail/SIGPIPE shape / pipefail 与 SIGPIPE ═══════════════
# 把一处匹配改回 `printf | grep -q` 的写法：结构判据必须抓到它。
# ⚠️ 这里刻意只验**结构判据**会红，不验那条 200 次行为判据——后者是统计判据，
#    在一次消融里恰好 200 次全对的概率不是 0（按实测 7.6% 约 1e-7，但那是概率不是保证）。
#    ⭐ 用一条概率判据去证明另一条判据「会红」，等于把一个可判定的问题换成一个赌注。
ablate pipeline-grepq \
  "判据里不许出现管道末端的 grep -q（pipefail 会把命中报成没命中）" --fast \
  "这些管道会把命中报成没命中" \
  m_sed lib/detect.sh \
    'grep -qE "$QUOTA_MENU_OPT1_REGEX" <<<"$t20" || return 1' \
    'printf "%s\\n" "$t20" | grep -qE "$QUOTA_MENU_OPT1_REGEX" || return 1'

# ══ 11. reading-side gates / 读数侧的闸 ══════════════════════════════════
ablate compare-log-heartbeat \
  "对账日志只在内容变化时记，不逐行心跳" --slow \
  "心跳会把真正的变化埋掉" \
  m_sed lib/reading.sh \
    '[[ "$_cmp_sig" == "$_cmp_prev" ]] && return 0' \
    '[[ "$_cmp_sig" == "__never__" ]] && return 0'

echo
echo "── 三列对照表 / guard -> ablation -> observed ──"
printf '%s\n' "${ROWS[@]}" | awk -F'|' '{printf "  %-24s %-58s %s\n", $1, $2, $3}'
echo
# ── negative control / 负控 ──────────────────────────────────────────────
# ⚠️ Without this line, "every ablation went red" is equally consistent with "this
#    harness breaks any copy it makes". Copy the repo, change nothing, and require GREEN.
# ⚠️ 没有这一条，「每条消融都红了」与「这套脚手架把任何副本都弄坏了」同样说得通。
#    复制一份、什么都不改、要求全绿。
NC="$TMP/negative-control"
mkdir -p "$NC"
cp -r "$ROOT/lib" "$ROOT/test" "$ROOT/quota-sentinel" "$ROOT/account-probe" "$ROOT/account-switch" "$NC/" 2>/dev/null
if nc_out=$(cd "$NC" && bash "$NC/test/quota-sentinel.test.sh" 2>&1); then
  echo "NEG-CTL  未改动的副本全绿：$(printf '%s' "$nc_out" | tail -1)"
else
  echo "NEG-CTL  ❌ 未改动的副本就已经红了 —— 上面每一条 RED 都不作数"
  printf '%s\n' "$nc_out" | grep -E '^  FAIL' | head -5
  BAD=$((BAD+1))
fi

echo
printf 'ablations proved red: %d   not proved: %d\n' "$OK" "$BAD"
(( BAD == 0 )) || exit 1
