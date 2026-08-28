#!/bin/bash
# quota-sentinel regression / 判据回归
#
# This suite is organised around one idea that is worth stating before anything else:
# **a guard that has never gone red proves nothing when it is green.** So wherever a
# guard exists because something actually broke, the suite also asserts that the
# broken behaviour is still reachable and still detected — either by running the
# frozen pre-fix detector (test/fixtures/legacy-detectors.sh) or by a positive control
# that feeds an input the guard MUST reject and fails the run if the guard accepts it.
# 本套件的组织方式先说一句：**一条从来没红过的守卫，绿了也不说明问题。**因此凡是因为
# 真出过事才存在的守卫，套件都同时断言那个坏行为仍然可达、仍然被抓到——要么跑冻结的
# 修复前判据（test/fixtures/legacy-detectors.sh），要么用一条正控：喂一个守卫**必须
# 拒绝**的输入，守卫一旦接受就判红。
#
# Layers / 分层:
#   bash test/quota-sentinel.test.sh            all / 全量
#   bash test/quota-sentinel.test.sh --fast     detectors and short stubs / 纯判据与短打桩
#   bash test/quota-sentinel.test.sh --slow     state machines and switching / 状态机与切号
#   bash test/quota-sentinel.test.sh --shadow   shadow sampling only / 仅影子采样
#
# Exit: 0 = all green, 1 = a case failed, 2 = bad usage, 3 = the suite was about to
# write into the real state directory (see the construction-time assertion below).

set -uo pipefail

TEST_LAYER=all
case $# in
  0) ;;
  1)
    case "$1" in
      --all)                TEST_LAYER=all ;;
      --fast)               TEST_LAYER=fast ;;
      --slow|--integration) TEST_LAYER=slow ;;
      --shadow)             TEST_LAYER=shadow ;;
      *) printf 'usage: %s [--all|--fast|--slow|--shadow]\n' "$0" >&2; exit 2 ;;
    esac
    ;;
  *) printf 'usage: %s [--all|--fast|--slow|--shadow]\n' "$0" >&2; exit 2 ;;
esac

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FIX="$ROOT/test/fixtures"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/quota-sentinel-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
pass() { printf '  PASS %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }

# ── Control group: the detectors as they were BEFORE the rewrite ──────────────
# Upstream this was fetched live from the private repository's history with a pinned
# SHA and `|| exit 1`. That history is not here, so the text is frozen in a fixture
# and its checksum is asserted on every run: an edited control group is the one
# failure mode that produces no error and no symptom, it just quietly stops being a
# control. See the fixture header for what the checksum does and does not prove.
# 对照组：重构**之前**那版判据。上游是钉死 SHA 从私有仓历史现取的，本仓没有那段历史，
# 于是冻进夹具，并在每次运行校验哈希——被改过的对照组是唯一一种不报错、无症状的失效，
# 它只是悄悄地不再是对照组。哈希证明什么、不证明什么见夹具头部。
# shellcheck source=test/fixtures/legacy-detectors.sh
source "$FIX/legacy-detectors.sh" || { echo "cannot load the frozen control group" >&2; exit 1; }
_legacy_now=$(printf '%s\n' "$QS_LEGACY_SRC" | sha256sum | cut -d' ' -f1)
if [[ "$_legacy_now" != "$QS_LEGACY_SHA256" ]]; then
  echo "the frozen control group has been modified" >&2
  echo "  expected sha256 $QS_LEGACY_SHA256" >&2
  echo "  actual   sha256 $_legacy_now" >&2
  echo "  Every 'the old detector got this wrong' assertion below compares against that" >&2
  echo "  text. With it changed, this suite only tests the new code against itself." >&2
  exit 1
fi
unset _legacy_now

# ── Subject under test / 被测 ────────────────────────────────────────────────
# ⚠️ Point the state root at $TMP **before** sourcing. Almost every writable path in
#    the tool is written as "${VAR:-$QS_STATE_DIR/...}", so redirecting the root once
#    redirects all of them, **including paths added later**. The per-variable
#    reassignments below are kept as a second line of defence, but they cannot be the
#    only one: relying on somebody remembering to add a line per new path is exactly
#    what failed upstream on 2026-08-21, when a newly added switch-ledger path had no
#    such line and the regression wrote 14 fabricated switch records into the
#    **production** ledger.
# ⚠️ **在 source 之前**把状态根指到 $TMP。工具里几乎所有可写路径都写成
#    "${VAR:-$QS_STATE_DIR/…}"，改一次根就全部落到 TMP，**包括以后新加的**。下面逐个
#    改指 TMP 的赋值保留作双保险，但不能只靠它：靠人记得给每个新路径补一行，正是上游
#    2026-08-21 出事的原因——当天新加的切号台账路径没人补，回归把 14 条假切号记录写进了
#    **生产**台账。
QS_STATE_DIR="$TMP/state"
mkdir -p "$QS_STATE_DIR" "$QS_STATE_DIR/lock"
QS_REAL_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/quota-sentinel"

# ⚠️ Pin the zone before anything resolves an offset. Several cases below assert a
#    wall-clock rendering ("this parses to 15:10 local"), and the offset is resolved
#    from the host at load time — so on a UTC machine those same assertions would
#    compare against different numbers and fail for a reason that has nothing to do
#    with the code. `CST-8` is the POSIX fixed-offset spelling (sign inverted: UTC+8);
#    it needs no zoneinfo database, so it behaves identically on a host with tzdata
#    and inside a stripped sandbox without it.
#    ⚠️ Pinning makes the suite deterministic, and that also means it stops being able
#    to notice "this only works at +8". One case below therefore re-runs a parse under
#    TZ=UTC and asserts the result MOVES, which is what proves the offset is resolved
#    rather than hard-coded.
# ⚠️ 在任何东西解析偏移量之前钉死时区。下面若干条断言的是墙上时间（「解析成本地 15:10」），
#    而偏移量是加载时从宿主取的——在 UTC 机器上同样的断言会跟不同的数字比，然后以一个与
#    代码无关的理由失败。`CST-8` 是 POSIX 固定偏移写法（符号与偏移相反，即 UTC+8），
#    不查 zoneinfo，因此在有 tzdata 的宿主和被剥光的沙箱里表现一致。
#    ⚠️ 钉死带来确定性，同时也意味着它不再能发现「这东西只在 +8 能用」。所以下面另有一条
#    在 TZ=UTC 下重跑解析、断言结果**会变**的用例——那才是「偏移量是解析出来的、不是写死的」
#    的证据。
export TZ="${QS_TEST_TZ:-CST-8}"

QS_SOURCE="${QS_SOURCE:-$ROOT}"
# shellcheck source=lib/config.sh
source "$QS_SOURCE/lib/config.sh"   || { echo "cannot load lib/config.sh" >&2; exit 1; }
# shellcheck source=lib/reading.sh
source "$QS_SOURCE/lib/reading.sh"  || { echo "cannot load lib/reading.sh" >&2; exit 1; }
# shellcheck source=lib/monitor.sh
source "$QS_SOURCE/lib/monitor.sh"  || { echo "cannot load lib/monitor.sh" >&2; exit 1; }
# shellcheck source=lib/detect.sh
source "$QS_SOURCE/lib/detect.sh"   || { echo "cannot load lib/detect.sh" >&2; exit 1; }
# shellcheck source=lib/switch.sh
source "$QS_SOURCE/lib/switch.sh"   || { echo "cannot load lib/switch.sh" >&2; exit 1; }
# shellcheck source=lib/state.sh
source "$QS_SOURCE/lib/state.sh"    || { echo "cannot load lib/state.sh" >&2; exit 1; }
# The CLI itself, for the display-layer commands. It guards its own dispatch with
# `[[ "${BASH_SOURCE[0]}" == "$0" ]]`, so sourcing it defines the functions without
# running a command.
# CLI 本身，为的是展示层那几个命令。它自己用 BASH_SOURCE/$0 守住了 dispatch，
# source 它只会定义函数，不会执行命令。
# shellcheck source=quota-sentinel
source "$QS_SOURCE/quota-sentinel"  || { echo "cannot load the CLI" >&2; exit 1; }

QUOTA_LOG="$TMP/quota.log"
QUOTA_STATE="$TMP/quota-state.json"
QUOTA_SHADOW_OAUTH_STATE="$TMP/quota-oauth-shadow-state.json"
QUOTA_SHADOW_OAUTH_EVENTS="$TMP/quota-oauth-shadow-events.jsonl"
QUOTA_SHADOW_OAUTH_LOCK="$TMP/quota-oauth-shadow.lock"
QUOTA_SHADOW_PIDFILE="$TMP/quota-shadow-poller.pid"
QUOTA_SHADOW_STATUSLINE_STATE="$TMP/quota-statusline-shadow-state.json"
QUOTA_SHADOW_STATUSLINE_EVENTS="$TMP/quota-statusline-shadow-events.jsonl"
QUOTA_SHADOW_STATUSLINE_LOCK="$TMP/quota-statusline-shadow.lock"
QUOTA_SHADOW_SCHEDULE_STATE="$TMP/quota-shadow-schedule.json"
QUOTA_SHADOW_SCHEDULE_LOCK="$TMP/quota-shadow-schedule.lock"
QUOTA_SOURCE_EVENTS="$TMP/quota-source-samples.jsonl"
QUOTA_SOURCE_EVENTS_LOCK="$TMP/quota-source-samples.lock"
QUOTA_PANEL_OBSERVATIONS="$TMP/quota-panel-observations.jsonl"
QUOTA_PANEL_OBSERVATIONS_LOCK="$TMP/quota-panel-observations.lock"
QUOTA_PANEL_PRUNE_STAMP="$TMP/quota-panel-observations.prune-ts"
QUOTA_MONITOR_OP_LOCK="$TMP/quota-monitor-op.lock"
QUOTA_SWITCH_LEDGER="$TMP/switches.jsonl"
QUOTA_SNAPSHOT_FILE="$TMP/account-quota-snapshot.json"

# ⚠️ Construction-time assertion: no QUOTA_* path may point into the real state
#    directory. This does not ask "did the test write there" — it asks "could it".
#    Whether a write happens depends on which branch runs, which is probabilistic;
#    whether a path points at the wrong root is structural, decidable right here, and
#    therefore cannot be missed. It is at the top and not at the end on purpose: by the
#    time a run has finished, a misdirected path has already been writing for several
#    hundred cases.
# ⚠️ 构造期断言：任何 QUOTA_* 路径都不许指进真的状态目录。这条不看「测试有没有真的写」，
#    只看「有没有可能写」——写没写要看运行时走没走到，是概率问题；指没指对是构造问题，
#    当场可判，也就不会漏。放在开头而不是收尾：一旦指错，等跑完再报时已经污染了几百条用例。
_leaks=""
for _v in $(compgen -v | grep '^QUOTA_'); do
  _val="${!_v:-}"
  [[ "$_val" == "$QS_REAL_STATE_DIR"* ]] && _leaks="$_leaks $_v=$_val"
done
if [[ -n "$_leaks" ]]; then
  printf 'aborting: these paths point into the REAL state directory and running on would corrupt it:%s\n' "$_leaks" >&2
  printf '  fix: give it a value under $TMP, or make sure it derives from $QS_STATE_DIR (already redirected here)\n' >&2
  exit 3
fi
unset _leaks _v _val

# ════════════════════════════════════════════════════════════════════════
# Global tmux gate: deny every real tmux call by default
# 全局 tmux 闸：默认拦住一切真实 tmux 调用
# ════════════════════════════════════════════════════════════════════════
# ⚠️ 2026-08-19 incident: the regression reached into **production sessions** and
#    pressed Esc on two live rate-limit dialogs. The action itself matched production
#    behaviour and touched nothing paid, but **that the tests were able to touch
#    production at all** is the incident. Root cause: each case stubbed tmux for
#    itself, with **no global backstop**; several functions reach for real panes, and
#    they were only ever entered through two paths that happened to be stubbed. The
#    isolation was implicit, unwritten, and unguarded — so when one of those side
#    paths became a main path, the tests walked straight in.
# ⚠️ 2026-08-19 事故：本回归伸手动了**生产会话**，给两个撞了限流框的对话按了 Esc。动作
#    本身与生产行为一致、没碰付费选项，但**测试有能力动生产**这件事本身就是事故。根因：
#    此前每条用例各自临时打桩 tmux，**没有全局兜底**；有几个函数会摸真实 pane，而它们
#    原本只从两条碰巧打了桩的路进入，于是**碰巧**安全——那是隐式的、没写下来、也没人守的
#    隔离。那条岔路一变成大路，测试就走了进去。
#
# ⇒ Deny by default: any tmux call that was not explicitly stubbed cannot reach tmux.
#   Cases that need specific behaviour still stub it themselves; _stub_restore restores
#   to this gate, not to the real tmux.
#
# ⚠️ The gate itself has to be verified, or it is an ornament nobody checks. Violations
#   are recorded in TMUX_VIOLATIONS; one case at the end asserts the log is empty, and
#   another deliberately triggers one, to prove the first assertion can go red.
TMUX_VIOLATIONS="$TMP/tmux-violations.log"
: > "$TMUX_VIOLATIONS"
# ⚠️ It must be a **reinstallable** function, not a one-off definition at the top of
#    the file. Upstream had 6 `unset -f tmux` teardowns; unset deletes the function
#    outright, so from that line until the next redefinition `tmux` was **the real
#    tmux** — that is the seam the 2026-08-19 leak went through, and after the last
#    unset the whole remainder of the file was bare. Those teardowns all call this
#    function instead.
_tmux_guard_install() {
  tmux() {
    case "${1:-}" in
      ls|list-sessions)  return 1 ;;   # "cannot ask" — the code must treat this as unknown, not as "no sessions"
      capture-pane)      printf '' ;;  # blank screen: no detector matches, nothing is misjudged
      has-session)       return 1 ;;
      display-message)   printf '' ;;
      send-keys|kill-session|new-session|rename-session|set-buffer|paste-buffer|respawn-pane)
        # These change somebody else's state — the genuinely dangerous class. Record and refuse.
        printf '%s %s\n' "$1" "${*:2}" >> "$TMUX_VIOLATIONS"
        return 1 ;;
      *) printf '%s %s\n' "UNSTUBBED:$1" "${*:2}" >> "$TMUX_VIOLATIONS"; return 1 ;;
    esac
  }
}
_tmux_guard_install

# ⚠️ Stubs must nest. If one block's save lands inside another block's save/restore
#    span, the **stub** gets saved as if it were the original, and from then on every
#    restore installs a stub — the contamination spreads hundreds of lines away and
#    surfaces as a completely unrelated case failing. Upstream fell into this twice in
#    one day (2026-08-24): once by deleting somebody else's restore while moving a
#    block, once by inserting a new block inside somebody else's span. Both took a long
#    time to trace back to the scaffolding.
#    ⇒ Point fixes cannot stop this, because it depends on **where** the block is
#      inserted, and that differs every time. Per-function counted stack instead:
#      the Nth save goes to orig.$f.N, restore pops level N.
# ⚠️ 打桩必须支持**嵌套**……（同上，2026-08-24 一天内栽两次，两次都花了很久才定位到脚手架）
declare -A _stub_depth=()
_stub_save() {
  local f n
  for f in "$@"; do
    n=$(( ${_stub_depth[$f]:-0} + 1 )); _stub_depth[$f]=$n
    declare -f "$f" > "$TMP/orig.$f.$n" 2>/dev/null || : > "$TMP/orig.$f.$n"
  done
}
_stub_restore() {
  local f n
  for f in "$@"; do
    n=${_stub_depth[$f]:-0}
    (( n > 0 )) || continue          # never touch what was not saved, or the real function gets unset
    if [[ -s "$TMP/orig.$f.$n" ]]; then . "$TMP/orig.$f.$n"; else unset -f "$f" 2>/dev/null || true; fi
    rm -f "$TMP/orig.$f.$n"; _stub_depth[$f]=$(( n - 1 ))
  done
}

read_fx() { cat "$FIX/$1"; }
ready_composer_frame() { printf '%s\n' '────────────────────────' $'❯\302\240'; }

# ════════════════════════════════════════════════════════════════════════
# Fast layer — detectors and short stubs / 快层：纯判据与短打桩
# ════════════════════════════════════════════════════════════════════════
run_fast_tests() {
echo "── 状态落盘：atomic rename 失败不能冒充成功 ──"
QUOTA_STATE="$TMP/state-rename-fail.json"
echo '{}' > "$QUOTA_STATE"
if (
  mv() { return 1; }
  quota_state_merge '.probe = true'
); then
  fail "mv 失败后 quota_state_merge 仍返回 0，at-most-once ledger 是假成功"
else
  pass "atomic rename 失败会向调用方报错，不会放行后续不可撤回动作"
fi

echo "── 选单入口：cc 改了选项文案之后还认不认得出 ──"
# 实测背景：cc 在 2026-07-14 之后把选项 2 从 "Switch to usage credits" 改成
# "Upgrade your plan"，旧判据逐字锚这行 → 此后 28 天 menu-detected 恒为 0，
# 同期横幅分支跑了 165+ 次，撞限会话只能等人手动清框。
if legacy_call usage_menu_present "$(read_fx menu-new-wording.txt)"; then
  fail "对照组应当在新文案上失效（它却命中了，说明本用例没复现原缺陷）"
else
  pass "对照组在新文案上确实进不去（复现了 28 天哑掉的那条）"
fi
if quota_menu_present "$(read_fx menu-new-wording.txt)"; then
  pass "新判据认得出新文案选单"
else
  fail "新判据仍认不出新文案选单"
fi

echo "── 选单入口：旧文案不得回归 ──"
if legacy_call usage_menu_present "$(read_fx menu-old-wording.txt)" && quota_menu_present "$(read_fx menu-old-wording.txt)"; then
  pass "新旧判据在旧文案上都命中（无回归）"
else
  fail "旧文案上新旧判据不一致"
fi

echo "── 选单入口：scrollback 里的死选单不得误判 ──"
if quota_menu_present "$(read_fx menu-in-scrollback.txt)"; then
  fail "新判据把 scrollback 里的死选单当成了活选单"
else
  pass "新判据不吃 scrollback 死选单（末 10 行有空 ❯ = cc 闲置）"
fi

echo "── 横幅入口：用户在对话里提到横幅文案（2026-08-11 活体自激）──"
# 当天实撞：用户在对话里引用了一句撞限横幅作说明，daemon 当场把本会话判成撞限，
# 建 episode、探活、并连发三次伪「额度已恢复」；同期另一个正在分析撞限日志的
# 会话也被同样抓进队列。
if legacy_call usage_banner_active "$(read_fx self-trigger-user-message.txt)"; then
  pass "对照组确实会被用户消息触发（复现了当天的自激）"
else
  fail "对照组没被触发，本用例没复现原缺陷"
fi
if quota_banner_present "$(read_fx self-trigger-user-message.txt)" >/dev/null; then
  fail "新判据仍会被用户消息触发"
else
  pass "新判据拒绝：横幅落在 ❯ 用户输入行上，不是 cc 渲染的横幅"
fi

echo "── 横幅入口：用户正在 composer 里打这段字 ──"
if legacy_call usage_banner_active "$(read_fx banner-in-composer.txt)"; then
  pass "对照组确实会被 composer 里的半截输入触发"
else
  fail "对照组没被触发，本用例没复现原缺陷"
fi
if quota_banner_present "$(read_fx banner-in-composer.txt)" >/dev/null; then
  fail "新判据仍被 composer 输入触发"
else
  pass "新判据拒绝 composer 输入"
fi

echo "── 横幅入口：真横幅必须照常认出（不得因收紧而漏判）──"
strength=$(quota_banner_present "$(read_fx banner-strict.txt)")
if [[ "$strength" == "strict" ]]; then
  pass "真横幅（⎿ 子行）判为 strict，无需交叉验证即可采信"
else
  fail "真横幅被漏判或降级（got=${strength:-none}）"
fi

echo "── 横幅入口：已被后续输出盖过的旧横幅 ──"
if quota_banner_present "$(read_fx banner-stale-covered.txt)" >/dev/null; then
  fail "新判据把已被新 ● 块盖过的旧横幅当成活的"
else
  pass "新判据拒绝陈旧横幅"
fi

echo "── reset 时间：缺时区时的 8 小时偏差 ──"
# 旧实现兜底用 tz=$(date +%Z)，本机返回裸 CST，glibc 把它当 UTC+0 → 整体偏 8 小时，
# 且不报错。实测活体撞出：同一句 "resets 3:10pm" 一次记成 15:10 一次记成 23:10。
old_epoch=$(legacy_call parse_usage_reset_epoch "$(read_fx reset-no-timezone.txt)" || echo "")
new_epoch=$(quota_parse_reset_epoch "$(read_fx reset-no-timezone.txt)" || echo "")
old_hm=$([[ -n "$old_epoch" ]] && date -d "@$old_epoch" '+%H:%M' || echo "-")
new_hm=$([[ -n "$new_epoch" ]] && date -d "@$new_epoch" '+%H:%M' || echo "-")
if [[ "$old_hm" == "23:10" ]]; then
  pass "对照组确实把 3:10pm 解析成本地 23:10（复现 8 小时偏差）"
else
  fail "对照组未复现 8 小时偏差（got=$old_hm，期望 23:10）"
fi
if [[ "$new_hm" == "15:10" ]]; then
  pass "新判据解析成本地 15:10（TZ=CST-8 固定偏移 + %z 自检）"
else
  fail "新判据解析错误（got=$new_hm，期望 15:10）"
fi

echo "── reset 时间：带时区时新旧应一致（无回归）──"
o=$(legacy_call parse_usage_reset_epoch "$(read_fx reset-with-timezone.txt)" || echo "")
n=$(quota_parse_reset_epoch "$(read_fx reset-with-timezone.txt)" || echo "")
if [[ -n "$o" && "$o" == "$n" ]]; then
  pass "带 (Asia/Shanghai) 时新旧解析一致（$(date -d "@$n" '+%H:%M')）"
else
  fail "带时区时新旧解析不一致（old=$o new=$n）"
fi

echo "── ISO 解析：cc 写进 .claude.json 的形态 ──"
iso_epoch=$(quota_iso_epoch "2026-08-11T08:10:00.492913+00:00" || echo "")
if [[ "$(date -d "@$iso_epoch" '+%H:%M')" == "16:10" ]]; then
  pass "ISO 带偏移直读为本地 16:10（不经任何本地时区推断）"
else
  fail "ISO 解析错误（got=$(date -d "@${iso_epoch:-0}" '+%H:%M')）"
fi

echo "── 新鲜度闸：陈旧读数必须判「未知」而不是拿来决策 ──"
export QUOTA_CLAUDE_JSON="$TMP/stale.json"
cat > "$QUOTA_CLAUDE_JSON" <<'JSON'
{"oauthAccount":{"emailAddress":"stale@example.com"},
 "cachedUsageUtilization":{"fetchedAtMs":1000000000000,"accountUuid":"u",
  "utilization":{"five_hour":{"utilization":100,"resets_at":null},
                 "seven_day":{"utilization":100,"resets_at":null}}}}
JSON
if quota_snapshot >/dev/null 2>&1; then
  pass "陈旧文件仍能读出快照（读数层本身不做判断）"
else
  fail "读数层读不出快照"
fi
if quota_snapshot_fresh "$(date +%s)" >/dev/null 2>&1; then
  fail "新鲜度闸没拦住 2001 年的陈旧读数"
else
  pass "新鲜度闸拦下陈旧读数（100% 但过期 → 判未知，不动作）"
fi
unset QUOTA_CLAUDE_JSON

echo "── 账号守卫：切号回读之后再被并发覆盖也不得静默跟随 ──"
export QUOTA_CLAUDE_JSON="$TMP/account-guard.json"
QUOTA_STATE="$TMP/account-guard-state.json"; QUOTA_CACHE_MTIME=""
cat > "$QUOTA_CLAUDE_JSON" <<'JSON'
{"oauthAccount":{"emailAddress":"target@x","accountUuid":"uuid-target"},
 "cachedUsageUtilization":{"accountUuid":"uuid-target"}}
JSON
cat > "$QUOTA_STATE" <<'JSON'
{"phase":"normal","account":"target@x",
 "account_guard":{"expected_email":"target@x","expected_uuid":"uuid-target"}}
JSON
if declare -F quota_account_guard >/dev/null 2>&1 \
   && quota_account_guard "test-before-overwrite" >/dev/null 2>&1; then
  pass "目标邮箱 + oauth UUID + usage UUID 一致时守卫放行"
else
  fail "账号身份一致时守卫未放行（或守卫尚不存在）"
fi

# 首次升级还没有 expected 字段时，也不能无条件采当前文件为基线：旧 state.account 是
# 最近一次面板归属。两者已不同时，正是“账号变了但没有对应切号成功事件”的签名。
cat > "$QUOTA_STATE" <<'JSON'
{"phase":"normal","account":"target@x"}
JSON
cat > "$QUOTA_CLAUDE_JSON" <<'JSON'
{"oauthAccount":{"emailAddress":"old@x","accountUuid":"uuid-old"},
 "cachedUsageUtilization":{"accountUuid":"uuid-old"}}
JSON
if quota_account_guard "test-first-baseline-mismatch" >/dev/null 2>&1; then
  fail "首次建 fence 时无视 state.account 差异，把无成功事件的旧账号收编成基线"
elif [[ "$(quota_state_get '.phase' '')" == "account_drift" \
     && -z "$(quota_state_get '.account_guard.expected_email' '')" ]]; then
  pass "首次建 fence 会用 state.account 否证静默漂移，不盲目采当前文件"
else
  fail "首次基线差异虽失败，但没有留下可诊断的 account_drift"
fi

# 恢复后续用例的持久 expected。
cat > "$QUOTA_STATE" <<'JSON'
{"phase":"normal","account":"target@x",
 "account_guard":{"expected_email":"target@x","expected_uuid":"uuid-target"}}
JSON

# 这是管家指出的一次性回读盲区：第一次检查已经通过，随后另一个 cc 进程才把整份
# .claude.json 用旧内存快照盖回。守卫必须拿持久 expected 身份对照，不能把新值当基线跟走。
cat > "$QUOTA_CLAUDE_JSON" <<'JSON'
{"oauthAccount":{"emailAddress":"old@x","accountUuid":"uuid-old"},
 "cachedUsageUtilization":{"accountUuid":"uuid-old"}}
JSON
if declare -F quota_account_guard >/dev/null 2>&1 \
   && quota_account_guard "test-after-overwrite" >/dev/null 2>&1; then
  fail "回读后被覆盖成旧账号，守卫仍放行"
elif [[ "$(quota_state_get '.phase' '')" == "account_drift" \
     && "$(quota_state_get '.account_guard.expected_email' '')" == "target@x" ]]; then
  pass "回读后再被覆盖会进入 account_drift，且不把旧账号收编成新基线"
else
  fail "账号漂移虽返回失败，但没有留下 account_drift + 原 expected 身份"
fi

# ⚠️ 语义修订（2026-08-12 13:00 停摆事故后反转本断言）：usage_uuid 是 /usage 的**缓存**，
# 切号后为空或滞留旧账号是正常状态——把它当身份会死锁（guard 要它一致才放行，它要跑
# /usage 才刷新，跑 /usage 要先过 guard），实测停摆 3 小时。身份只看 oauthAccount；
# 「面板数值可能属于旧账号」由 monitor owner guard + 陈旧帧判据把关，不在这里。
cat > "$QUOTA_STATE" <<'JSON'
{"phase":"normal","account":"target@x",
 "account_guard":{"expected_email":"target@x","expected_uuid":"uuid-target"}}
JSON
cat > "$QUOTA_CLAUDE_JSON" <<'JSON'
{"oauthAccount":{"emailAddress":"target@x","accountUuid":"uuid-target"},
 "cachedUsageUtilization":{"accountUuid":"uuid-old"}}
JSON
if quota_account_guard "test-split-identity" >/dev/null 2>&1; then
  pass "usage 缓存滞留旧账号（正常滞后）→ 守卫放行，不再制造 3 小时死锁"
else
  fail "usage 缓存滞后仍被当身份卡死（13:00 停摆事故的机制原样复活）"
fi

# ABA：共享文件在 panel 前后都呈 A，但 monitor 曾在中间按 B 重启。只核文件 expected
# 会两次都绿，仍会把 B-monitor 的面板值记给 A；必须把 monitor_account 也纳入归属证据。
cat > "$QUOTA_STATE" <<'JSON'
{"phase":"normal","account":"target@x","monitor_account":"old@x",
 "monitor_uuid":"uuid-target","monitor_session_created":100,
 "monitor_launch_id":"launch-100",
 "account_guard":{"expected_email":"target@x","expected_uuid":"uuid-target"}}
JSON
cat > "$QUOTA_CLAUDE_JSON" <<'JSON'
{"oauthAccount":{"emailAddress":"target@x","accountUuid":"uuid-target"},
 "cachedUsageUtilization":{"accountUuid":"uuid-target"}}
JSON
if declare -F quota_monitor_owner_guard >/dev/null 2>&1 && (
  quota_session_created() { printf '100\n'; }
  quota_monitor_live_launch_id() { printf 'launch-100\n'; }
  ! quota_monitor_owner_guard "test-monitor-aba" >/dev/null 2>&1
); then
  pass "panel 后文件虽回到 expected，monitor_account 不同仍会阻断 ABA 错归"
else
  fail "没有把 monitor_account 纳入 panel 归属判据，ABA 可把 B 的额度记给 A"
fi

# 同名 monitor 死后重建也是新 owner 事件；若只看旧 email/UUID，旧标记会被新 tmux
# 代际冒用。必须把启动时的 session_created 一起钉住。
cat > "$QUOTA_STATE" <<'JSON'
{"phase":"normal","account":"target@x","monitor_account":"target@x",
 "monitor_uuid":"uuid-target","monitor_session_created":100,
 "monitor_launch_id":"launch-100",
 "account_guard":{"expected_email":"target@x","expected_uuid":"uuid-target"}}
JSON
if (
  quota_session_created() { printf '200\n'; }
  quota_monitor_live_launch_id() { printf 'launch-100\n'; }
  ! quota_monitor_owner_guard "test-monitor-generation" >/dev/null 2>&1
); then
  pass "同名 monitor 的 session_created 变化会让旧 owner 证明失效"
else
  fail "monitor 同名重建后仍沿用旧 owner，面板归属缺少会话代际证明"
fi
}


# ════════════════════════════════════════════════════════════════════════
# Extraction integrity — guards that only this repository can fail
# 抽取完整性——只有本仓会栽的那几条
# ════════════════════════════════════════════════════════════════════════
# These have no upstream counterpart. They exist because splitting one 5124-line
# script into lib/*.sh created a failure mode the original could not have: a symbol
# can now be *read* in one file and *defined* in none, and under `set -u` that is not
# a warning, it is an immediate process exit on whichever branch first touches it.
# 这几条上游没有对应物。它们存在是因为「把 5124 行拆成 lib/*.sh」造出了原文件不可能有的
# 失效形态：一个符号可以在某个文件里被**读**、却在任何文件里都没被**定义**，而在 `set -u`
# 下那不是警告，是第一个碰到它的分支上整个进程当场退出。
run_extraction_tests() {

echo "── 抽取完整性：被读到的配置变量必须真的有定义 ──"
# 🔴 Found by this migration, 2026-08-28. lib/state.sh:424 read
#    QUOTA_ACCOUNT_DRIFT_LOG_INTERVAL; lib/config.sh never defined it (upstream did,
#    at sentinel-quota:576). The branch that reads it is the external-drift branch —
#    the one whose whole purpose is to notice that somebody else changed the account —
#    so the tool exited on exactly the event it was built to report.
# 🔴 本次迁移查出（2026-08-28）：lib/state.sh:424 读 QUOTA_ACCOUNT_DRIFT_LOG_INTERVAL，
#    而 lib/config.sh 从没定义过它（上游定义在 sentinel-quota:576）。读它的那个分支正是
#    外部漂移分支——其存在的全部意义就是「发现别人改了账号」——于是工具恰恰死在它被造出来
#    要报告的那件事上。
_undefined_reads() {
  # Every ALL-CAPS name read as $NAME / ${NAME}, minus every name that is assigned
  # somewhere or carries a `:-` default at its point of use, minus the ambient
  # environment.
  # ⚠️ This is a static check and says so out loud: it cannot see names built by
  #    expansion (`${prefix}_SUFFIX`), it does not follow `eval`, and it treats a name
  #    as defined if ANY file assigns it. It answers "is this symbol defined
  #    somewhere", not "is every branch safe".
  # ⚠️ 这是静态检查，且把话说明白：拼接出来的名字（`${prefix}_SUFFIX`）看不见，不跟
  #    `eval`，只要**任一**文件赋过值就算已定义。它答的是「这个符号有没有定义」，
  #    不是「每条分支都安全」。
  local reads assigned
  # ⚠️ Two shapes, and the second is the one that matters here: inside `(( ... ))`
  #    bash reads a variable with **no `$` sigil**, and that is exactly how the missing
  #    symbol was written (`>= QUOTA_ACCOUNT_DRIFT_LOG_INTERVAL`). A checker that only
  #    looks for `$NAME` is structurally blind to the very defect it was written for —
  #    which is what the positive control below caught on the first run.
  # ⚠️ 两种形态，而这里要紧的是第二种：`(( ... ))` 里读变量**不带 `$`**，那正是缺失的
  #    那个符号的写法。只找 `$NAME` 的检查器对它要抓的那个缺陷结构上是瞎的——下面的正控
  #    第一次跑就把这件事抓了出来。
  reads=$( { grep -ohE '\$\{?[A-Z][A-Z0-9_]*' "$@" | tr -d '${'
             grep -ohE '\(\([^)]*\)\)' "$@" | grep -oE '\b[A-Z][A-Z0-9_]{2,}\b'
           } | sort -u)
  assigned=$( { grep -ohE '(^|[^A-Za-z0-9_])[A-Z][A-Z0-9_]*=' "$@" | grep -oE '[A-Z][A-Z0-9_]*'
                grep -ohE '\$\{[A-Z][A-Z0-9_]*:[-?=+]' "$@" | grep -oE '[A-Z][A-Z0-9_]*'
              } | sort -u)
  comm -23 <(printf '%s\n' "$reads") <(printf '%s\n' "$assigned") \
    | grep -vxE 'HOME|PATH|TMPDIR|PWD|SHELL|TERM|LANG|LC_ALL|TZ|IFS|RANDOM|UID|EUID|HOSTNAME|SECONDS|LINENO|COLUMNS|LINES|OSTYPE|FUNCNAME|BASH_SOURCE|BASH_REMATCH|XDG_STATE_HOME|HTTPS_PROXY|HTTP_PROXY|NO_PROXY|ALL_PROXY|R|P' \
    || true
}
undef=$(_undefined_reads "$QS_SOURCE"/lib/*.sh "$QS_SOURCE/quota-sentinel")
if [[ -z "$undef" ]]; then
  pass "lib/*.sh 与 CLI 里没有「读了但谁都没定义」的配置变量"
else
  fail "这些名字被读到却没有任何定义，set -u 下会当场退出：$(printf '%s' "$undef" | tr '\n' ' ')"
fi

# 正控：把同一个检查指向一份**故意抠掉一行**的 config，必须变红。否则上面那条绿了也
# 不说明问题——它可能只是没看见任何东西。
mkdir -p "$TMP/posctrl-lib"
cp "$QS_SOURCE"/lib/*.sh "$TMP/posctrl-lib/"
grep -v '^QUOTA_ACCOUNT_DRIFT_LOG_INTERVAL=' "$QS_SOURCE/lib/config.sh" > "$TMP/posctrl-lib/config.sh"
undef_pc=$(_undefined_reads "$TMP/posctrl-lib"/*.sh)
if printf '%s\n' "$undef_pc" | grep -qx 'QUOTA_ACCOUNT_DRIFT_LOG_INTERVAL'; then
  pass "正控：删掉那一行定义之后，同一个检查确实抓得到（判据会红）"
else
  fail "正控没红：这个检查抓不到「读了没定义」，上面那条绿是没有分辨力的绿"
fi

echo "── 账号守卫：外部漂移分支不得因为一个未定义变量而杀死进程 ──"
# The branch above is only reachable when the state file and the config file disagree
# about which account is logged in, which is why no earlier test walked into it. This
# one constructs that disagreement on purpose and asserts the guard **returns** —
# a non-zero return is correct, a dead shell is not.
export QUOTA_CLAUDE_JSON="$TMP/drift-exit.json"
QUOTA_STATE="$TMP/drift-exit-state.json"
QUOTA_SWITCH_LEDGER="$TMP/drift-exit-ledger.jsonl"
cat > "$QUOTA_STATE" <<'JSON'
{"phase":"normal","account":"target@x",
 "account_guard":{"expected_email":"target@x","expected_uuid":"uuid-target"}}
JSON
cat > "$QUOTA_CLAUDE_JSON" <<'JSON'
{"oauthAccount":{"emailAddress":"other@x","accountUuid":"uuid-other"},
 "cachedUsageUtilization":{"accountUuid":"uuid-other"}}
JSON
drift_out=$( set -u; quota_account_guard "test-drift-survives" 2>&1; printf 'RC=%s' "$?" )
if [[ "$drift_out" == *"RC=1"* && "$drift_out" != *"unbound"* && "$drift_out" != *"未绑定"* ]]; then
  pass "漂移分支正常返回 1，没有因未绑定变量而退出"
else
  fail "漂移分支没有干净返回（这正是缺定义时的表现）：$drift_out"
fi
# 负控/正控合一：把那个变量 unset 掉再走同一条路，必须看到它坏。
drift_bad=$( set -u; unset QUOTA_ACCOUNT_DRIFT_LOG_INTERVAL; quota_account_guard "test-drift-unset" 2>&1; printf 'RC=%s' "$?" )
if [[ "$drift_bad" == *"unbound"* || "$drift_bad" == *"未绑定"* ]]; then
  pass "正控：把它 unset 之后同一条路确实坏掉（上面那条不是恒真）"
else
  fail "正控没红：unset 之后仍然一切正常，说明上面那条断言不测任何东西（got=$drift_bad）"
fi
QUOTA_ACCOUNT_DRIFT_LOG_INTERVAL=300
unset QUOTA_CLAUDE_JSON

echo "── 时区偏移必须是解析出来的，不是写死的 +8 ──"
# 上游把 +8 写死在可读时间那一层；抽取时换成从宿主解析。整套回归钉在 TZ=CST-8 下跑，
# 那让断言可复现，但同时也会让「写死 +8」和「解析到 +8」长得一模一样。
# ⇒ 换一个时区重跑同一个解析：结果必须**跟着变**。
iso_at_plus8=$(quota_iso_epoch "2026-08-11T08:10:00.492913+00:00" || echo "")
hm_plus8=$(TZ=CST-8 date -d "@${iso_at_plus8:-0}" '+%H:%M')
hm_utc=$(TZ=UTC date -d "@${iso_at_plus8:-0}" '+%H:%M')
if [[ "$hm_plus8" == "16:10" && "$hm_utc" == "08:10" ]]; then
  pass "同一 epoch 在 +8 与 UTC 下分别渲染成 16:10 / 08:10（偏移量真的参与了运算）"
else
  fail "渲染不随时区变化，说明某处把偏移写死了（+8=$hm_plus8 utc=$hm_utc）"
fi
}

# ── monitor lifecycle / monitor 生命周期 ──
run_monitor_tests() {
echo "── monitor 重启：保留 tmux/pane，只在原 shell 内替换 cc ──"
# 活体已证明 `/exit` 后 tmux session/window/pane 与 shell PID 都不变，而 Claude 子进程
# 会换新。旧实现直接 kill-session，会改变 session_created，随后 poller 又按代际不匹配
# 重启第二次。这里先把编排钉死：已有 monitor 只能 exit→launch→bind，不能 kill/new。
MONITOR_RESTART_TRACE="$TMP/monitor-restart-trace"
: > "$MONITOR_RESTART_TRACE"
_stub_save quota_monitor_alive quota_monitor_exit_to_shell quota_monitor_launch_in_pane \
           quota_monitor_bind_owner quota_monitor_ensure quota_account_guard \
           quota_session_created quota_monitor_live_launch_id quota_monitor_shell_ready \
           quota_monitor_single_pane_id
quota_monitor_alive() { return 0; }
quota_monitor_single_pane_id() { printf '%%1\n'; }
quota_monitor_shell_ready() { return 1; }
quota_monitor_exit_to_shell() { printf 'exit\n' >> "$MONITOR_RESTART_TRACE"; return 0; }
quota_monitor_launch_in_pane() {
  QUOTA_MONITOR_STARTED_LAUNCH_ID='launch-new'
  QUOTA_MONITOR_STARTED_EMAIL='target@x'
  QUOTA_MONITOR_STARTED_UUID='uuid-target'
  printf 'launch\n' >> "$MONITOR_RESTART_TRACE"; return 0
}
quota_monitor_bind_owner() {
  printf 'bind:%s:%s:%s\n' "$2" "$3" "$4" >> "$MONITOR_RESTART_TRACE"; return 0
}
quota_monitor_ensure() { printf 'ensure\n' >> "$MONITOR_RESTART_TRACE"; return 0; }
quota_account_guard() {
  QUOTA_GUARD_EMAIL='target@x'; QUOTA_GUARD_UUID='uuid-target'; return 0
}
quota_session_created() { printf '100\n'; }
quota_monitor_live_launch_id() { printf 'launch-new\n'; }
tmux() {
  case "${1:-}" in
    kill-session) printf 'kill-session\n' >> "$MONITOR_RESTART_TRACE" ;;
    new-session)  printf 'new-session\n' >> "$MONITOR_RESTART_TRACE" ;;
  esac
  return 0
}
if quota_monitor_restart 'target@x' 'uuid-target' >/dev/null 2>&1 \
   && [[ "$(tr '\n' ' ' < "$MONITOR_RESTART_TRACE")" == \
         "exit launch bind:target@x:uuid-target:launch-new " ]]; then
  pass "已有 monitor 在原 pane 内 /exit→新 cc→owner 绑定，不杀/重建 tmux"
else
  fail "monitor restart 仍破坏 tmux 或没有原子绑定：$(tr '\n' ' ' < "$MONITOR_RESTART_TRACE")"
fi

: > "$MONITOR_RESTART_TRACE"
quota_monitor_shell_ready() { return 0; }
if quota_monitor_restart 'target@x' 'uuid-target' >/dev/null 2>&1 \
   && [[ "$(tr '\n' ' ' < "$MONITOR_RESTART_TRACE")" == \
         "launch bind:target@x:uuid-target:launch-new " ]]; then
  pass "monitor 已退回 shell 时直接拉起新 cc，不会再向 shell 发送 /exit"
else
  fail "shell 恢复路径仍先发 /exit 或遗漏绑定：$(tr '\n' ' ' < "$MONITOR_RESTART_TRACE")"
fi

: > "$MONITOR_RESTART_TRACE"
quota_account_guard() { return 1; }
if ! quota_monitor_restart 'target@x' 'uuid-target' >/dev/null 2>&1 \
   && [[ ! -s "$MONITOR_RESTART_TRACE" ]]; then
  pass "显式 expected 在重启前重新核验账号；漂移时不碰 monitor UI"
else
  fail "账号已漂移仍执行了 monitor 重启：$(tr '\n' ' ' < "$MONITOR_RESTART_TRACE")"
fi
_tmux_guard_install   # 不留裸奔窗口：清桩即重装闸
_stub_restore quota_monitor_alive quota_monitor_exit_to_shell quota_monitor_launch_in_pane \
              quota_monitor_bind_owner quota_monitor_ensure quota_account_guard \
              quota_session_created quota_monitor_live_launch_id quota_monitor_shell_ready \
              quota_monitor_single_pane_id

# tmux 不再重建后 session_created 不变，必须另有 cc launch id。否则同 pane 里的旧
# statusLine 回调/旧 cc 画面可以冒用新进程 owner 证明。
cat > "$QUOTA_STATE" <<'JSON'
{"phase":"normal","account":"target@x","monitor_account":"target@x",
 "monitor_uuid":"uuid-target","monitor_session_created":100,
 "monitor_launch_id":"launch-old",
 "account_guard":{"expected_email":"target@x","expected_uuid":"uuid-target"}}
JSON
if declare -F quota_monitor_live_launch_id >/dev/null 2>&1 && (
  quota_session_created() { printf '100\n'; }
  quota_monitor_live_launch_id() { printf 'launch-new\n'; }
  ! quota_monitor_owner_guard "test-monitor-cc-generation" >/dev/null 2>&1
); then
  pass "tmux 代际相同但 cc launch id 不同 → 旧进程 owner 证明失效"
else
  fail "只看 session_created，原 pane 内换 cc 后无法区分新旧进程"
fi

# restart 已经负责启动并绑定，prepare_owner 不得紧接着再 bind/再触发一次换代。
PREPARE_TRACE="$TMP/monitor-prepare-restart-trace"
: > "$PREPARE_TRACE"
_stub_save quota_account_guard quota_monitor_alive quota_monitor_restart \
           quota_monitor_bind_owner quota_session_created quota_monitor_live_launch_id \
           quota_monitor_shell_ready quota_monitor_panel_open quota_monitor_ready \
           quota_monitor_single_pane_id
quota_account_guard() { QUOTA_GUARD_EMAIL='target@x'; QUOTA_GUARD_UUID='uuid-target'; return 0; }
quota_monitor_alive() { return 0; }
quota_monitor_single_pane_id() { printf '%%1\n'; }
quota_monitor_shell_ready() { return 1; }
quota_monitor_panel_open() { return 0; }
quota_monitor_ready() { return 1; }
quota_monitor_restart() { printf 'restart\n' >> "$PREPARE_TRACE"; return 0; }
quota_monitor_bind_owner() { printf 'bind\n' >> "$PREPARE_TRACE"; return 0; }
quota_session_created() { printf '100\n'; }
quota_monitor_live_launch_id() { printf 'launch-new\n'; }
cat > "$QUOTA_STATE" <<'JSON'
{"monitor_account":"old@x","monitor_uuid":"uuid-old",
 "monitor_session_created":100,"monitor_launch_id":"launch-old"}
JSON
if quota_monitor_prepare_owner >/dev/null 2>&1 \
   && [[ "$(tr '\n' ' ' < "$PREPARE_TRACE")" == "restart " ]]; then
  pass "owner/cc 代际变化只做一次 restart；restart 内已绑定，外层不重复"
else
  fail "prepare_owner 在 restart 后仍重复 bind/换代：$(tr '\n' ' ' < "$PREPARE_TRACE")"
fi

: > "$PREPARE_TRACE"
quota_monitor_shell_ready() { return 0; }
cat > "$QUOTA_STATE" <<'JSON'
{"monitor_account":"target@x","monitor_uuid":"uuid-target",
 "monitor_session_created":100,"monitor_launch_id":"launch-new"}
JSON
if quota_monitor_prepare_owner >/dev/null 2>&1 \
   && [[ "$(tr '\n' ' ' < "$PREPARE_TRACE")" == "restart " ]]; then
  pass "owner/launch 虽匹配但 cc 已回 shell → prepare_owner 仍只恢复一次"
else
  fail "tmux 活着掩盖了已退出的 cc：$(tr '\n' ' ' < "$PREPARE_TRACE")"
fi
_stub_restore quota_account_guard quota_monitor_alive quota_monitor_restart \
              quota_monitor_bind_owner quota_session_created quota_monitor_live_launch_id \
              quota_monitor_shell_ready quota_monitor_panel_open quota_monitor_ready \
              quota_monitor_single_pane_id

echo "── monitor 原 pane 换代：/exit 必须回 shell，pane 身份变化一律拒绝 ──"
MONITOR_FAKE_PHASE="$TMP/monitor-fake-phase"
MONITOR_FAKE_LAUNCH="$TMP/monitor-fake-launch"
MONITOR_FAKE_TRACE="$TMP/monitor-fake-trace"
printf 'old\n' > "$MONITOR_FAKE_PHASE"; printf 'launch-old\n' > "$MONITOR_FAKE_LAUNCH"; : > "$MONITOR_FAKE_TRACE"
_stub_save quota_identity_read quota_monitor_new_launch_id quota_log
quota_identity_read() { printf 'target@x\037uuid-target\037uuid-target\n'; }
quota_monitor_new_launch_id() { printf 'launch-new\n'; }
quota_log() { printf 'log:%s\n' "$1" >> "$MONITOR_FAKE_TRACE"; }
tmux() {
  local phase last format pane='%71'
  phase=$(cat "$MONITOR_FAKE_PHASE")
  last="${!#}"
  case "${1:-}" in
    has-session) return 0 ;;
    list-panes)
      if [[ "${MONITOR_FAKE_MULTI_PANE:-0}" == '1' ]]; then
        printf '%%71\n%%72\n'
      else
        printf '%%71\n'
      fi
      return 0
      ;;
    display-message)
      format=$last
      if [[ "$format" == *'pane_current_command'* ]]; then
        [[ "$phase" == "shell" || "$phase" == "failed" ]] \
          && printf 'bash\n' || printf 'claude\n'
      elif [[ "$format" == *'pane_id'* ]]; then
        [[ "${MONITOR_FAKE_SWAP_PANE:-0}" == "1" && "$phase" == "shell" ]] && pane='%72'
        printf '4242|%s|9001\n' "$pane"
      elif [[ "$format" == *"$QUOTA_MONITOR_LAUNCH_OPTION"* ]]; then
        cat "$MONITOR_FAKE_LAUNCH"
      else
        printf '4242\n'
      fi
      return 0
      ;;
    capture-pane)
      case "$phase" in
        exit-typed) printf '%s\n' '────────────────' '❯ /exit' ;;
        *) ready_composer_frame ;;
      esac
      return 0
      ;;
    set-option)
      printf '%s\n' "$last" > "$MONITOR_FAKE_LAUNCH"
      printf 'set-launch:%s\n' "$last" >> "$MONITOR_FAKE_TRACE"
      return 0
      ;;
    send-keys)
      if [[ " $* " == *' -l '* ]]; then
        if [[ "$last" == '/exit' ]]; then
          printf 'exit-typed\n' > "$MONITOR_FAKE_PHASE"
          printf 'literal:/exit\n' >> "$MONITOR_FAKE_TRACE"
        elif [[ "$phase" == "shell" ]]; then
          printf 'launch-typed\n' > "$MONITOR_FAKE_PHASE"
          printf 'literal:launch\n' >> "$MONITOR_FAKE_TRACE"
        fi
      elif [[ "$last" == 'C-u' && "$phase" == 'shell' ]]; then
        printf 'clear-shell-line\n' >> "$MONITOR_FAKE_TRACE"
      elif [[ "$last" == 'Enter' ]]; then
        if [[ "$phase" == 'exit-typed' && "${MONITOR_FAKE_EXIT_STUCK:-0}" != '1' ]]; then
          printf 'shell\n' > "$MONITOR_FAKE_PHASE"
          printf 'enter:exit\n' >> "$MONITOR_FAKE_TRACE"
        elif [[ "$phase" == 'launch-typed' ]]; then
          if [[ "${MONITOR_FAKE_LAUNCH_FAIL:-0}" == '1' ]]; then
            printf 'failed\n' > "$MONITOR_FAKE_PHASE"
          else
            printf 'new\n' > "$MONITOR_FAKE_PHASE"
          fi
          printf 'enter:launch\n' >> "$MONITOR_FAKE_TRACE"
        fi
      fi
      return 0
      ;;
    kill-session|new-session)
      printf '%s\n' "$1" >> "$MONITOR_FAKE_TRACE"
      return 0
      ;;
  esac
  return 0
}
sleep() { :; }
SAVED_MONITOR_EXIT_SEC=$QUOTA_MONITOR_EXIT_SEC
SAVED_MONITOR_READY_SEC=$QUOTA_MONITOR_READY_SEC
QUOTA_MONITOR_EXIT_SEC=1
if quota_monitor_exit_to_shell >/dev/null 2>&1 \
   && quota_monitor_launch_in_pane >/dev/null 2>&1 \
   && [[ "$(cat "$MONITOR_FAKE_PHASE")" == 'new' ]] \
   && [[ "$(cat "$MONITOR_FAKE_LAUNCH")" == 'launch-new' ]] \
   && [[ "$(tr '\n' ' ' < "$MONITOR_FAKE_TRACE")" == *'clear-shell-line literal:launch '* ]] \
   && ! grep -qE '^(kill-session|new-session)$' "$MONITOR_FAKE_TRACE"; then
  pass "原 pane 内先清 shell 残留，再完成 /exit→新 cc；tmux 容器身份保持"
else
  fail "原 pane 换代时序失败：$(tr '\n' ' ' < "$MONITOR_FAKE_TRACE")"
fi

printf 'old\n' > "$MONITOR_FAKE_PHASE"; : > "$MONITOR_FAKE_TRACE"
MONITOR_FAKE_EXIT_STUCK=1 QUOTA_MONITOR_EXIT_SEC=0
if quota_monitor_exit_to_shell >/dev/null 2>&1; then
  fail "/exit 未回 shell 仍继续换代"
elif ! grep -q 'literal:launch' "$MONITOR_FAKE_TRACE"; then
  pass "/exit 未回 shell → fail closed，不发送新 cc 启动命令"
else
  fail "/exit 失败后仍向旧 cc 塞了启动命令"
fi
unset MONITOR_FAKE_EXIT_STUCK

printf 'old\n' > "$MONITOR_FAKE_PHASE"; : > "$MONITOR_FAKE_TRACE"
MONITOR_FAKE_SWAP_PANE=1 QUOTA_MONITOR_EXIT_SEC=1
if quota_monitor_exit_to_shell >/dev/null 2>&1; then
  fail "/exit 前后 pane_id 变化仍被当成原 pane 成功"
else
  pass "pane_id/pane_pid/session 任一变化 → 拒绝在未知 pane 启动 cc"
fi
unset MONITOR_FAKE_SWAP_PANE

printf 'shell\n' > "$MONITOR_FAKE_PHASE"; : > "$MONITOR_FAKE_TRACE"
MONITOR_FAKE_LAUNCH_FAIL=1 QUOTA_MONITOR_READY_SEC=0
if quota_monitor_launch_in_pane >/dev/null 2>&1; then
  fail "启动命令立即失败回 shell仍被旧 composer 冒充 ready"
else
  pass "新 cc 未离开 shell → 即使屏上残留 composer 形文字也拒绝绑定"
fi
unset MONITOR_FAKE_LAUNCH_FAIL
QUOTA_MONITOR_READY_SEC=$SAVED_MONITOR_READY_SEC

printf 'old\n' > "$MONITOR_FAKE_PHASE"; : > "$MONITOR_FAKE_TRACE"
MONITOR_FAKE_MULTI_PANE=1
if quota_monitor_exit_to_shell >/dev/null 2>&1; then
  fail "专用 monitor 多出 pane 后仍按漂移的 session target 发送 /exit"
elif ! grep -q 'literal:/exit' "$MONITOR_FAKE_TRACE"; then
  pass "monitor session 非唯一单 pane → fail closed，不向未知 active pane 发键"
else
  fail "多 pane 闸在发送 /exit 之后才生效"
fi
unset MONITOR_FAKE_MULTI_PANE

_stub_save quota_account_guard quota_session_created
quota_account_guard() { QUOTA_GUARD_EMAIL='target@x'; QUOTA_GUARD_UUID='uuid-target'; return 0; }
quota_session_created() { printf '4242\n'; }
QUOTA_STATE="$TMP/monitor-bind-launch-state.json"; QUOTA_CACHE_MTIME=""
printf '%s\n' '{"monitor_launch_id":"launch-old"}' > "$QUOTA_STATE"
printf 'launch-hijacked\n' > "$MONITOR_FAKE_LAUNCH"
if ! quota_monitor_bind_owner bind-test target@x uuid-target launch-new \
      target@x uuid-target >/dev/null 2>&1 \
   && [[ "$(quota_state_get '.monitor_launch_id' '')" == 'launch-old' ]]; then
  pass "owner 只绑定本次 launch 返回的 ID；并发改写 tmux option 时拒绝落盘"
else
  fail "bind 接受了非本次启动的任意 live launch id"
fi

printf 'launch-new\n' > "$MONITOR_FAKE_LAUNCH"
if ! quota_monitor_bind_owner bind-test target@x uuid-target launch-new \
      transient-b@x uuid-b >/dev/null 2>&1 \
   && [[ "$(quota_state_get '.monitor_launch_id' '')" == 'launch-old' ]]; then
  pass "凭据 A→B→A 时拒绝把 B 启动的 cc 绑定成 A（launch-time 身份闭环）"
else
  fail "bind 只核最终文件，接受了启动瞬间属于 B 的 monitor"
fi
_stub_restore quota_account_guard quota_session_created

QUOTA_MONITOR_EXIT_SEC=$SAVED_MONITOR_EXIT_SEC
unset -f sleep; _tmux_guard_install   # 不留裸奔窗口：清桩即重装闸
_stub_restore quota_identity_read quota_monitor_new_launch_id quota_log

echo "── monitor 操作互斥：poll 与人工 restart/ensure 不得同时驱动同一 pane ──"
MONITOR_LOCK_PROBE="$TMP/monitor-lock-probe"
rm -f "$MONITOR_LOCK_PROBE" "$QUOTA_MONITOR_OP_LOCK"
monitor_lock_probe() { printf 'ran\n' >> "$MONITOR_LOCK_PROBE"; }
exec {MONITOR_HELD_FD}> "$QUOTA_MONITOR_OP_LOCK"
flock "$MONITOR_HELD_FD"
if quota_monitor_op_run try monitor_lock_probe >/dev/null 2>&1 \
   && [[ ! -e "$MONITOR_LOCK_PROBE" ]]; then
  pass "人工操作持锁时 poll tick 直接跳过，不交错发送 tmux 按键"
else
  fail "monitor-op 锁未挡住并发 poll"
fi
flock -u "$MONITOR_HELD_FD"; exec {MONITOR_HELD_FD}>&-
if quota_monitor_op_run wait monitor_lock_probe >/dev/null 2>&1 \
   && [[ "$(cat "$MONITOR_LOCK_PROBE" 2>/dev/null)" == 'ran' ]]; then
  pass "锁释放后人工/单轮入口只执行一次完整 monitor 操作"
else
  fail "monitor-op 锁释放后没有正常执行入口"
fi
unset -f monitor_lock_probe

echo "── 陈旧帧自愈：稳定 stale 只允许受控重启一次，冷却期内不循环 ──"
STALE_RECOVERY_TRACE="$TMP/stale-recovery-trace"
: > "$STALE_RECOVERY_TRACE"
QUOTA_STATE="$TMP/stale-recovery-state.json"; QUOTA_CACHE_MTIME=""; echo '{}' > "$QUOTA_STATE"
_stub_save quota_monitor_restart quota_monitor_refresh quota_log
quota_monitor_restart() { printf 'restart:%s:%s\n' "$1" "$2" >> "$STALE_RECOVERY_TRACE"; return 0; }
quota_monitor_refresh() { printf 'refresh:%s\n' "$1" >> "$STALE_RECOVERY_TRACE"; return 0; }
quota_log() { :; }
date() { [[ "$*" == '+%s' ]] && printf '10000\n' || command date "$@"; }
SAVED_STALE_COOLDOWN=${QUOTA_MONITOR_STALE_RESTART_COOLDOWN:-}
QUOTA_MONITOR_STALE_RESTART_COOLDOWN=1800
if declare -F quota_monitor_recover_stale_frame >/dev/null 2>&1 \
   && quota_monitor_recover_stale_frame scheduled 'target@x' 'uuid-target' 6 1 20000 30000 \
   && [[ "$(tr '\n' ' ' < "$STALE_RECOVERY_TRACE")" == \
         'restart:target@x:uuid-target refresh:stale_recovery ' ]] \
   && [[ "$(quota_state_get '.monitor_recovery.last_restart_ts' 0)" == '10000' ]]; then
  pass "稳定 stale 帧先持久化冷却，再原 pane 重启并只追加一次 fresh /usage"
else
  fail "stale 帧没有进入受控单次自愈：$(tr '\n' ' ' < "$STALE_RECOVERY_TRACE")"
fi
: > "$STALE_RECOVERY_TRACE"
if declare -F quota_monitor_recover_stale_frame >/dev/null 2>&1 \
   && ! quota_monitor_recover_stale_frame scheduled 'target@x' 'uuid-target' 6 1 20000 30000 \
   && [[ ! -s "$STALE_RECOVERY_TRACE" ]] \
   && ! quota_monitor_recover_stale_frame stale_recovery 'target@x' 'uuid-target' 6 1 20000 30000; then
  pass "30 分钟冷却与 stale_recovery 模式共同阻断递归重启"
else
  fail "stale 自愈能在同一事故里循环重启：$(tr '\n' ' ' < "$STALE_RECOVERY_TRACE")"
fi
[[ -n "$SAVED_STALE_COOLDOWN" ]] && QUOTA_MONITOR_STALE_RESTART_COOLDOWN=$SAVED_STALE_COOLDOWN || unset QUOTA_MONITOR_STALE_RESTART_COOLDOWN
unset -f date
_stub_restore quota_monitor_restart quota_monitor_refresh quota_log

}

# ── thresholds, cadence, panel sampling / 阈值、节奏、面板采样 ──
run_cadence_tests() {
# ⚠️ Upstream this variable was set by a neighbouring case and simply inherited here.
#    That kind of implicit coupling between cases survives only as long as every
#    neighbour is migrated, and it fails as a **fatal** `unbound variable` under
#    `set -u` — which is loud, but only at the case that inherits, not at the one that
#    was dropped. Set it locally instead.
# ⚠️ 上游这个变量由相邻用例设好、这里直接继承。这种用例之间的隐式耦合，只在「每个邻居
#    都被迁移」时成立；一旦某个邻居没搬，它在 set -u 下是**致命**的未绑定变量——响是响，
#    但响在继承方，不响在被丢掉的那一方。改成本地取值。
SCHED_NOW=$(date +%s)
echo "── 两个窗口各自的阈值（五小时 90 / 周 99）──"
# 用户 2026-08-13 拍板：五小时由 96 下调到 94、周仍为 99。两者不只烧速差一个数量级（五小时实测峰值
# 1.3%/分钟，周 ~0.2%/分钟），单位价值也差一个数量级——按实测换算常数 0.120，
# **1 个周额度点 ≈ 8.3 个五小时点**。所以五小时要多留（留 4 点才够从容切号），
# 周额度要尽量少留（每早 1 点就扔掉 8.3 个五小时点的产能）。
# ⚠️ 上游这里还钉住第三个数：一条**严格低于**切换线的「接受线」（five 89 / week 99），
#    存在的理由是防来回切——接纳一个恰好在线上的候选，下一轮又把它切走。
#    🔴 本仓没有这条线：切号那一半是重写的，quota_switch_pick 用同一个
#    QUOTA_SWITCH_PCT_* 既当切走线又当接纳线。⇒ 防抖余量从「至少 2 点」变成
#    「恰好 1 点」：一个 five=89 的候选会被接纳，而它离 90 只差 1 点。
#    这不是迁移时丢的，是切号那一半重写时的既有差异；这里把它**测出来并写下来**，
#    而不是让它以「上游有一条断言、本仓没有」的形式消失。
if [[ "$QUOTA_SWITCH_PCT_FIVE" == "90" && "$QUOTA_SWITCH_PCT_WEEK" == "99" ]]; then
  pass "阈值配置：五小时切换线 90 / 周切换线 99"
else
  fail "阈值配置错误（five=$QUOTA_SWITCH_PCT_FIVE week=$QUOTA_SWITCH_PCT_WEEK）"
fi
# 把「接纳线 = 切换线」这个事实钉成断言：恰好差 1 点的候选会被接纳，等于线上的不会。
QUOTA_STATE="$TMP/accept-line-state.json"
cat > "$QUOTA_STATE" <<JSON
{"account":"cur@x","accounts":{
  "cur@x":{"five":95,"week":10},
  "edge@x":{"five":$(( QUOTA_SWITCH_PCT_FIVE - 1 )),"week":10},
  "over@x":{"five":$QUOTA_SWITCH_PCT_FIVE,"week":10}}}
JSON
picked=$(quota_switch_pick "cur@x" || echo "")
if [[ "$picked" == "edge@x" ]]; then
  pass "接纳线 = 切换线：five=$(( QUOTA_SWITCH_PCT_FIVE - 1 )) 被接纳，防抖余量只有 1 点（与上游的两点不同，已记）"
else
  fail "候选接纳边界不是「切换线减一」（picked=${picked:-none}）"
fi
cat > "$QUOTA_STATE" <<JSON
{"account":"cur@x","accounts":{
  "cur@x":{"five":95,"week":10},
  "over@x":{"five":$QUOTA_SWITCH_PCT_FIVE,"week":10}}}
JSON
if picked2=$(quota_switch_pick "cur@x"); then
  fail "正好在切换线上的候选被接纳了（picked=$picked2），那会当场再切走"
else
  pass "正控：候选恰好在切换线上时不被接纳，上一条不是恒真"
fi
# 弱证据横幅要拿百分比交叉验证，正好用它验两个窗口是各比各的
mk_json() {  # $1=five $2=week
  export QUOTA_CLAUDE_JSON="$TMP/thr.json"
  cat > "$QUOTA_CLAUDE_JSON" <<JSON
{"oauthAccount":{"emailAddress":"t@x"},
 "cachedUsageUtilization":{"fetchedAtMs":$(( $(date +%s) * 1000 )),"accountUuid":"u",
  "utilization":{"five_hour":{"utilization":$1,"resets_at":null},
                 "seven_day":{"utilization":$2,"resets_at":null}}}}
JSON
}
mk_json 90 50
if quota_banner_confirmed "$(read_fx banner-weak.txt)" "$(date +%s)"; then
  pass "five=90% 触五小时阈值 90（周才 50% 也算数）"
else
  fail "five=90% 没触发五小时阈值 90"
fi
# ⚠️ 五小时线 2026-08-19 降到 90 后，这里的 five 取值必须跟着降：原来用 90 表示
#    "还没到线"，现在 90 本身就是线上，这条会变成测反了。
mk_json 85 97
if quota_banner_confirmed "$(read_fx banner-weak.txt)" "$(date +%s)"; then
  fail "five=85%/week=97% 都不到各自阈值（90/99），不该触发"
else
  pass "five=85%/week=97% 两边都不到各自阈值 → 不触发"
fi
mk_json 85 98
if quota_banner_confirmed "$(read_fx banner-weak.txt)" "$(date +%s)"; then
  fail "week=98% 不该触发（周阈值已从 98 上调到 99）"
else
  pass "week=98% 不触发（边界：99 才触发，98 差一点）"
fi

echo "── /usage 网络频率：按更紧张窗口的剩余额度走 60/300/600 秒 ──"
if declare -F quota_usage_interval_for_values >/dev/null 2>&1 \
   && [[ "$(quota_usage_interval_for_values 10 20)" == "600" ]] \
   && [[ "$(quota_usage_interval_for_values 50 20)" == "300" ]] \
   && [[ "$(quota_usage_interval_for_values 79 20)" == "300" ]] \
   && [[ "$(quota_usage_interval_for_values 80 20)" == "60" ]] \
   && [[ "$(quota_usage_interval_for_values 20 94)" == "60" ]] \
   && [[ "$(quota_usage_interval_for_values nope 20)" == "60" ]]; then
  pass "剩余 >50%=600s、21–50%=300s、≤20%=60s；任一窗口紧张即收紧，未知 fail-safe 到 60s"
else
  fail "/usage 频率分档缺失或没有按两个窗口中更紧张的一维计算"
fi
if declare -F quota_usage_backoff_interval >/dev/null 2>&1 \
   && [[ "$(quota_usage_backoff_interval 60)" == "300" ]] \
   && [[ "$(quota_usage_backoff_interval 300)" == "600" ]] \
   && [[ "$(quota_usage_backoff_interval 600)" == "600" ]]; then
  pass "高频请求不可信/受限后按 60→300→600 退避，600s 封顶"
else
  fail "/usage 失败退避不是 60→300→600"
fi

echo "── /usage 面板可信度：刷新中、限流、last-known 与刷新失败整帧拒绝 ──"
PANEL_OK=$'Current session\n  12% used\n  Resets 5:00pm (Asia/Shanghai)\nCurrent week (all models)\n  34% used\n  Resets Aug 20, 5:00pm (Asia/Shanghai)'
PANEL_DETAIL=$'   Settings  Status   Config   Usage   Stats\n\n   What is contributing to your limits usage?\n   Last 24h · these are independent characteristics of your usage\n   88% of your usage was at >150k context'
if declare -F quota_panel_frame_status >/dev/null 2>&1 \
   && [[ "$(quota_panel_frame_status "$PANEL_OK")" == "clean" ]] \
   && [[ "$(quota_panel_frame_status "$PANEL_OK\nRefreshing…")" == "refreshing" ]] \
   && [[ "$(quota_panel_frame_status "$PANEL_OK\nUsage endpoint is rate limited. Press r to retry")" == "rate_limited" ]] \
   && [[ "$(quota_panel_frame_status "$PANEL_OK\nShowing last-known usage")" == "last_known" ]] \
   && [[ "$(quota_panel_frame_status "$PANEL_OK\nCould not refresh usage data")" == "refresh_failed" ]]; then
  pass "只有无污染的完整面板为 clean；带旧百分比的错误/刷新帧也不会进入决策"
else
  fail "/usage 面板缺少整帧可信度闸，可能把错误页上的旧百分比当实时值"
fi
if [[ "$(quota_panel_frame_status "$PANEL_DETAIL")" == "panel_detail" ]]; then
  pass "额度区块被归因分析滚出可见区时仍识别为 Usage 面板，不会提前触网重开"
else
  fail "常驻 Usage 页的归因详情被误判为面板关闭，会绕过 next_due 提前重发 /usage"
fi

echo "── 流速自适应：涨得快就多看几眼，但只收紧不放宽 ──"
# 2026-08-19 11:40 实撞：11:35:39 面板 77% → 11:40:52 面板 100%。77% 按水位是 300 秒档，
# 而从 77% 涨到切换线 94% 只要 3.9 分钟——间隔比到线时间还长，必然漏过。结果切号发生在
# 100%，6 个会话在切号前就撞了墙，预防性切号退化成事后补救。
# 上游这里给 quota_banner_pressure 打了桩，因为流速档与「屏上横幅」提速源共用一个
# 出口。本仓没有那个提速源（它读的是那套环境里全部会话的屏幕留档，未抽取），
# quota_usage_interval_adaptive 只剩流速这一条，所以不需要打桩——但也就意味着**这一组
# 现在覆盖的是全部提速源，而不是四分之一**。

RATE_FAIL=0
_rate() {  # _rate <期望> <说明> <five> <week> <prev_five> <prev_week> <prev_ts> <now> <prev_email> <cur_email>
  local want="$1" label="$2"; shift 2
  local got; got=$(quota_usage_interval_adaptive "$@")
  [[ "$got" == "$want" ]] && return 0
  printf '     %-34s 期望 %s 实际 %s\n' "$label" "$want" "$got"; RATE_FAIL=$((RATE_FAIL+1))
}
# 真实数字：上次 five=0%（t=1000），这次 five=77%（t=1620）。
# ⚠️ 切换线 2026-08-19 从 94 降到 90 之后，同一场景算出来是 (90-77)*620/77/2≈52s，
#    低于地板价，所以结果是 60 —— 两项改动叠加的效果：查得更勤 + 线更低，双重余量。
#    （按旧的 94 线算是 68s，这个数留在注释里做对照。）
_rate 60  "实撞那次：300s → 60s（撞地板）" 77 47 0  39 1000 1620 a@x a@x
# 再来一条不撞地板的，单独验流速算式本身：600s 内涨 30 点 → 到 90 线还需 400s，取一半
_rate 200 "中速上涨：300s → 200s（未撞地板）" 70 20 40 15 1000 1600 a@x a@x
# 只收紧不放宽：水位档永远是上界
_rate 300 "慢涨不收紧（水位档 300 封顶）" 50 20 40 19 1000 1600 a@x a@x
# 跨账号不能算流速：旧账号 100% → 新账号 0%，算出来是负的
_rate 300 "跨账号（切号那轮）不算流速"   0  51 100 49 1000 1620 old@x new@x
# 百分比掉下来是窗口重置，不是流速
_rate 600 "窗口重置导致下降，不当流速"   5  49 100 49 1000 1620 a@x a@x
# 没有上一次读数
_rate 300 "无 prev 时回落到水位档"       77 47 "" "" "" 1620 a@x a@x
# 地板价：再快也不低于 60s
_rate 60  "极快上涨仍不低于地板 60s"     93 10 0  5  1000 1010 a@x a@x
if (( RATE_FAIL == 0 )); then
  pass "流速自适应六种情形全部正确（含跨账号/窗口重置两种不该收紧的）"
else
  fail "$RATE_FAIL 种情形算错"
fi

# ⚠️ 开关必须真能关掉：留一个 env 后门，出问题时不用改代码就能退回旧行为。
QUOTA_RATE_ADAPTIVE=0
RATE_OFF=$(quota_usage_interval_adaptive 77 47 0 39 1000 1620 a@x a@x)
QUOTA_RATE_ADAPTIVE=1
if [[ "$RATE_OFF" == "300" ]]; then
  pass "QUOTA_RATE_ADAPTIVE=0 时退回纯水位档（有可回退的后门）"
else
  fail "关掉开关后行为没退回旧逻辑（得到 $RATE_OFF）"
fi

echo "── 0% inactive：无 Resets 可写 null，连续 TAB 不得把周 reset 错位 ──"
PANEL_INACTIVE=$'Current session\n  0% used\n\nCurrent week (all models)\n  34% used\n  Resets Aug 20, 5:00pm (Asia/Shanghai)'
if inactive_row=$(quota_panel_parse "$PANEL_INACTIVE") \
   && [[ "$(quota_panel_field "$inactive_row" 1)" == "0" ]] \
   && [[ -z "$(quota_panel_field "$inactive_row" 3)" ]] \
   && [[ "$(quota_panel_field "$inactive_row" 4)" == *'Aug 20'* ]] \
   && [[ "$(quota_window_reset_for_write 0 '' "$SCHED_NOW" "$QUOTA_SESSION_WINDOW_HORIZON")" == "null" ]] \
   && ! quota_window_reset_for_write 1 '' "$SCHED_NOW" "$QUOTA_SESSION_WINDOW_HORIZON" >/dev/null 2>&1; then
  pass "0%/无 reset 明确记为 inactive(null)；非 0 缺 reset 仍拒绝，四字段不串列"
else
  fail "0% 无 reset 被误拒或 TAB 空列让周 reset 错归到五小时窗口"
fi

rm -f "$QUOTA_PANEL_OBSERVATIONS"
quota_panel_log_observation "$SCHED_NOW" 'sched@x' 'uuid-s' local_sample clean "$PANEL_OK"
if jq -e --arg raw "$PANEL_OK" '
     .source=="usage_panel_screen" and .mode=="local_sample" and .status=="clean"
     and .account.email=="sched@x" and .cadence.local_sample_seconds==10
     and .panel_text==$raw and (.panel_sha256|length)==64' \
     "$QUOTA_PANEL_OBSERVATIONS" >/dev/null 2>&1; then
  pass "每次本地采样保留账号、时刻、档位、解析值、SHA 与可见面板原文"
else
  fail "10s 面板观测日志缺原始画面或频率/账号字段"
fi

echo "── 原始整屏日志：滚动保留七天，低频清理且不误删坏行 ──"
RETENTION_NOW=2000000
RETENTION_CUTOFF=$(( RETENTION_NOW - 604800 ))
cat > "$QUOTA_PANEL_OBSERVATIONS" <<JSON
{"schema":1,"source":"usage_panel_screen","observed_at":$(( RETENTION_CUTOFF - 1 )),"tag":"expired"}
{"schema":1,"source":"usage_panel_screen","observed_at":$RETENTION_CUTOFF,"tag":"boundary"}
{"schema":1,"source":"usage_panel_screen","observed_at":$(( RETENTION_NOW - 1 )),"tag":"recent"}
{"schema":2,"source":"usage_panel_screen","observed_at":$(( RETENTION_CUTOFF - 2 )),"tag":"unknown-schema"}
{"schema":1,"source":"usage_panel_screen","observed_at":"$(( RETENTION_CUTOFF - 3 ))","tag":"wrong-ts-type"}
not-json-preserve-me
JSON
rm -f "$QUOTA_PANEL_PRUNE_STAMP"
quota_panel_log_observation "$RETENTION_NOW" 'retention@x' 'uuid-r' local_sample clean "$PANEL_OK"
if [[ "${QUOTA_PANEL_RETENTION_SEC:-}" == "604800" \
      && "${QUOTA_PANEL_PRUNE_INTERVAL:-}" == "86400" ]] \
   && ! grep -q '"tag":"expired"' "$QUOTA_PANEL_OBSERVATIONS" \
   && grep -q '"tag":"boundary"' "$QUOTA_PANEL_OBSERVATIONS" \
   && grep -q '"tag":"recent"' "$QUOTA_PANEL_OBSERVATIONS" \
   && grep -q '"tag":"unknown-schema"' "$QUOTA_PANEL_OBSERVATIONS" \
   && grep -q '"tag":"wrong-ts-type"' "$QUOTA_PANEL_OBSERVATIONS" \
   && grep -q '^not-json-preserve-me$' "$QUOTA_PANEL_OBSERVATIONS" \
   && jq -Rse --argjson now "$RETENTION_NOW" '
        split("\n") | map(try fromjson catch null)
        | any(.observed_at==$now and .account.email=="retention@x")' \
        "$QUOTA_PANEL_OBSERVATIONS" >/dev/null 2>&1 \
   && [[ "$(stat -c %a "$QUOTA_PANEL_OBSERVATIONS")" == "600" ]] \
   && [[ "$(cat "$QUOTA_PANEL_PRUNE_STAMP" 2>/dev/null)" == "$RETENTION_NOW" ]]; then
  pass "首次到期清理只删除七天前的有效帧，边界/坏行/本轮新帧均保留"
else
  fail "整屏日志没有落实七天保留，或清理误删了边界/坏行/新帧"
fi

printf '{"schema":1,"source":"usage_panel_screen","observed_at":%s,"tag":"throttled-old"}\n' \
  "$(( RETENTION_CUTOFF - 2 ))" >> "$QUOTA_PANEL_OBSERVATIONS"
quota_panel_log_observation "$(( RETENTION_NOW + QUOTA_PANEL_PRUNE_INTERVAL - 1 ))" \
  'retention@x' 'uuid-r' local_sample clean "$PANEL_OK"
if grep -q '"tag":"throttled-old"' "$QUOTA_PANEL_OBSERVATIONS" \
   && [[ "$(cat "$QUOTA_PANEL_PRUNE_STAMP" 2>/dev/null)" == "$RETENTION_NOW" ]]; then
  pass "每日清理周期内只追加不重扫整份大日志"
else
  fail "整屏日志清理没有按每日周期节流"
fi
quota_panel_log_observation "$(( RETENTION_NOW + QUOTA_PANEL_PRUNE_INTERVAL ))" \
  'retention@x' 'uuid-r' local_sample clean "$PANEL_OK"
if ! grep -q '"tag":"throttled-old"' "$QUOTA_PANEL_OBSERVATIONS" \
   && [[ "$(cat "$QUOTA_PANEL_PRUNE_STAMP" 2>/dev/null)" == "$(( RETENTION_NOW + QUOTA_PANEL_PRUNE_INTERVAL ))" ]]; then
  pass "清理间隔到期后再次滚动删除过期帧"
else
  fail "整屏日志到期后没有再次执行滚动清理"
fi

if (
  QUOTA_PANEL_OBSERVATIONS="$TMP/quota-panel-observations.atomic.jsonl"
  QUOTA_PANEL_PRUNE_STAMP="$TMP/quota-panel-observations.atomic.prune-ts"
  printf '%s\n' \
    "{\"schema\":1,\"source\":\"usage_panel_screen\",\"observed_at\":$(( RETENTION_CUTOFF - 1 )),\"tag\":\"must-survive\"}" \
    "{\"schema\":1,\"source\":\"usage_panel_screen\",\"observed_at\":$RETENTION_NOW,\"tag\":\"recent\"}" \
    > "$QUOTA_PANEL_OBSERVATIONS"
  before=$(sha256sum "$QUOTA_PANEL_OBSERVATIONS" | awk '{print $1}')
  mv() {
    local dest="${@: -1}"
    [[ "$dest" == "$QUOTA_PANEL_OBSERVATIONS" ]] && return 1
    command mv "$@"
  }
  declare -F quota_panel_observations_prune_if_due >/dev/null \
    && ! quota_panel_observations_prune_if_due "$RETENTION_NOW" \
    && [[ "$(sha256sum "$QUOTA_PANEL_OBSERVATIONS" | awk '{print $1}')" == "$before" ]] \
    && ! compgen -G "${QUOTA_PANEL_OBSERVATIONS}.prune.*" >/dev/null
); then
  pass "整屏日志 atomic rename 失败时原文件不变且临时文件已清理"
else
  fail "整屏日志清理失败破坏原文件或遗留临时文件"
fi
mk_json 90 99
if quota_banner_confirmed "$(read_fx banner-weak.txt)" "$(date +%s)"; then
  pass "week=99% 触周阈值 99"
else
  fail "week=99% 没触发周阈值"
fi
unset QUOTA_CLAUDE_JSON; unset -f mk_json

echo "── 陈旧帧：窗口身份优先，不能只看单调性 ──"
# 2026-08-11 事故的两条真实序列都**不是回退**，而是旧窗口的高值回来了：
#   Faith   19:49:53 five=97%(旧窗口) → 19:50:13 five=0%(真 reset) → 19:50:31 five=97%(旧窗口)
#   Michael 21:10:09 five=0%(真 reset) → 21:10:28 five=99%(旧窗口)
# 97>0 是上涨，纯单调性判据一条都拦不住；两次都因此错切账号，第二次把 waiting 推到 24h 后。
QUOTA_STATE="$TMP/frame-state.json"; QUOTA_CACHE_MTIME=""
NOW_T=$(date +%s)
SR_NEW=$(( NOW_T + 17000 ))    # 新窗口：reset 还在未来
SR_OLD=$(( NOW_T - 600 ))      # 旧窗口：reset 已过（视界钳制会解析成这种过去 epoch）
WR=$(( NOW_T + 100000 ))
mk_last() {  # $1=account $2=five $3=week $4=five_reset $5=week_reset
  cat > "$QUOTA_STATE" <<JSON
{"account":"$1","five_hour":$2,"seven_day":$3,"five_reset_ts":$4,"week_reset_ts":$5}
JSON
}

# ── 事故序列 1：Faith 97 → 0 → 97 ──
mk_last "faith@x" 0 11 "$SR_NEW" "$WR"          # 已确认：真 reset 后的 0%
if quota_frame_stale "faith@x" 97 10 "$SR_OLD" "$WR"; then
  pass "Faith 97%(已过期窗口) 在 0%(新窗口) 之后回来 → 判陈旧（事故序列 1）"
else
  fail "没拦住事故序列 1——这正是 19:50:31 那次错切的原因"
fi
# ── 事故序列 2：Michael 0 → 99 ──
mk_last "m@x" 0 88 "$SR_NEW" "$WR"
if quota_frame_stale "m@x" 99 87 "$SR_OLD" "$WR"; then
  pass "Michael 99%(已过期窗口) 在 0% 之后回来 → 判陈旧（事故序列 2）"
else
  fail "没拦住事故序列 2"
fi
# ⚠️ 隔离「窗口已过期」这条规则：上面两条序列同时命中「比上次更旧」，所以即使删掉
# 过期规则也照样红不了（破坏性验证实测红 0 条）。真正只有它能救的场景是**切号后第一次
# 读新账号**——没有可比的历史读数，此时若面板给的是上一个窗口的缓存帧，只能靠 reset
# 落在过去来识别。
mk_last "someone-else@x" 50 50 "$SR_NEW" "$WR"
if quota_frame_stale "brandnew@x" 97 10 "$SR_OLD" "$WR"; then
  pass "无同账号历史时，仅凭 reset 已过去即判陈旧（切号后第一读的唯一防线）"
else
  fail "切号后第一读会收下已过期窗口的缓存帧"
fi

# ⚠️ 基准本身可能是坏的。2026-08-12 11:38 活体实撞：state 里存着旧 buggy 代码写下的
# five_reset_ts=08-13 02:10（距今 14.5h，五小时窗口不可能这么远），于是面板的**真值**
# 08-12 12:10 被判成"更旧的窗口"，新 poller 每一帧都被拒、读数彻底进不来。
# 基准要用同一条物理事实先校验：超出 5h 视界或已过去 → 当没有基准。
BAD_SR=$(( NOW_T + 52200 ))     # 14.5 小时后——不可能是五小时窗口
mk_last "f@x" 0 10 "$BAD_SR" "$WR"
if quota_frame_stale "f@x" 20 14 "$(( NOW_T + 1800 ))" "$WR"; then
  fail "坏基准（$(date -d @$BAD_SR '+%m-%d %H:%M')）把真值判成陈旧 → 读数会彻底进不来"
else
  pass "基准超出 5h 视界 → 当没有基准，真值照常采信"
fi
mk_last "f@x" 0 10 "$(( NOW_T - 3600 ))" "$WR"
if quota_frame_stale "f@x" 20 14 "$(( NOW_T + 1800 ))" "$WR"; then
  fail "已过去的基准仍被用来比较"
else
  pass "基准已过去（窗口早结束）→ 当没有基准"
fi

# ⚠️ 基准过期时，百分比要跟 reset 一起作废。2026-08-12 12:19 实撞：Faith 12:10 重置后
# state 里还留着旧窗口的 five=100（reset 已过），新窗口真值 20% 被「100→20 回退」拒掉，
# 读数饿死——只作废基准的 reset、留着它的百分比做单调性比较，等于让死窗口继续否决活窗口。
# 帧的 week 给 25（不回退）：这条用例只考「五小时维度的死基准」。当天真实的 20/14 帧
# 其实 week 也回退了，它被拒是对的——真正饿死读数的是后来 19/25 那类帧的 five 维度。
mk_last "f@x" 100 23 "$(( NOW_T - 300 ))" "$WR"     # 基准：reset 五分钟前已过
if quota_frame_stale "f@x" 20 25 "$(( NOW_T + 17000 ))" "$WR"; then
  fail "死窗口的 100% 否决了新窗口的真值 20%（当天 12:19 读数饿死那一幕）"
else
  pass "基准 reset 已过 → 其百分比一并作废，新窗口 20% 正常采信"
fi

# 单调性那一路仍要保住（当天 Michael 94→0、Paula 21→7 那两组）
mk_last "m@x" 94 88 "$SR_NEW" "$WR"
if quota_frame_stale "m@x" 0 88 "$SR_NEW" "$WR"; then
  pass "同窗口内 94%→0% 回退 → 判陈旧"
else
  fail "没识别同窗口回退"
fi
mk_last "p@x" 21 95 "$SR_NEW" "$WR"
if quota_frame_stale "p@x" 7 94 "$SR_NEW" "$WR"; then
  pass "同窗口内 21%→7% 回退 → 判陈旧（当天 Paula 那一组）"
else
  fail "没识别 Paula 那组回退"
fi
# 真 reset 后合法归零必须放行，否则永远拒绝重置后的真值
mk_last "m@x" 98 88 "$(( NOW_T + 60 ))" "$WR"
if quota_frame_stale "m@x" 0 88 "$SR_NEW" "$WR"; then
  fail "真 reset 后的合法归零被误判 → 会永远拒绝新窗口读数"
else
  pass "真 reset（窗口 reset 时刻前移到新的未来值）后归零 → 采信"
fi
# 账号不同不可比
mk_last "m@x" 98 88 "$SR_NEW" "$WR"
if quota_frame_stale "other@x" 0 5 "$SR_NEW" "$WR"; then
  fail "不同账号之间不该比较"
else
  pass "账号不同 → 不适用（切号后第一读本就是另一账号的独立读数）"
fi
# reset 拿不到 + 回退 → fail closed
mk_last "m@x" 94 88 "$SR_NEW" "$WR"
if quota_frame_stale "m@x" 0 88 "" ""; then
  pass "reset 时刻不可得 + 回退 → fail closed 当陈旧帧"
else
  fail "reset 未知时应保守判陈旧"
fi
# 正常上涨必须放行
mk_last "m@x" 90 88 "$SR_NEW" "$WR"
if quota_frame_stale "m@x" 91 88 "$SR_NEW" "$WR"; then
  fail "正常上涨被误判 → 会拒绝一切真值"
else
  pass "同窗口内上涨 → 正常采信"
fi

echo "── reset 分钟抖动：同一窗口允许相差 5 分钟，不能颠倒新旧帧 ──"
# 2026-08-13 活体：同一次 r 刷新交替显示 Boyce 62/35 @ 4:00/14:00（缓存）与
# 77/37 @ 3:59/13:59（新鲜）。两个来源对同一 reset 的分钟取整相差 60s；若精确比较
# epoch，真帧会因 reset 早一分钟被拒，缓存又会因 reset 晚一分钟冒充“新窗口”。
# 用户随后补充，服务端/UI 的同窗 reset 还可能相差几分钟；容差扩为 5 分钟。真正换窗会
# 跳约 5h/7d，远大于 5 分钟；容差内仍必须服从百分比单调性，不能让低值缓存借机混入。
if declare -F quota_reset_same_window >/dev/null 2>&1 \
   && quota_reset_same_window "$SR_NEW" "$((SR_NEW-300))" \
   && quota_reset_same_window "$WR" "$((WR+300))" \
   && ! quota_reset_same_window "$SR_NEW" "$((SR_NEW-301))"; then
  pass "reset 相差不超过 5 分钟归为同窗，超过容差仍区分窗口"
else
  fail "reset 同窗容差不是 5 分钟"
fi
mk_last "boyce@x" 66 36 "$SR_NEW" "$WR"
if quota_frame_stale "boyce@x" 77 37 "$((SR_NEW-240))" "$((WR-240))"; then
  fail "新鲜 77/37 因 reset 早 4 分钟被错拒"
else
  pass "同窗 reset 早 4 分钟但用量上涨 → 采信新鲜帧"
fi
mk_last "boyce@x" 77 37 "$((SR_NEW-240))" "$((WR-240))"
if quota_frame_stale "boyce@x" 62 35 "$SR_NEW" "$WR"; then
  pass "同窗 reset 晚 4 分钟但用量回退 → 仍判缓存陈旧"
else
  fail "62/35 缓存借 reset 晚 4 分钟冒充新窗口"
fi
mk_last "boyce@x" 66 36 "$SR_NEW" "$WR"
if quota_frame_stale "boyce@x" 99 99 "$((SR_NEW-301))" "$((WR-301))"; then
  pass "超过 5 分钟的更旧 reset 即使百分比更高也仍判陈旧"
else
  fail "reset 容差放得过宽，吞掉了真正更旧的窗口"
fi
if declare -F quota_panel_sample_better >/dev/null 2>&1 \
   && quota_panel_sample_better "$((SR_NEW-240))" 77 37 "$SR_NEW" 66 36 \
   && ! quota_panel_sample_better "$SR_NEW" 66 36 "$((SR_NEW-240))" 77 37 \
   && quota_panel_sample_better "$((SR_NEW+301))" 0 37 "$SR_NEW" 99 37 \
   && ! quota_panel_sample_better "$((SR_NEW-301))" 99 99 "$SR_NEW" 66 36; then
  pass "单轮交错采样始终选同窗高值，只有明确新窗口才允许归零"
else
  fail "单轮 best-frame 仍会被几分钟 reset 抖动颠倒"
fi
if quota_panel_sample_better "" 0 37 "$((NOW_T-1))" 99 37 "$WR" "$WR" \
   && ! quota_panel_sample_better "" 0 37 "$SR_NEW" 99 37 "$WR" "$WR" \
   && quota_panel_sample_better "$SR_NEW" 2 0 "$SR_NEW" 2 99 "" "$((NOW_T-1))" \
   && quota_panel_sample_better "$SR_NEW" 2 37 "" 0 37 "$WR" "$WR" \
   && ! quota_panel_sample_better "$((NOW_T-1))" 99 37 "" 0 37 "$WR" "$WR"; then
  pass "单轮选帧分别识别五小时/周窗口的 0% inactive；只在旧 reset 到期后允许无 reset 归零"
else
  fail "0%/无 reset 与旧高值交错时仍会选错窗口"
fi

echo "── reset 解析：五小时窗口的跨日回卷必须被钳制 ──"
# 事故的根因之一：19:50:31 那帧写 `Resets 7:50pm`，而 19:50 刚过去，裸解析 +86400 变成
# **明天 19:50**，比真帧的今天 00:50 还晚 → 「按 reset 比新旧」完全失效。
# ⚠️ 必须锁 LC_ALL=C：date 的 %P/%b 是**跟随 locale** 的，本机中文环境下 `%P` 输出
#    「下午」而不是「pm」，喂给解析器就是一个现实中根本不会出现的字符串——
#    cc 面板永远是英文。不锁的话这几条用例测的不是生产逻辑，而是本机 locale，
#    且失败文案会显示成解析器坏了，把人引向错误方向。
NOWHM=$(LC_ALL=C TZ=CST-8 date '+%-I:%M%P')          # 取「刚刚过去」的那个时刻文案
PAST_LINE="Resets $(LC_ALL=C TZ=CST-8 date -d '-2 minutes' '+%-I:%M%P') (Asia/Shanghai)"
naive=$(quota_panel_reset_epoch "$PAST_LINE" || echo "")
clamped=$(quota_panel_reset_epoch "$PAST_LINE" "$QUOTA_SESSION_WINDOW_HORIZON" || echo "")
if [[ "$naive" =~ ^[0-9]+$ ]] && (( naive > NOW_T + 80000 )); then
  pass "不加视界时确实回卷到约 24h 后（复现原缺陷，got $(date -d "@$naive" '+%m-%d %H:%M')）"
else
  fail "没复现回卷（naive=$naive）"
fi
if [[ "$clamped" =~ ^[0-9]+$ ]] && (( clamped < NOW_T )); then
  pass "加 5h 视界后还原成已过去的时刻 → 调用方能看出窗口已过期"
else
  fail "视界钳制没生效（clamped=$clamped）"
fi
: "${NOWHM:-}"
unset -f mk_last

}

# ── the reading round and its write gates / 读数主轮与写入闸 ──
# ⚠️ Upstream this function was `quota_read_once`; here the reading half is
#    `quota_read_once` and the switching half hangs off the seam at its end. Every
#    call below is renamed accordingly. Stubs for functions that no longer exist
#    (`quota_reap_dead_sessions`, `quota_after_recovery` — session reaping and the
#    resume-delivery chain, neither extracted) are harmless no-ops and are kept so the
#    diff against the upstream case stays readable.
# ⚠️ 上游这个函数叫 quota_read_once；本仓读数那一半叫 quota_read_once，切号那一半挂在它
#    末尾的接缝上。下面的调用一律照此改名。对本仓已不存在的函数打的桩
#    （quota_reap_dead_sessions / quota_after_recovery——会话回收与复工投递链，两者都
#    未抽取）是无害空转，保留它们是为了与上游用例的 diff 仍然读得出来。
run_reading_round_tests() {
export QUOTA_CLAUDE_JSON="$TMP/poll-round.json"
QUOTA_STATE="$TMP/poll-round-state.json"; QUOTA_CACHE_MTIME=""
echo "── 主轮询：发现账号漂移后不得重启监控并把旧账号读数收编进 state ──"
cat > "$QUOTA_STATE" <<'JSON'
{"phase":"normal","account":"target@x",
 "account_guard":{"expected_email":"target@x","expected_uuid":"uuid-target"}}
JSON
cat > "$QUOTA_CLAUDE_JSON" <<'JSON'
{"oauthAccount":{"emailAddress":"old@x","accountUuid":"uuid-old"},
 "cachedUsageUtilization":{"accountUuid":"uuid-old"}}
JSON
POLL_MONITOR_MARK="$TMP/account-drift-monitor-called"
rm -f "$POLL_MONITOR_MARK"
if (
  quota_reap_dead_sessions() { :; }
  quota_monitor_refresh() { : > "$POLL_MONITOR_MARK"; return 1; }
  quota_read_once >/dev/null 2>&1
); then
  drift_poll_rc=0
else
  drift_poll_rc=$?
fi
if (( drift_poll_rc != 0 )) && [[ ! -e "$POLL_MONITOR_MARK" ]] \
   && [[ "$(quota_state_get '.account' '')" == "target@x" ]]; then
  pass "主轮询在账号漂移处止步，没有静默跟随旧账号"
else
  fail "主轮询未在账号漂移处止步（rc=$drift_poll_rc monitor_called=$([[ -e "$POLL_MONITOR_MARK" ]] && echo yes || echo no)）"
fi

echo "── 主轮询归属：必须消费 guard 同一快照，不能通过后再读一次身份 ──"
QUOTA_STATE="$TMP/poll-same-snapshot.json"; QUOTA_CACHE_MTIME=""
echo '{}' > "$QUOTA_STATE"
if (
  quota_account_guard() {
    QUOTA_GUARD_EMAIL='target@x'
    QUOTA_GUARD_UUID='uuid-target'
    return 0
  }
  quota_reap_dead_sessions() { return 0; }
  quota_monitor_refresh() { QUOTA_PANEL_LAST=$'20\t30\tfive-good\tweek-good'; return 0; }
  quota_panel_reset_epoch() {
    [[ -n "${2:-}" ]] && echo $(( $(date +%s) + 1800 )) || echo $(( $(date +%s) + 604800 ))
  }
  # 模拟 guard 通过后旧 writer 才把文件完整盖成另一个内部自洽的账号。
  quota_identity_read() { printf 'old@x\037uuid-old\037uuid-old\n'; }
  quota_ratio_update() { :; }
  quota_capacity_update() { :; }
  quota_after_recovery() { :; }
  quota_read_once >/dev/null 2>&1
); then
  poll_snapshot_rc=0
else
  poll_snapshot_rc=$?
fi
if (( poll_snapshot_rc == 0 )) \
   && [[ "$(quota_state_get '.account' '')" == "target@x" ]] \
   && [[ "$(quota_state_get '.uuid' '')" == "uuid-target" ]]; then
  pass "面板值归给 guard 已确认的同一快照，未被第二次读取改写归属"
else
  fail "guard 后另读身份重新打开 TOCTOU（rc=$poll_snapshot_rc account=$(quota_state_get '.account' '')）"
fi
unset QUOTA_CLAUDE_JSON

echo "── 双时钟：未到网络 due 只做 10s 本地处理，不重复进入决策 ──"
SCHED_NOW=$(date +%s)
QUOTA_STATE="$TMP/usage-schedule.json"; QUOTA_CACHE_MTIME=""
cat > "$QUOTA_STATE" <<JSON
{"account":"sched@x","uuid":"uuid-s","five_hour":80,"seven_day":10,
 "monitor_session_created":111,"monitor_launch_id":"launch-111",
 "usage_refresh":{"account":"sched@x","uuid":"uuid-s","monitor_generation":111,
                  "monitor_launch_id":"launch-111",
                  "refresh_seq":7,"decided_seq":7,"interval_seconds":60,
                  "next_due_ts":$((SCHED_NOW+60))}}
JSON
if ! quota_usage_refresh_due "$SCHED_NOW" 'sched@x' 'uuid-s' 111 'launch-111' \
   && quota_usage_refresh_due "$((SCHED_NOW+60))" 'sched@x' 'uuid-s' 111 'launch-111' \
   && quota_usage_refresh_due "$SCHED_NOW" 'sched@x' 'uuid-s' 111 'launch-new' \
   && quota_usage_refresh_due "$SCHED_NOW" 'other@x' 'uuid-o' 222 'launch-222'; then
  pass "同账号/同 cc 代际在 next_due 前不触网；到点或账号/tmux/cc 代际变化立即刷新"
else
  fail "网络 due 没有按持久账号、tmux+cc 代际与 next_due 隔离"
fi
LOCAL_MARK="$TMP/local-observe"; NETWORK_MARK="$TMP/network-refresh"
rm -f "$LOCAL_MARK" "$NETWORK_MARK"
_stub_save quota_account_guard quota_reap_dead_sessions quota_monitor_observe quota_monitor_refresh
quota_account_guard() { QUOTA_GUARD_EMAIL='sched@x'; QUOTA_GUARD_UUID='uuid-s'; return 0; }
quota_reap_dead_sessions() { return 0; }
quota_monitor_observe() { : > "$LOCAL_MARK"; return 0; }
quota_monitor_refresh() { : > "$NETWORK_MARK"; return 1; }
if quota_read_once >/dev/null 2>&1 && [[ -e "$LOCAL_MARK" && ! -e "$NETWORK_MARK" ]]; then
  pass "未到 due 的 poll tick 只处理本地面板，不调用 /usage，也不复用旧帧做决策"
else
  fail "10s 本地 tick 仍触发了网络 /usage 或没有处理面板"
fi
_stub_restore quota_account_guard quota_reap_dead_sessions quota_monitor_observe quota_monitor_refresh

echo "── 双时钟：成功后的下一 due 必须从采样完成时刻计算 ──"
COMPLETE_MARK="$TMP/usage-refresh-completed"
rm -f "$COMPLETE_MARK"
if (
  QUOTA_STATE="$TMP/usage-completion-clock.json"; QUOTA_CACHE_MTIME=""
  cat > "$QUOTA_STATE" <<'JSON'
{"account":"clock@x","uuid":"uuid-c","monitor_session_created":111,
 "monitor_launch_id":"launch-111",
 "usage_refresh":{"account":"clock@x","uuid":"uuid-c","monitor_generation":111,
                  "monitor_launch_id":"launch-111",
                  "refresh_seq":8,"decided_seq":8}}
JSON
  date() {
    if [[ "$*" == "+%s" ]]; then
      [[ -e "$COMPLETE_MARK" ]] && printf '1020\n' || printf '1000\n'
    else
      command date "$@"
    fi
  }
  quota_account_guard() { QUOTA_GUARD_EMAIL='clock@x'; QUOTA_GUARD_UUID='uuid-c'; return 0; }
  quota_reap_dead_sessions() { return 0; }
  quota_usage_refresh_due() { return 0; }
  quota_monitor_refresh() {
    QUOTA_PANEL_LAST=$'75\t8\tfive-reset\tweek-reset'; QUOTA_REFRESH_SEQ=9
    : > "$COMPLETE_MARK"
    return 0
  }
  quota_window_reset_for_write() {
    [[ "$4" == "$QUOTA_SESSION_WINDOW_HORIZON" ]] && printf '1500\n' || printf '6000\n'
  }
  quota_source_log_usage() { return 0; }
  quota_source_log_usage_failure() { return 0; }
  quota_ratio_update() { :; }
  quota_capacity_update() { :; }
  quota_after_recovery() { return 0; }
  quota_log() { :; }
  quota_read_once >/dev/null 2>&1
  # ⚠️ 本条测的是**时钟起点**，不是档位数值：next_due 必须 = 完成时刻 + 本轮实际档位。
  #    原来写死成 1320（=1020+300）——2026-08-19 加了流速自适应后档位会被合法地收紧，
  #    这条立刻转红，但坏的不是被测语义，是断言把可变的档位当成了常量。
  #    改成断言不变式：三个值互相之间的关系对，就说明用的是同一个完成时钟。
  _clk_fetched=$(quota_state_get '.fetched_ts' 0)
  _clk_success=$(quota_state_get '.usage_refresh.last_success_ts' 0)
  _clk_due=$(quota_state_get '.usage_refresh.next_due_ts' 0)
  _clk_int=$(quota_state_get '.usage_refresh.interval_seconds' 0)
  [[ "$_clk_fetched" == "1020" && "$_clk_success" == "1020" ]] \
     && [[ "$_clk_int" =~ ^[0-9]+$ ]] && (( _clk_int > 0 )) \
     && [[ "$_clk_due" == "$(( 1020 + _clk_int ))" ]]
); then
  pass "300s 档从网络采样完成时刻起算，fetched/success/next_due 使用同一完成时钟"
else
  fail "网络耗时被从档位中扣掉：下一 due 仍从 poll tick 开始时刻计算"
fi

echo "── P2-C：reset 在写入 state 前统一按窗口视界校验 ──"
P2C_NOW=$(date +%s)
P2C_FIVE_BAD=$(( P2C_NOW + QUOTA_SESSION_WINDOW_HORIZON + 3600 ))
P2C_WEEK_BAD=$(( P2C_NOW - 60 ))
P2C_WEEK_TOO_FAR=$(( P2C_NOW + ${QUOTA_WEEK_WINDOW_HORIZON:-700000} + 3600 ))
P2C_FIVE_GOOD=$(( P2C_NOW + 1800 ))
P2C_WEEK_GOOD=$(( P2C_NOW + 604800 ))
if declare -F quota_reset_validate_for_write >/dev/null 2>&1 \
   && [[ "$(quota_reset_validate_for_write "$P2C_FIVE_GOOD" "$P2C_NOW" "$QUOTA_SESSION_WINDOW_HORIZON")" == "$P2C_FIVE_GOOD" ]] \
   && [[ "$(quota_reset_validate_for_write "$P2C_WEEK_GOOD" "$P2C_NOW" "${QUOTA_WEEK_WINDOW_HORIZON:-700000}")" == "$P2C_WEEK_GOOD" ]] \
   && ! quota_reset_validate_for_write "$P2C_FIVE_BAD" "$P2C_NOW" "$QUOTA_SESSION_WINDOW_HORIZON" >/dev/null 2>&1 \
   && ! quota_reset_validate_for_write "$P2C_WEEK_BAD" "$P2C_NOW" "${QUOTA_WEEK_WINDOW_HORIZON:-700000}" >/dev/null 2>&1 \
   && ! quota_reset_validate_for_write nope "$P2C_NOW" "$QUOTA_SESSION_WINDOW_HORIZON" >/dev/null 2>&1 \
   && ! quota_reset_validate_for_write "$P2C_NOW" "$P2C_NOW" "$QUOTA_SESSION_WINDOW_HORIZON" >/dev/null 2>&1 \
   && [[ "$(quota_reset_validate_for_write "$((P2C_NOW+QUOTA_SESSION_WINDOW_HORIZON))" "$P2C_NOW" "$QUOTA_SESSION_WINDOW_HORIZON")" == "$((P2C_NOW+QUOTA_SESSION_WINDOW_HORIZON))" ]]; then
  pass "reset 写入校验：合法未来边界保留，过期/超视界/非数字拒绝"
else
  fail "缺少统一 reset 写入校验，或 epoch 边界语义错误"
fi

# 主轮写两份：顶层当前值 + accounts[current]。任一 reset 非法时，整帧必须原子拒绝，
# 不能把新百分比配旧 reset，也不能写 null 主动制造 P1-A 的残缺台账。
QUOTA_STATE="$TMP/reset-write-current.json"; QUOTA_CACHE_MTIME=""
cat > "$QUOTA_STATE" <<JSON
{"phase":"normal","account":"prior@x","five_hour":7,"seven_day":8,
 "five_reset_ts":$P2C_FIVE_GOOD,"week_reset_ts":$P2C_WEEK_GOOD,
 "accounts":{"current@x":{"five":7,"week":8,"five_reset":$P2C_FIVE_GOOD,"week_reset":$P2C_WEEK_GOOD}}}
JSON
P2C_CURRENT_BEFORE=$(quota_state_read | jq -c '{account,five_hour,seven_day,five_reset_ts,week_reset_ts,accounts}')
P2C_DECISION_MARK="$TMP/p2c-current-decision"
rm -f "$P2C_DECISION_MARK"
_stub_save quota_account_guard quota_reap_dead_sessions quota_monitor_refresh quota_panel_reset_epoch \
           quota_ratio_update quota_capacity_update quota_after_recovery quota_source_log_usage quota_source_log_usage_failure
quota_account_guard() { QUOTA_GUARD_EMAIL='current@x'; QUOTA_GUARD_UUID='uuid-current'; return 0; }
quota_reap_dead_sessions() { return 0; }
quota_monitor_refresh() { QUOTA_PANEL_LAST=$'20\t30\tfive-bad\tweek-bad'; return 0; }
quota_panel_reset_epoch() {
  [[ "$1" == "five-bad" ]] && printf '%s\n' "$P2C_FIVE_BAD" || printf '%s\n' "$P2C_WEEK_GOOD"
}
quota_ratio_update() { : > "$P2C_DECISION_MARK"; }
quota_capacity_update() { : > "$P2C_DECISION_MARK"; }
quota_after_recovery() { : > "$P2C_DECISION_MARK"; }
quota_source_log_usage() { : > "$P2C_DECISION_MARK"; }
quota_source_log_usage_failure() { :; }
if quota_read_once >/dev/null 2>&1; then p2c_current_rc=0; else p2c_current_rc=$?; fi
P2C_CURRENT_AFTER=$(quota_state_read | jq -c '{account,five_hour,seven_day,five_reset_ts,week_reset_ts,accounts}')
if (( p2c_current_rc != 0 )) \
   && [[ "$P2C_CURRENT_AFTER" == "$P2C_CURRENT_BEFORE" ]] \
   && [[ ! -e "$P2C_DECISION_MARK" ]]; then
  pass "主轮当前账号：一维 reset 非法则整帧不写、不进入 ratio/capacity/恢复决策"
else
  fail "主轮未原子拒绝非法 reset（rc=$p2c_current_rc changed=$([[ "$P2C_CURRENT_AFTER" != "$P2C_CURRENT_BEFORE" ]] && echo yes || echo no) decision=$([[ -e "$P2C_DECISION_MARK" ]] && echo yes || echo no)）"
fi
_stub_restore quota_account_guard quota_reap_dead_sessions quota_monitor_refresh quota_panel_reset_epoch \
              quota_ratio_update quota_capacity_update quota_after_recovery quota_source_log_usage quota_source_log_usage_failure
# 🔴 上游这一组还有第三段：候选账号切过去量一次之后的**另一处写入口**，同样不许绕过
#    reset 规范化（走 quota_try_switch → 候选面板读数 → 写 accounts[候选]）。
#    本仓**没有那条路径**：切号那一半是重写的，quota_switch_perform 把凭据交给
#    account-switch 之后就结束，不去测量候选账号、也不写候选台账（候选数值只由
#    account-probe 的快照另行提供）。⇒ 那段断言在本仓没有对象，整段不搬，
#    **而不是**改成一条碰巧能通过的形式。若以后补上候选测量，这段要一起补回来。
}

# ── shadow sampling / 影子采样 ──

run_shadow_tests() {
  echo "── 影子采样：两条新来源只记账，不参与额度决策 ──"
  _stub_save quota_log
  quota_log() { printf '[test] %s\n' "$1" >> "$QUOTA_LOG"; }
  rm -f "$QUOTA_SHADOW_OAUTH_STATE" "$QUOTA_SHADOW_OAUTH_EVENTS" "$QUOTA_SHADOW_OAUTH_LOCK" \
        "$QUOTA_SHADOW_STATUSLINE_STATE" "$QUOTA_SHADOW_STATUSLINE_EVENTS" "$QUOTA_SHADOW_STATUSLINE_LOCK" \
        "$QUOTA_SHADOW_SCHEDULE_STATE" "$QUOTA_SHADOW_SCHEDULE_LOCK" \
        "$QUOTA_SOURCE_EVENTS" "$QUOTA_SOURCE_EVENTS_LOCK"

  # ⚠️ 2026-08-21 改判：本用例原先断言 OAuth shadow poller **必须默认停用**。
  #    那是 2026-08-13 的决定——当时实测 28 次查询里 25 次被限流（成功率 7%），
  #    于是整条路关掉。后来重新验证过：限流的真正原因是**查询间隔太密**，
  #    正常 token 在 ≥180s 间隔下 7/7 全部成功。据此用户拍板重新打开。
  #    所以现在要守的不再是「必须关」，而是「开了也不能烧接口次数」——
  #    即节流间隔不得低于地板价。断言跟着决定走，否则用例会一直红着挡路。
  if [[ "$QUOTA_SHADOW_OAUTH_ENABLED" == "1" ]] \
     && [[ "$QUOTA_SHADOW_OAUTH_INTERVAL" =~ ^[0-9]+$ ]] \
     && (( QUOTA_SHADOW_OAUTH_INTERVAL >= 180 )); then
    pass "OAuth shadow poller 已启用，且采样间隔不低于 180s 地板价（${QUOTA_SHADOW_OAUTH_INTERVAL}s）"
  else
    fail "OAuth 采样配置越界（enabled=$QUOTA_SHADOW_OAUTH_ENABLED interval=$QUOTA_SHADOW_OAUTH_INTERVAL）—— 间隔低于 180s 会重演 08-13 的 25/28 限流"
  fi

  local schedule
  schedule=$(quota_shadow_schedule 100000 2>/dev/null || true)
  if [[ -n "$schedule" ]] \
     && [[ "$(printf '%s' "$schedule" | jq -r '.stage,.interval_seconds' | paste -sd/ -)" == "1/20" ]] \
     && [[ "$(quota_shadow_schedule 100600 2>/dev/null | jq -r '.stage,.interval_seconds' | paste -sd/ -)" == "2/40" ]] \
     && [[ "$(quota_shadow_schedule 101200 2>/dev/null | jq -r '.stage,.interval_seconds' | paste -sd/ -)" == "3/60" ]] \
     && [[ "$(quota_shadow_schedule 101800 2>/dev/null | jq -r '.stage,.interval_seconds' | paste -sd/ -)" == "4/120" ]] \
     && [[ "$(quota_shadow_schedule 102400 2>/dev/null | jq -r '.stage,.interval_seconds' | paste -sd/ -)" == "4/120" ]]; then
    pass "四个 10 分钟阶段依次为 20s/40s/60s/120s，结束后保持 120s"
  else
    fail "四阶段采样节奏不符合 20s/40s/60s/120s"
  fi
  rm -f "$QUOTA_SHADOW_SCHEDULE_STATE" "$QUOTA_SHADOW_SCHEDULE_LOCK"

  QUOTA_STATE="$TMP/shadow-main-state.json"; QUOTA_CACHE_MTIME=""
  cat > "$QUOTA_STATE" <<'JSON'
{"phase":"near","account":"shadow@x","five_hour":91,"seven_day":88,
 "monitor_account":"shadow@x","monitor_uuid":"uuid-shadow","monitor_session_created":"4242",
 "monitor_launch_id":"launch-shadow",
 "accounts":{"shadow@x":{"five":91,"week":88}}}
JSON
  local main_before payload event count launch
  main_before=$(sha256sum "$QUOTA_STATE" | awk '{print $1}')
  payload='{"session_id":"claude-session-1","version":"2.1.226","rate_limits":{"five_hour":{"used_percentage":12.5,"resets_at":1893474000},"seven_day":{"used_percentage":34,"resets_at":1893888000}}}'

  _stub_save quota_identity_read quota_session_created quota_monitor_live_launch_id
  quota_identity_read() { printf 'shadow@x\037uuid-shadow\037uuid-shadow\n'; }
  quota_session_created() { printf '4242\n'; }
  quota_monitor_live_launch_id() { printf 'launch-shadow\n'; }

  if printf '%s' "$payload" | quota_shadow_statusline_ingest \
       "shadow@x" "uuid-shadow" "4242" "launch-shadow" >/dev/null 2>&1 \
     && [[ -s "$QUOTA_SHADOW_STATUSLINE_EVENTS" ]]; then
    pass "statusLine 有效帧写入独立 JSONL"
  else
    fail "statusLine 有效帧未写入独立 JSONL"
  fi
  event=$(tail -n 1 "$QUOTA_SHADOW_STATUSLINE_EVENTS" 2>/dev/null || true)
  if [[ -n "$event" ]] && printf '%s' "$event" | jq -e '
      .source == "statusline"
      and .decision_eligible == false
      and .account.email == "shadow@x"
      and .account.uuid == "uuid-shadow"
      and .monitor.generation == "4242"
      and .monitor.launch_id == "launch-shadow"
      and .observed_at > 0
      and .cadence.stage == 1
      and .cadence.interval_seconds == 20
      and .windows.five_hour.period_seconds == 18000
      and .windows.five_hour.used_percentage == 12.5
      and .windows.five_hour.resets_at == 1893474000
      and .windows.seven_day.period_seconds == 604800
      and .windows.seven_day.used_percentage == 34
      and .windows.seven_day.resets_at == 1893888000' >/dev/null 2>&1; then
    pass "statusLine 记录含来源、账号、采样时刻、两个额度窗口且明确不可决策"
  else
    fail "statusLine 影子记录字段不完整：${event:-empty}"
  fi

  printf '%s' "$payload" | quota_shadow_statusline_ingest \
    "shadow@x" "uuid-shadow" "4242" "launch-shadow" >/dev/null 2>&1 || true
  if [[ -f "$QUOTA_SHADOW_STATUSLINE_EVENTS" ]]; then count=$(wc -l < "$QUOTA_SHADOW_STATUSLINE_EVENTS"); else count=0; fi
  if (( count == 1 )); then
    pass "statusLine 回调在当前实验频率窗口内节流"
  else
    fail "statusLine 相同帧重复落盘（lines=$count）"
  fi

  printf '%s' "${payload/claude-session-1/claude-session-2}" | quota_shadow_statusline_ingest \
    "shadow@x" "uuid-shadow" "old-generation" "launch-shadow" >/dev/null 2>&1 || true
  if [[ -f "$QUOTA_SHADOW_STATUSLINE_EVENTS" ]]; then count=$(wc -l < "$QUOTA_SHADOW_STATUSLINE_EVENTS"); else count=0; fi
  if (( count == 1 )); then
    pass "statusLine 旧 monitor 代际帧被丢弃，不会串账号"
  else
    fail "statusLine 接收了旧 monitor 代际帧"
  fi

  if launch=$(quota_monitor_launch_command "shadow@x" "uuid-shadow" "4242" "launch-shadow" 2>/dev/null) \
     && [[ "$launch" == *"--settings"* && "$launch" == *"shadow-statusline-ingest"* \
           && "$launch" == *"refreshInterval"* ]]; then
    pass "专用 monitor 启动命令注入低频 statusLine 采样器"
  else
    fail "专用 monitor 启动命令没有注入 statusLine 采样器"
  fi

  if [[ "$(sha256sum "$QUOTA_STATE" | awk '{print $1}')" == "$main_before" ]]; then
    pass "statusLine 采样未改主 quota-state（不进入切号/等待/恢复）"
  else
    fail "statusLine 采样污染了主 quota-state"
  fi

  # tmux session 不变、只在原 pane 内换 cc 时，旧 callback 的 session_created 仍相同；
  # 必须靠独立 launch id 把上一代回调挡住。
  quota_state_merge '.monitor_launch_id = "launch-new"' >/dev/null 2>&1
  quota_monitor_live_launch_id() { printf 'launch-new\n'; }
  if [[ -f "$QUOTA_SHADOW_STATUSLINE_EVENTS" ]]; then count=$(wc -l < "$QUOTA_SHADOW_STATUSLINE_EVENTS"); else count=0; fi
  before_launch_count=$count
  printf '%s' "${payload/claude-session-1/claude-session-old}" | quota_shadow_statusline_ingest \
    "shadow@x" "uuid-shadow" "4242" "launch-shadow" >/dev/null 2>&1 || true
  if [[ -f "$QUOTA_SHADOW_STATUSLINE_EVENTS" ]]; then count=$(wc -l < "$QUOTA_SHADOW_STATUSLINE_EVENTS"); else count=0; fi
  if (( count == before_launch_count )); then
    pass "同 tmux 代际内上一代 cc 的 statusLine callback 被 launch id 丢弃"
  else
    fail "旧 cc callback 冒用了未变化的 session_created"
  fi
  _stub_restore quota_identity_read quota_session_created quota_monitor_live_launch_id
  main_before=$(sha256sum "$QUOTA_STATE" | awk '{print $1}')
  # 决策状态快照：OAuth 写读数可以，动这几格不行
  QUOTA_CACHE_MTIME=""
  decision_phase_before=$(quota_state_get '.phase' 'null')
  decision_wait_before=$(quota_state_get '.waiting_until' 'null')
  decision_episode_before=$(quota_state_get '.episode' 'null')
  decision_switch_before=$(quota_state_get '.last_switch_ts' 'null')
  decision_sessions_before=$(quota_state_read | jq -c '.sessions // {}')

  echo "── 影子采样：OAuth JSON 的成功、节流、漂移与退避 ──"
  rm -f "$QUOTA_SHADOW_OAUTH_STATE" "$QUOTA_SHADOW_OAUTH_EVENTS" "$QUOTA_SHADOW_OAUTH_LOCK"
  _stub_save quota_identity_read quota_shadow_oauth_http_fetch
  quota_identity_read() { printf 'shadow@x\037uuid-shadow\037uuid-shadow\n'; }
  quota_shadow_oauth_http_fetch() {
    local body_file="$1" header_file="$2"
    printf '%s' '{"five_hour":{"utilization":13,"resets_at":"2030-01-01T05:00:00+00:00"},"seven_day":{"utilization":47,"resets_at":"2030-01-07T00:00:00+00:00"}}' > "$body_file"
    : > "$header_file"
    printf '200'
  }
  if quota_shadow_oauth_sample >/dev/null 2>&1 \
     && event=$(tail -n 1 "$QUOTA_SHADOW_OAUTH_EVENTS" 2>/dev/null) \
     && printf '%s' "$event" | jq -e '
          .source == "oauth_api"
          and .decision_eligible == false
          and .outcome == "ok"
          and .account.email == "shadow@x"
          and .account.uuid == "uuid-shadow"
          and .observed_at > 0
          and .cadence.stage == 1
          and .cadence.interval_seconds == 20
          and .windows.five_hour.period_seconds == 18000
          and .windows.five_hour.used_percentage == 13
          and .windows.five_hour.resets_at > 0
          and .windows.seven_day.period_seconds == 604800
          and .windows.seven_day.used_percentage == 47
          and .windows.seven_day.resets_at > 0' >/dev/null 2>&1; then
    pass "OAuth JSON 成功帧按账号与窗口写入独立 JSONL"
  else
    fail "OAuth JSON 成功帧没有正确落盘：${event:-empty}"
  fi

  quota_shadow_oauth_sample >/dev/null 2>&1 || true
  if [[ -f "$QUOTA_SHADOW_OAUTH_EVENTS" ]]; then count=$(wc -l < "$QUOTA_SHADOW_OAUTH_EVENTS"); else count=0; fi
  if (( count == 1 )); then
    pass "OAuth JSON 成功采样后按低频间隔节流"
  else
    fail "OAuth JSON 未节流（lines=$count）"
  fi

  rm -f "$QUOTA_SHADOW_OAUTH_STATE" "$QUOTA_SHADOW_OAUTH_EVENTS" "$TMP/shadow-identity-changed"
  quota_identity_read() {
    if [[ -e "$TMP/shadow-identity-changed" ]]; then
      printf 'other@x\037uuid-other\037uuid-other\n'
    else
      printf 'shadow@x\037uuid-shadow\037uuid-shadow\n'
    fi
  }
  quota_shadow_oauth_http_fetch() {
    local body_file="$1" header_file="$2"
    printf '%s' '{"five_hour":{"utilization":14,"resets_at":"2030-01-01T05:00:00+00:00"},"seven_day":{"utilization":48,"resets_at":"2030-01-07T00:00:00+00:00"}}' > "$body_file"
    : > "$header_file"
    : > "$TMP/shadow-identity-changed"
    printf '200'
  }
  quota_shadow_oauth_sample >/dev/null 2>&1 || true
  event=$(tail -n 1 "$QUOTA_SHADOW_OAUTH_EVENTS" 2>/dev/null || true)
  if [[ -n "$event" ]] && printf '%s' "$event" | jq -e '.outcome == "identity_changed" and .windows == null' >/dev/null 2>&1; then
    pass "OAuth 请求途中账号变化时丢弃额度，不把值记到错误账号"
  else
    fail "OAuth 请求途中账号变化仍采信了额度：${event:-empty}"
  fi

  rm -f "$QUOTA_SHADOW_OAUTH_STATE" "$QUOTA_SHADOW_OAUTH_EVENTS" "$TMP/shadow-identity-changed"
  quota_identity_read() { printf 'shadow@x\037uuid-shadow\037uuid-shadow\n'; }
  quota_shadow_oauth_http_fetch() {
    local body_file="$1" header_file="$2"
    printf '%s' '{"error":{"type":"rate_limit_error"}}' > "$body_file"
    printf 'Retry-After: 900\r\n' > "$header_file"
    printf '429'
  }
  quota_shadow_oauth_sample >/dev/null 2>&1 || true
  event=$(tail -n 1 "$QUOTA_SHADOW_OAUTH_EVENTS" 2>/dev/null || true)
  if [[ -n "$event" ]] && printf '%s' "$event" | jq -e '
      .outcome == "rate_limited"
      and .windows == null
      and (.next_due - .attempted_at) >= 900
      and .cadence.interval_seconds >= 20' >/dev/null 2>&1 \
     && [[ "$(jq -r '.penalty_interval // 0' "$QUOTA_SHADOW_SCHEDULE_STATE" 2>/dev/null)" -ge 40 ]]; then
    pass "OAuth 429 尊重 Retry-After、自动降频且错误正文不进日志"
  else
    fail "OAuth 429 没有正确退避：${event:-empty}"
  fi
  schedule=$(quota_shadow_schedule "$(date +%s)" 2>/dev/null || echo '{}')
  if [[ "$(quota_shadow_source_interval statusline "$schedule")" == "20" \
        && "$(quota_shadow_source_interval oauth_api "$schedule")" -ge 40 ]]; then
    pass "OAuth 拒绝只降低网络直查频率，statusLine 仍按原四阶段计划"
  else
    fail "OAuth penalty 错误拖慢了本地 statusLine 采样"
  fi

  quota_source_log_usage "$(date +%s)" "shadow@x" "uuid-shadow" 15 1893474000 49 1893888000
  quota_source_log_usage_failure "$(date +%s)" "shadow@x" "uuid-shadow" "panel_stale_frame"
  if jq -s -e '
      any(.[]; .source == "statusline")
      and any(.[]; .source == "oauth_api")
      and any(.[]; .source == "usage_panel" and .decision_eligible == true)
      and any(.[]; .source == "usage_panel" and .decision_eligible == false
                   and .outcome == "panel_stale_frame" and .windows == null)
      and all(.[]; has("observed_at") and has("account") and has("windows") and has("cadence"))' \
      "$QUOTA_SOURCE_EVENTS" >/dev/null 2>&1; then
    pass "统一逐次日志同时含 /usage、OAuth、statusLine，均带账号/时刻/窗口/频率"
  else
    fail "统一逐次日志缺少三方样本或比较字段"
  fi

  # ⚠️ 上游这条断言是「grep 单文件里有没有 quota_shadow_poller_ensure 的调用」。本仓被
  #    拆成多文件，而且调用它的那个监督 daemon **未抽取** ⇒ 照搬那句 grep 只会证明
  #    「这个名字在文件里出现过」，而它在定义处也出现。⭐ 一条只会命中定义本身的 grep，
  #    绿得毫无分辨力。改成直接测它要守的那件事：**读数主轮不得驱动 OAuth 采样**。
  _stub_save quota_shadow_oauth_sample quota_account_guard quota_monitor_observe quota_usage_refresh_due
  OAUTH_DRIVEN_MARK="$TMP/oauth-driven-by-read-round"
  rm -f "$OAUTH_DRIVEN_MARK"
  quota_shadow_oauth_sample() { : > "$OAUTH_DRIVEN_MARK"; return 0; }
  quota_account_guard() { QUOTA_GUARD_EMAIL='sh@x'; QUOTA_GUARD_UUID='uuid-sh'; return 0; }
  quota_usage_refresh_due() { return 1; }
  quota_monitor_observe() { return 0; }
  quota_read_once >/dev/null 2>&1
  if declare -F quota_shadow_poller_loop >/dev/null 2>&1 \
     && declare -F quota_shadow_poller_ensure >/dev/null 2>&1 \
     && [[ ! -e "$OAUTH_DRIVEN_MARK" ]]; then
    pass "OAuth 走独立影子时钟：读数主轮跑完一整轮也没有触发过一次 OAuth 采样"
  else
    fail "OAuth 仍由 /usage 主轮驱动，20s 档会被单轮耗时拉成约 36s"
  fi
  # 正控：同一个标记文件在 OAuth 采样真被调用时必须出现，否则上面那条「没出现」等于没测。
  quota_shadow_oauth_sample >/dev/null 2>&1
  if [[ -e "$OAUTH_DRIVEN_MARK" ]]; then
    pass "正控：标记文件在采样真被调用时确实出现（上面那条不是恒真）"
  else
    fail "正控没红：标记文件根本不会出现，上面那条断言不测任何东西"
  fi
  _stub_restore quota_shadow_oauth_sample quota_account_guard quota_monitor_observe quota_usage_refresh_due

  # 🔴 一处只报不修的观察：quota_shadow_poller_ensure 在本仓**没有任何调用方**——上游是
  #    那个未抽取的监督 daemon 每拍调它保活。本仓唯一的启动口是 CLI 的 shadow-poller
  #    子命令，要人自己起。⇒ 影子采样在本仓默认**不会自己跑起来**。这里只把事实钉住，
  #    不替它决定该由谁调。
  if grep -q 'shadow-poller' "$QS_SOURCE/quota-sentinel"; then
    pass "影子采样至少有一个可达入口（CLI shadow-poller）；ensure 保活无调用方，已记录"
  else
    fail "影子采样在本仓无任何可达入口：定义在那里，谁都起不动它"
  fi

  # ⚠️ 2026-08-21 改判：原先用整个状态文件的 sha256 断言「OAuth 一个字节都不许动」。
  #    那是 OAuth 还是纯影子时的契约。用户拍板让它转为正式上游后，**写读数是它的本职**，
  #    整文件哈希会必然变化。但它背后要防的事一点没变、而且更该精确地守住：
  #    **OAuth 可以更新读数，但绝不能自己驱动切号/等待/恢复的状态跃迁。**
  #    所以改成按字段守 —— 这比整文件哈希更强：哈希只会告诉你「有东西变了」，
  #    不会告诉你变的是读数还是 phase，而这两者的后果天差地别。
  if [[ "$(quota_state_get '.phase' 'null')" == "$decision_phase_before" ]] \
     && [[ "$(quota_state_get '.waiting_until' 'null')" == "$decision_wait_before" ]] \
     && [[ "$(quota_state_get '.episode' 'null')" == "$decision_episode_before" ]] \
     && [[ "$(quota_state_get '.last_switch_ts' 'null')" == "$decision_switch_before" ]] \
     && [[ "$(quota_state_read | jq -c '.sessions // {}')" == "$decision_sessions_before" ]]; then
    pass "OAuth 采样只更新读数，不碰 phase/waiting/episode/last_switch/sessions（不驱动决策跃迁）"
  else
    fail "OAuth 采样动了决策状态：phase=$(quota_state_get '.phase' 'null')（原 $decision_phase_before）waiting=$(quota_state_get '.waiting_until' 'null')（原 $decision_wait_before）"
  fi
  _stub_restore quota_identity_read quota_shadow_oauth_http_fetch
  _stub_restore quota_log
}


# ── the decision layer / 决策层 ──
run_decision_tests() {

echo "── 切号被挡下时不得每拍重试 ──"
# ⚠️ 上游 2026-08-21 把决策拆成每 10s 一拍之后，「触阈值 → 无处可切」从每 60s 一次变成
#    每 10s 一次，08-24 12:00 实撞刷了几百行。而 2026-08-24 起在役只剩一个账号，
#    **到阈值必然无处可切**，这个状态天天出现并持续数小时——噪音会埋掉真信号。
# 🔴 本仓的形态更糟一点：无处可切那一支除了打日志，还会**每拍往流水账追加一条 blocked**，
#    而流水账正是事后唯一能复原「这台机器为什么在这个账号上」的东西。
#    上游这道闸挂在 quota_switch_allowed（安全闸，未抽取）上；本仓挂在
#    quota_switch_pick 失败这一支上。守的是同一件事，位置不同。
TH="$TMP/throttle"; mkdir -p "$TH"
QUOTA_STATE="$TH/state.json"; QUOTA_LOG="$TH/quota.log"; QUOTA_SWITCH_LEDGER="$TH/switches.jsonl"
_TH_NOW=1787320000
_th_state() {   # 只有一个在役账号且已过线 ⇒ quota_switch_pick 必然找不到候选
  printf '{"account":"cur@x","fetched_ts":%s,"accounts":{"cur@x":{"five":95,"week":10}}}' \
    "$(( _TH_NOW - 30 ))" > "$QUOTA_STATE"
}
_th_state; : > "$QUOTA_LOG"; : > "$QUOTA_SWITCH_LEDGER"
for _i in $(seq 0 29); do quota_decide_once "$(( _TH_NOW + _i * 10 ))" >/dev/null 2>&1; done
_th_log=$(grep -c '🛑' "$QUOTA_LOG"); _th_led=$(grep -c '"blocked"' "$QUOTA_SWITCH_LEDGER")
if [[ "$_th_log" == "1" && "$_th_led" == "1" ]]; then
  pass "被挡下后 5 分钟（30 拍）日志 1 条、流水账 1 条，不刷屏也不刷账"
else
  fail "5 分钟内日志 $_th_log 条、流水账 $_th_led 条——每拍重试会把两者都刷满"
fi
# ⚠️ 正控之一：静默不能变成永久闭嘴。防抖窗口过后必须能重新出声，
#    否则一次「无处可切」之后就再也不报告了——那比刷屏严重得多。
quota_decide_once "$(( _TH_NOW + QUOTA_SWITCH_MIN_INTERVAL + 5 ))" >/dev/null 2>&1
if [[ "$(grep -c '🛑' "$QUOTA_LOG")" == "2" ]]; then
  pass "正控：防抖窗口过后恢复报告（静默没变成永久闭嘴）"
else
  fail "窗口过后仍不出声——一次被挡就再也不报告了"
fi
# ⚠️ 正控之二：首次尝试不得被延迟。闸只在「已经被挡过」之后生效。
_th_state; : > "$QUOTA_LOG"; : > "$QUOTA_SWITCH_LEDGER"
quota_decide_once "$_TH_NOW" >/dev/null 2>&1
if [[ "$(grep -c '🛑' "$QUOTA_LOG")" == "1" ]]; then
  pass "正控：首次尝试立即执行，不被防抖闸延迟"
else
  fail "首次尝试就被压住——真该报告时会晚 ${QUOTA_SWITCH_MIN_INTERVAL}s"
fi
# ⚠️ 正控之三：闸不能把**能切**的那次也压住。同样在防抖窗口内，只要出现可用候选就必须切。
#    没有这一条，上面三条用「恒拒」实现也全绿。
printf '{"account":"cur@x","fetched_ts":%s,"accounts":{"cur@x":{"five":95,"week":10},"free@x":{"five":5,"week":5}}}' \
  "$(( _TH_NOW - 30 ))" > "$QUOTA_STATE"
: > "$QUOTA_LOG"
quota_decide_once "$(( _TH_NOW + 10 ))" >/dev/null 2>&1
if grep -q 'would switch' "$QUOTA_LOG"; then
  pass "正控：防抖窗口内出现可用候选时照常切号（闸压的是重复报告，不是切号）"
else
  fail "防抖闸把真正该切的那次也压住了：$(tail -1 "$QUOTA_LOG")"
fi

echo "── 决策只读台账，且对陈旧读数 fail closed ──"
# ⚠️ 上游 2026-08-21 第二步：判断从采集里拆出来，轮询每一拍都对着台账判一次。
#    拆之前决策只在**面板刷新成功那一拍**发生，于是 OAuth 写进台账的新读数要等面板
#    下次成功才被看见——而面板恰恰在逼近阈值时被限流失明（实测 27 次、中位 6.4 分钟）。
# ⚠️ 拆开就必须配新鲜度闸，否则更糟：对着**僵住的**台账反复决策，等于每一拍都自信地
#    按陈旧水位判一次；原来至少「没刷新就不判」。
DC="$TMP/decide"; mkdir -p "$DC"
QUOTA_STATE="$DC/state.json"; QUOTA_LOG="$DC/quota.log"; QUOTA_SWITCH_LEDGER="$DC/switches.jsonl"
_DC_NOW=1787320000
_dc_run() {  # $1=five $2=读数年龄(s)
  printf '{"account":"cur@x","fetched_ts":%s,"accounts":{"cur@x":{"five":%s,"week":10},"free@x":{"five":5,"week":5}}}' \
    "$(( _DC_NOW - $2 ))" "$1" > "$QUOTA_STATE"
  : > "$QUOTA_LOG"; : > "$QUOTA_SWITCH_LEDGER"
  quota_decide_once "$_DC_NOW" >/dev/null 2>&1
  grep -c 'would switch' "$QUOTA_LOG"
}
if [[ "$(_dc_run 95 30)" == "1" ]]; then
  pass "读数新鲜且超阈值 → 只凭台账就能判定切号（不必等面板那一拍）"
else
  fail "台账里已有超阈值的新读数却没判 —— 决策没接上台账"
fi
if [[ "$(_dc_run 40 30)" == "0" ]]; then
  pass "读数新鲜但未到阈值 → 不切"
else
  fail "未到阈值也切了"
fi
# ⚠️ 这条是拆分带来的**新**风险，必须守死。
if [[ "$(_dc_run 95 $(( QUOTA_FETCH_MAX_AGE + 60 )))" == "0" ]]; then
  pass "读数超期 → 不做决策（fail closed，不按陈旧水位切号）"
else
  fail "拿超期读数切号 —— 每拍都会把这个错误重复一次"
fi
_dc_run 95 "$(( QUOTA_FETCH_MAX_AGE + 60 ))" >/dev/null
if grep -q 'no decision this round' "$QUOTA_LOG"; then
  pass "超期时说明了原因（上一条不是因为函数压根没跑到）"
else
  fail "超期时静默返回 —— 分不清『判过了没超阈值』和『压根没判』"
fi
# ⚠️ 正控：同一份超期读数只说一次，但换一份新的超期读数必须重新说。
#    「每份说一次」与「说过一次就再也不说」在单次运行里长得一模一样。
: > "$QUOTA_LOG"
printf '{"account":"cur@x","fetched_ts":%s,"accounts":{"cur@x":{"five":95,"week":10},"free@x":{"five":5,"week":5}}}' \
  "$(( _DC_NOW - QUOTA_FETCH_MAX_AGE - 60 ))" > "$QUOTA_STATE"
quota_decide_once "$_DC_NOW" >/dev/null 2>&1
quota_decide_once "$_DC_NOW" >/dev/null 2>&1
_dc_first=$(grep -c 'no decision this round' "$QUOTA_LOG")
printf '{"account":"cur@x","fetched_ts":%s,"accounts":{"cur@x":{"five":95,"week":10},"free@x":{"five":5,"week":5}},"decide_stale_logged":%s}' \
  "$(( _DC_NOW - QUOTA_FETCH_MAX_AGE - 61 ))" "$(( _DC_NOW - QUOTA_FETCH_MAX_AGE - 60 ))" > "$QUOTA_STATE"
quota_decide_once "$_DC_NOW" >/dev/null 2>&1
_dc_second=$(grep -c 'no decision this round' "$QUOTA_LOG")
if [[ "$_dc_first" == "1" && "$_dc_second" == "2" ]]; then
  pass "正控：同一份陈旧读数只说一次，换一份仍会说（不是说过就永久闭嘴）"
else
  fail "陈旧提示的去重口径错了（同一份说了 $_dc_first 次，换一份后累计 $_dc_second 次）"
fi

echo "── 两条线同时越过时，流水账必须两条都写 ──"
# 上游那两句原本是直接赋值，周额度那句会把五小时那句悄悄盖掉；双重耗尽在账本里只剩一个
# 原因，读的人会据此以为五小时没事。抽取时已改成累加，这里把它钉住。
QUOTA_STATE="$DC/both.json"; QUOTA_LOG="$DC/both.log"; QUOTA_SWITCH_LEDGER="$DC/both.jsonl"
printf '{"account":"cur@x","fetched_ts":%s,"accounts":{"cur@x":{"five":99,"week":100},"free@x":{"five":5,"week":5}}}' \
  "$(( _DC_NOW - 30 ))" > "$QUOTA_STATE"
: > "$QUOTA_LOG"; : > "$QUOTA_SWITCH_LEDGER"
quota_decide_once "$_DC_NOW" >/dev/null 2>&1
_both=$(jq -r '.note' "$QUOTA_SWITCH_LEDGER" 2>/dev/null | tail -1)
if [[ "$_both" == *"five_hour"* && "$_both" == *"weekly"* ]]; then
  pass "两条线都越过时账本两条原因都在（不是后一条盖掉前一条）"
else
  fail "双重耗尽在账本里只留下一个原因：[$_both]"
fi
# 正控：只越过一条线时，账本里必须只有那一条，否则上面那条用「永远两条都写」也能过。
printf '{"account":"cur@x","fetched_ts":%s,"accounts":{"cur@x":{"five":99,"week":10},"free@x":{"five":5,"week":5}}}' \
  "$(( _DC_NOW - 30 ))" > "$QUOTA_STATE"
: > "$QUOTA_SWITCH_LEDGER"
quota_decide_once "$_DC_NOW" >/dev/null 2>&1
_one=$(jq -r '.note' "$QUOTA_SWITCH_LEDGER" 2>/dev/null | tail -1)
if [[ "$_one" == *"five_hour"* && "$_one" != *"weekly"* ]]; then
  pass "正控：只越过五小时线时账本只写这一条（上面那条不是恒真）"
else
  fail "只越过一条线却写了两条原因：[$_one]"
fi
}

# ── slow layer / 慢层 ──
run_slow_tests() {
echo "── /usage 主动刷新：clean 重开、错误页才按 r，结束后面板常驻 ──"
# Claude Code 2.1.226 的 clean 面板没有 r action；正常到期必须 Esc→重开 /usage。
# rate-limit/last-known/error 面板才注册 r to retry。两条路径都不能在读完后再次 dismiss。
REFRESH_TRACE="$TMP/usage-refresh-trace"
: > "$REFRESH_TRACE"
_stub_save quota_monitor_prepare_owner quota_monitor_dismiss quota_monitor_panel_open \
           quota_monitor_owner_guard quota_monitor_open_usage quota_usage_refresh_begin \
           quota_usage_refresh_failure quota_panel_reset_epoch quota_frame_stale quota_panel_log_observation
_stub_save quota_monitor_recover_stale_frame
PANEL_OK=$'Current session\n  20% used\n  Resets 5:00pm (Asia/Shanghai)\nCurrent week (all models)\n  30% used\n  Resets Aug 20, 5:00pm (Asia/Shanghai)'
REFRESH_FRAME="$PANEL_OK"
tmux() {
  if [[ "${1:-}" == "send-keys" ]]; then
    printf 'send:%s\n' "${!#}" >> "$REFRESH_TRACE"
    [[ "${!#}" == "r" ]] && REFRESH_FRAME="$PANEL_OK"
    return 0
  fi
  if [[ "${1:-}" == "capture-pane" ]]; then
    printf '%s\n' "$REFRESH_FRAME"
    return 0
  fi
  return 0
}
sleep() { :; }
quota_monitor_prepare_owner() {
  QUOTA_MONITOR_CURRENT_ACCOUNT='s@x'; QUOTA_MONITOR_CURRENT_UUID='u'
  QUOTA_MONITOR_CURRENT_GENERATION=111; QUOTA_MONITOR_CURRENT_LAUNCH_ID='launch-111'; return 0
}
quota_monitor_dismiss() { printf 'dismiss\n' >> "$REFRESH_TRACE"; return 0; }
quota_monitor_panel_open() { return 0; }
quota_monitor_owner_guard() { return 0; }
quota_monitor_open_usage() { printf 'open\n' >> "$REFRESH_TRACE"; QUOTA_REFRESH_SEQ=1; return 0; }
quota_usage_refresh_begin() { printf 'begin\n' >> "$REFRESH_TRACE"; QUOTA_REFRESH_SEQ=1; return 0; }
quota_usage_refresh_failure() { return 0; }
quota_panel_reset_epoch() { echo $(( $(date +%s) + 3600 )); }
quota_frame_stale() { return 1; }
quota_panel_log_observation() { :; }
QUOTA_PANEL_LAST=""
if quota_monitor_refresh >/dev/null 2>&1; then
  if [[ "$(grep -c '^dismiss$' "$REFRESH_TRACE")" == "1" ]] \
     && [[ "$(grep -c '^open$' "$REFRESH_TRACE")" == "1" ]] \
     && ! grep -q '^send:r$' "$REFRESH_TRACE"; then
    pass "clean 面板只在网络到期时收起并重开一次；读完不再关闭，也不发送无效 r"
  else
    fail "clean 面板生命周期错误：$(tr '\n' ' ' < "$REFRESH_TRACE")"
  fi
else
  fail "clean 面板重开用例未完成"
fi

: > "$REFRESH_TRACE"
REFRESH_FRAME="$PANEL_OK"$'\nUsage endpoint is rate limited. Press r to retry'
QUOTA_PANEL_LAST=""
if quota_monitor_refresh >/dev/null 2>&1 \
   && grep -q '^begin$' "$REFRESH_TRACE" \
   && grep -q '^send:r$' "$REFRESH_TRACE" \
   && ! grep -qE '^(dismiss|open)$' "$REFRESH_TRACE"; then
  pass "错误页到期时只按一次 r retry，不重开第二个请求；成功后仍保留面板"
else
  fail "错误页没有走单次 r retry：$(tr '\n' ' ' < "$REFRESH_TRACE")"
fi

: > "$REFRESH_TRACE"
REFRESH_FRAME="$PANEL_OK"
quota_monitor_owner_guard() { printf 'owner-guard\n' >> "$REFRESH_TRACE"; return 1; }
quota_frame_stale() { printf 'stale-check\n' >> "$REFRESH_TRACE"; return 0; }
quota_monitor_recover_stale_frame() { printf 'stale-restart\n' >> "$REFRESH_TRACE"; return 0; }
if ! quota_monitor_refresh >/dev/null 2>&1 \
   && grep -q '^owner-guard$' "$REFRESH_TRACE" \
   && ! grep -qE '^(stale-check|stale-restart)$' "$REFRESH_TRACE"; then
  pass "采样期账号漂移先被 owner guard 拦下，不进入 stale 判断或重启 UI"
else
  fail "stale 自愈抢在 panel-after 身份 bracket 前运行：$(tr '\n' ' ' < "$REFRESH_TRACE")"
fi
unset -f sleep; _tmux_guard_install   # 不留裸奔窗口：清桩即重装闸
_stub_restore quota_monitor_prepare_owner quota_monitor_dismiss quota_monitor_panel_open \
              quota_monitor_owner_guard quota_monitor_open_usage quota_usage_refresh_begin \
              quota_usage_refresh_failure quota_panel_reset_epoch quota_frame_stale quota_panel_log_observation
_stub_restore quota_monitor_recover_stale_frame

echo "── 采样：窗口内要取最大帧，不能取「第一个稳定的」──"
# 这是修复的另一半。旧规则「连续 N 次一致就收下」在「缓存帧先出现且重复多次、真值后到」
# 的序列上会收下缓存帧——而这正是实测的形态（面板 +1s 给缓存、+2s 才刷新，且拉取有节流）。
# ⚠️ 面板时刻必须动态生成为未来：写死 "Resets 3:29pm" 的话，现实时间一过 15:29，
# 这一帧就真的属于过期窗口，被 stale 规则**正确地**拒掉——测试会在下午定时变红。
# ⚠️ 必须锁 LC_ALL=C：date 的 %P/%b 是**跟随 locale** 的，本机中文环境下 `%P` 输出
#    「下午」而不是「pm」，喂给解析器就是一个现实中根本不会出现的字符串——
#    cc 面板永远是英文。不锁的话这几条用例测的不是生产逻辑，而是本机 locale，
#    且失败文案会显示成解析器坏了，把人引向错误方向。
PANEL_SESS_RESET=$(LC_ALL=C TZ=CST-8 date -d '+2 hours' '+%-I:%M%P')
PANEL_WEEK_RESET=$(LC_ALL=C TZ=CST-8 date -d '+3 days' '+%b %-d, %-I:%M%P')
mk_panel() {  # $1=session% $2=week%
  # 末尾那行 composer 是必需的：refresh 会先确认 /usage 真落进 composer 才回车
  printf '   Current session\n   ███   %s%% used\n   Resets %s (Asia/Shanghai)\n\n   Current week (all models)\n   ███   %s%% used\n   Resets %s (Asia/Shanghai)\n❯ /usage\n' "$1" "$PANEL_SESS_RESET" "$2" "$PANEL_WEEK_RESET"
}
# 序列：缓存帧 0% 连出 4 次（足够骗过 stable-2），真值 95% 后到
FRAMES=(0 0 0 0 95 95 95 95 95 95 95 95 95 95 95 95 95 95 95 95 95 95 95 95)
FRAME_COUNTER="$TMP/frame-i"; echo 0 > "$FRAME_COUNTER"
tmux() {   # 只桩 capture-pane，其余调用一律成功
  if [[ "${1:-}" == "capture-pane" ]]; then
    # ⚠️ 计数必须落文件：调用方是 $(tmux ...) 命令替换，跑在子 shell 里，
    # 桩函数改的变量传不回父 shell（本会话早先在另一个桩上踩过同一个坑）。
    local i; i=$(cat "$FRAME_COUNTER" 2>/dev/null || echo 0)
    echo $(( i + 1 )) > "$FRAME_COUNTER"
    mk_panel "${FRAMES[$i]:-95}" 50; return 0
  fi
  return 0
}
_stub_save quota_monitor_alive quota_monitor_dismiss quota_monitor_panel_open \
           quota_monitor_owner_guard quota_account_guard quota_session_created \
           quota_monitor_live_launch_id quota_monitor_single_pane_id quota_snapshot
sleep() { :; }                                  # 采样循环里的 sleep 直接跳过
quota_monitor_alive() { return 0; }
quota_monitor_dismiss() { return 0; }
quota_monitor_panel_open() { return 0; }
quota_monitor_owner_guard() { return 0; }
quota_account_guard() { QUOTA_GUARD_EMAIL="s@x"; QUOTA_GUARD_UUID="u"; return 0; }
quota_session_created() { echo 111; }
quota_monitor_live_launch_id() { echo launch-111; }
quota_monitor_single_pane_id() { echo %1; }
quota_snapshot() { printf '0\tu\ts@x\t0\t\t0\t\n'; }
QUOTA_STATE="$TMP/sample-state.json"
# monitor owner/代际预置成一致，避免走进重启分支（那条路要真等 40s 就绪）
echo '{"monitor_account":"s@x","monitor_uuid":"u","monitor_session_created":111,"monitor_launch_id":"launch-111"}' > "$QUOTA_STATE"
QUOTA_CACHE_MTIME=""
QUOTA_PANEL_LAST=""
if quota_monitor_refresh >/dev/null 2>&1; then
  IFS=$'\t' read -r sm_five sm_week _ _ <<< "$QUOTA_PANEL_LAST"
  if [[ "$sm_five" == "95" ]]; then
    pass "缓存帧 0% 连出 4 次仍取到真值 95%（窗口内取最大，不取第一个稳定的）"
  else
    fail "采样取到 ${sm_five}%，应为 95%——「第一个稳定帧」正是旧规则会收下缓存帧的原因"
  fi
else
  fail "采样整体失败"
fi
# ── 场景 B：five 持平但 week 前进 ──
# 只按 five 取最大会把这种帧当成"没进步"丢掉。周额度粒度更粗、爬得更慢，
# 常常是它先动而 five 还没跳格；漏掉它会让周额度的观测慢一整轮。
FRAMES_W=(10 10 10 10 13 13 13 13 13 13 13 13 13 13 13 13 13 13 13 13 13 13 13 13)
echo 0 > "$FRAME_COUNTER"
tmux() {
  if [[ "${1:-}" == "capture-pane" ]]; then
    local i; i=$(cat "$FRAME_COUNTER" 2>/dev/null || echo 0)
    echo $(( i + 1 )) > "$FRAME_COUNTER"
    mk_panel 50 "${FRAMES_W[$i]:-13}"; return 0
  fi
  return 0
}
echo '{"monitor_account":"s@x","monitor_uuid":"u","monitor_session_created":111,"monitor_launch_id":"launch-111"}' > "$QUOTA_STATE"
QUOTA_CACHE_MTIME=""; QUOTA_PANEL_LAST=""
if quota_monitor_refresh >/dev/null 2>&1; then
  IFS=$'\t' read -r sw_five sw_week _ _ <<< "$QUOTA_PANEL_LAST"
  if [[ "$sw_week" == "13" ]]; then
    pass "five 持平(50%)但 week 由 10→13 时取到 13（不只按 five 取最大）"
  else
    fail "取到 week=${sw_week}%，应为 13——只按 five 比较会漏掉这类新帧"
  fi
else
  fail "场景 B 采样失败"
fi

unset -f sleep mk_panel; _tmux_guard_install   # 不留裸奔窗口：清桩即重装闸
_stub_restore quota_monitor_alive quota_monitor_dismiss quota_monitor_panel_open \
              quota_monitor_owner_guard quota_account_guard quota_session_created \
              quota_monitor_live_launch_id quota_monitor_single_pane_id quota_snapshot

echo "── 面板解析：必须跳过 Current week (Fable) 那段 ──"
# fixture 是 2026-08-11 从活体监控会话抓的真实面板原文。
# 第一版解析取「Current week 之后第一个 % used」，会抓到 Fable 那段的 2%，
# 把周额度 87% 读成 2% —— 那会让"周额度快满"完全看不见。
if pr=$(quota_panel_parse "$(read_fx usage-panel.txt)"); then
  IFS=$'\t' read -r p_s p_w p_sr p_wr <<< "$pr"
  if [[ "$p_s" == "38" && "$p_w" == "87" ]]; then
    pass "session=38% week=87%（没把 Fable 的 2% 当成周额度）"
  else
    fail "面板数值解析错误（session=$p_s week=$p_w，期望 38/87）"
  fi
  se=$(quota_panel_reset_epoch "$p_sr" || echo "")
  we=$(quota_panel_reset_epoch "$p_wr" || echo "")
  if [[ "$(date -d "@${se:-0}" '+%H:%M')" == "15:29" ]]; then
    pass "session Resets 3:29pm → 本地 15:29"
  else
    fail "session reset 解析错误（got=$(date -d "@${se:-0}" '+%m-%d %H:%M')）"
  fi
  if [[ "$(date -d "@${we:-0}" '+%m-%d %H:%M')" == "08-13 14:59" ]]; then
    pass "week Resets Aug 13, 2:59pm → 08-13 14:59（带日期的形态也认）"
  else
    fail "week reset 解析错误（got=$(date -d "@${we:-0}" '+%m-%d %H:%M')）"
  fi
else
  fail "面板解析整体失败"
fi

echo "── 接受线：周额度只剩一点也要用，不能干等 ──"
# 周额度花完要等好几天，干等换不来任何东西 ⇒ 周的接纳线必须**等于**切换线，把它榨到最后
# 一点。接纳线一旦低于切换线，就会出现「手里还有额度却判定无处可切、整台机器停下来等」。
# 五小时相反：几小时自己回血，等待真有收益，所以那一侧留余量是对的。
# 🔴 上游把这条写成两个常量的比较（QUOTA_ACCEPT_PCT_WEEK == QUOTA_SWITCH_PCT_WEEK）。
#    本仓没有独立的接纳线常量（见「两个窗口各自的阈值」那组的记录），照搬会读到一个
#    不存在的变量。⇒ 改成直接测承重的那个表达式：一个 week 恰好差 1 点的候选必须被接纳。
#    ⭐ 这也比原来那条强一点——常量相等不等于决策真的用了它。
QUOTA_STATE="$TMP/accept-week.json"
printf '{"account":"cur@x","accounts":{"cur@x":{"five":95,"week":10},"lastdrop@x":{"five":10,"week":%s}}}' \
  "$(( QUOTA_SWITCH_PCT_WEEK - 1 ))" > "$QUOTA_STATE"
if [[ "$(quota_switch_pick 'cur@x' || echo none)" == "lastdrop@x" ]]; then
  pass "周额度只剩 1 点的候选仍被接纳（不会出现「还有额度却干等」）"
else
  fail "周额度还剩 1 点的候选被挡在外面，那段额度会被白白等掉"
fi

echo "── capacity 展示层必须容忍 null 字段 ──"
# 2026-08-12 实撞：手工清零比值累加器后 cycles 还在而 ratio 已 null，
# `null * 100` 让整条 capacity 命令报错退出。它是给人看状态的命令，
# **状态异常时恰恰最需要它还能跑**——一个 null 就把诊断工具关掉是最坏的时机。
QUOTA_STATE="$TMP/nullcap.json"; QUOTA_CACHE_MTIME=""
cat > "$QUOTA_STATE" <<'JSON'
{"account":"n@x","accounts":{"n@x":{"five":10,"week":20}},
 "capacity":{"updated":1786000000,"accounts_known":1,"week_used_total":20,
             "week_remaining_total":80,"five_remaining_total":90,
             "week_remaining_cycles":6.7,"week_five_ratio":null,
             "week_five_ratio_measured":null}}
JSON
if out=$(quota_cmd_capacity 2>&1) && ! printf '%s' "$out" | grep -qi 'error'; then
  pass "ratio=null 时 capacity 仍正常输出（不再 null*100 崩掉）"
else
  fail "capacity 在 null 字段上报错：$(printf '%s' "$out" | grep -i error | head -1)"
fi
# ⚠️ 运行时输出在抽取时英文化过。断言跟着改文案，但**守的是同一件事**：
#    降级时必须说出「不可用」，而不是打印一个 null 让读的人自己猜。
if printf '%s' "$out" | grep -q 'ratio unavailable'; then
  pass "如实说明比值不可用，而不是打印一个 null"
else
  fail "缺少可读的降级说明：$(printf '%s' "$out" | tail -3)"
fi

echo "── 预估额度：外推与它的四道闸 ──"
ES="$TMP/estimate"; mkdir -p "$ES"
QUOTA_STATE="$ES/state.json"; QUOTA_CACHE_MTIME=""; QUOTA_LOG="$ES/quota.log"
_es_state() {  # $1=five $2=fetched_ts $3=burn_five $4=last_switch_ts
  printf '{"five_hour":%s,"seven_day":5,"fetched_ts":%s,"burn_rate_five":%s,"burn_rate_week":0,"last_switch_ts":%s}\n' \
    "$1" "$2" "$3" "$4" > "$QUOTA_STATE"; QUOTA_CACHE_MTIME=""
}
_es_state 50 1000 0.01 0            # 50% + 0.01%/s
V=$(quota_estimate_values 1100)     # 外推 100s → 51
[[ "$V" == "51 5" ]] && pass "按流速外推（50% + 0.01/s × 100s = 51%）" || fail "外推算错，得到 '$V'"
# ⚠️ lead 必须留在 QUOTA_ESTIMATE_MAX_LEAD(=180s) 以内，否则会先被「读数太旧就不外推」
#    那道闸挡掉，这条用例就变成在测另一件事了。
_es_state 85 1000 0.05 0
if quota_estimate_exceeds 1100; then pass "外推越过 90 线时报越线（85 + 0.05/s × 100s = 90）"; else fail "外推已达 90% 却没报越线"; fi
_es_state 85 1000 0.01 0
if quota_estimate_exceeds 1100; then fail "外推才 86% 就报越线"; else pass "外推未到线时不报越线"; fi
# ⚠️ 切号之后、真实读数之前不外推：那一刻的速度属于**上一个账号**，
#    拿旧账号烧得多快去推新账号，会在刚切完就立刻要求再切一次。
# ⚠️ 这条一开始写成 lead=600，结果**因为另一个原因**而绿：600 先撞上「读数超过 180s
#    就不外推」那道闸，于是「切号后不外推」拆没拆都一样通过。变异测试当场戳穿了它。
#    所以 lead 必须留在 180 以内，让这条用例只可能因为要测的那道闸而通过。
_es_state 85 1000 0.05 1050
if quota_estimate_exceeds 1100; then fail "切号后仍用旧账号流速外推 —— 会刚切完就再切"; else pass "切号后到首次真实读数之前不外推"; fi
# ⚠️ 外推超过上限就停：那说明查询本身坏了，是另一个问题，不该靠外推硬撑。
_es_state 85 1000 0.01 0
if quota_estimate_exceeds $(( 1000 + QUOTA_ESTIMATE_MAX_LEAD + 1 )); then
  fail "读数已过期超过 ${QUOTA_ESTIMATE_MAX_LEAD}s 仍在外推"
else
  pass "读数过期超过上限就停止外推（不拿陈旧基准硬撑）"
fi

echo "── 提前查一次 /usage：触发条件与防抖 ──"
# 🔴 上游有三个触发源：屏上横幅自报、并发骤增、预估已越线。前两个读的是那套环境的会话
#    信息，**未抽取** ⇒ 本仓只剩「预估已越线」这一个。上游那两条断言（抓跨越不抓水位、
#    并发持续高位不重复触发）在本仓**没有对象**，不搬；不改成碰巧能过的形式。
#    ⇒ 代价要说清楚：本仓的提前查询只会被「预估外推越线」叫醒，而外推本身依赖已有读数；
#    「一批会话刚同时开工、百分比还没动但马上要飙」那个拐点，本仓看不见。
FR="$TMP/force-refresh"; mkdir -p "$FR"
QUOTA_STATE="$FR/state.json"; QUOTA_LOG="$FR/quota.log"
_stub_save quota_estimate_exceeds
_fr_state() {  # $1=last_force_ts
  printf '{"force_refresh_last_ts":%s}\n' "$1" > "$QUOTA_STATE"
  : > "$QUOTA_LOG"
}
quota_estimate_exceeds() { return 0; }
_fr_state 0
if quota_refresh_force_due 10000; then
  pass "预估已越线时触发一次提前查询"
else
  fail "预估越线也没触发提前查询"
fi
_fr_state $(( 10000 - QUOTA_FORCE_REFRESH_COOLDOWN + 5 ))
if quota_refresh_force_due 10000; then
  fail "防抖期内仍触发提前查询"
else
  pass "防抖期内不重复提前查询"
fi
# 正控：没有任何触发源成立时必须不触发，否则上面第一条用「恒真」实现也全绿。
_stub_save quota_estimate_exceeds
quota_estimate_exceeds() { return 1; }
_fr_state 0
if quota_refresh_force_due 10000; then
  fail "没有任何触发源成立却仍然提前查询 —— 上面那条是恒真"
else
  pass "正控：没有触发源时不查（上面那条不是恒真）"
fi
_stub_restore quota_estimate_exceeds
# ⚠️ 开关必须真能关掉。
_stub_save quota_estimate_exceeds
quota_estimate_exceeds() { return 0; }
_fr_state 0
QUOTA_FORCE_REFRESH=0
if quota_refresh_force_due 10000; then
  fail "QUOTA_FORCE_REFRESH=0 时仍提前查询（没有可回退的后门）"
else
  pass "QUOTA_FORCE_REFRESH=0 时完全关闭提前查询"
fi
QUOTA_FORCE_REFRESH=1
_stub_restore quota_estimate_exceeds
_stub_restore quota_estimate_exceeds

echo "── OAuth 响应解析：空字段不得让后面全部错位 ──"
# ⚠️ 2026-08-22～24 三天丢了 25 条样本（约 5%），全在当前账号低用量时段。
#    根因不是判据太严，是**解析错位**：tab 属于 IFS 空白字符，read 会把连续制表符
#    当成一个分隔符，中间字段一空后面全塌：
#        服务端 0 <空> 31 <ISO>  被读成  five=0 five_iso=31 week=<ISO> week_iso=空
#    而 resets_at 恰恰在窗口闲置时就是空的（服务端不返回没启用窗口的重置时刻）。
#    原来那条「四个字段都必须是数字」的判据一直在**掩盖**这个错位 —— 它把错位结果
#    挡在门外，于是从没表现成错误数值，只表现为 schema_error。
#    ⇒ 修解析（null 换 "-" 占位），不是放松判据。
SP="$TMP/schema-parse"; mkdir -p "$SP"
QUOTA_STATE="$SP/state.json"; QUOTA_CACHE_MTIME=""; QUOTA_LOG="$SP/quota.log"
QUOTA_SHADOW_OAUTH_STATE="$SP/sh.json"; QUOTA_SHADOW_OAUTH_EVENTS="$SP/ev.jsonl"
QUOTA_SHADOW_OAUTH_LOCK="$SP/sh.lock"
QUOTA_SHADOW_SCHEDULE_STATE="$SP/sc.json"; QUOTA_SHADOW_SCHEDULE_LOCK="$SP/sc.lock"
_stub_save quota_identity_read quota_shadow_oauth_http_fetch
quota_identity_read() { printf 'a@x\037u1\037u1\n'; }
_sp_try() {  # $1=响应 JSON → 打印 outcome
  printf '%s\n' '{"account":"a@x"}' > "$QUOTA_STATE"; QUOTA_CACHE_MTIME=""
  rm -f "$QUOTA_SHADOW_OAUTH_STATE" "$QUOTA_SHADOW_OAUTH_EVENTS"
  eval "quota_shadow_oauth_http_fetch() { printf '%s' \"\$SP_BODY\" > \"\$1\"; : > \"\$2\"; printf '200'; }"
  SP_BODY="$1" quota_shadow_oauth_sample >/dev/null 2>&1
  [[ -s "$QUOTA_SHADOW_OAUTH_EVENTS" ]] && tail -1 "$QUOTA_SHADOW_OAUTH_EVENTS" | jq -r '.outcome' || echo 无事件
}
if [[ "$(_sp_try '{"five_hour":{"utilization":40,"resets_at":"2030-01-01T05:00:00+00:00"},"seven_day":{"utilization":50,"resets_at":"2030-01-07T00:00:00+00:00"}}')" == "ok" ]]; then
  pass "两窗口齐全 → ok（基准，这条不过后面没意义）"
else
  fail "正常响应都解析不了"
fi
# ⚠️ 这条是修的那个 bug 本身：闲置窗口没有 resets_at，必须照常采信。
if [[ "$(_sp_try '{"five_hour":{"utilization":0},"seven_day":{"utilization":31,"resets_at":"2030-01-07T00:00:00+00:00"}}')" == "ok" ]] \
   && [[ "$(quota_state_get '.seven_day' '')" == "31" ]]; then
  pass "五小时窗口闲置(0%)、无 resets_at → 照常采信，周额度没被连坐丢掉"
else
  fail "闲置窗口仍被判成格式错误（三天丢 25 条的原因）"
fi
# ⚠️ 正控：放宽不能变成一律放行。使用率不为 0 却没有 resets_at，服务端本该知道
#    何时重置，那是真的畸形，必须仍然拒绝 —— 否则这条闸等于拆了。
if [[ "$(_sp_try '{"five_hour":{"utilization":40},"seven_day":{"utilization":50,"resets_at":"2030-01-07T00:00:00+00:00"}}')" == "schema_error" ]]; then
  pass "使用率不为 0 却缺 resets_at → 仍判畸形（放宽没变成一律放行）"
else
  fail "真畸形响应也被收下了 —— 判据被拆掉了"
fi
if [[ "$(_sp_try '{"five_hour":{"resets_at":"2030-01-01T05:00:00+00:00"},"seven_day":{"utilization":50,"resets_at":"2030-01-07T00:00:00+00:00"}}')" == "schema_error" ]]; then
  pass "缺 utilization → 判畸形（决策要用的就是它）"
else
  fail "缺使用率也被收下"
fi
_stub_restore quota_identity_read quota_shadow_oauth_http_fetch

echo "── 台账多上游共写：谁的观测新用谁的 ──"
# ⚠️ 2026-08-21 起台账有两个上游（/usage 面板、OAuth），将来还会有对话横幅。
#    「谁当主」这个问题被架构消掉了 —— 只按观测时刻定胜负。这样做有实测依据：
#    翻 10 天日志，面板因限流失明 27 次，其中 22 次（81%）发生在 five>=85% 的危险区，
#    失明中位 6.4 分钟；最要命一次从 91% 一路瞎到 100%。面板逼近阈值时收紧到 60s，
#    **问得越勤越容易被限流**，密度恰好在最需要的时候塌掉。OAuth 固定 180s 不塌。
#    ⇒ 两个上游失败时机不重合，并联比串联强。
UP="$TMP/upstream"; mkdir -p "$UP"
QUOTA_STATE="$UP/state.json"; QUOTA_CACHE_MTIME=""; QUOTA_LOG="$UP/quota.log"
_up_reset() {
  printf '%s\n' '{"account":"cur@x","five_hour":50,"seven_day":20,"fetched_ts":1000,
   "accounts":{"cur@x":{"five":50,"week":20,"checked_ts":1000,"source":"usage_panel"}}}' > "$QUOTA_STATE"
  QUOTA_CACHE_MTIME=""
}
_up_reset
quota_reading_apply oauth_api 1200 cur@x 66 22; _rc=$?; QUOTA_CACHE_MTIME=""
if (( _rc == 0 )) && [[ "$(quota_state_get '.five_hour' '')" == "66" ]] \
   && [[ "$(quota_state_get '.reading_source' '')" == "oauth_api" ]]; then
  pass "更新的观测写入并改写顶层决策字段，来源标成 oauth_api"
else
  fail "新观测没写进去（rc=$_rc five=$(quota_state_get '.five_hour' '')）"
fi
# ⚠️ 这条是要害：旧观测**绝不能**覆盖新的。两个上游各按自己的节拍跑，迟到的包一定会
#    出现；不挡住的话台账会在新旧值之间来回跳，切号判据跟着抖。
quota_reading_apply oauth_api 900 cur@x 11 11; _rc=$?; QUOTA_CACHE_MTIME=""
if (( _rc == 2 )) && [[ "$(quota_state_get '.five_hour' '')" == "66" ]]; then
  pass "更旧的观测被拒（rc=2），台账不回退"
else
  fail "旧观测覆盖了新值 —— 台账会在新旧之间来回跳（rc=$_rc five=$(quota_state_get '.five_hour' '')）"
fi
# ⚠️ 非当前账号只更新自己那格。顶层 .five_hour 的语义是「**当前**账号还剩多少」，
#    把别人的数写进去会直接按错误水位切号。
quota_reading_apply oauth_api 1300 other@x 3 4; _rc=$?; QUOTA_CACHE_MTIME=""
if (( _rc == 0 )) && [[ "$(quota_state_get '.five_hour' '')" == "66" ]] \
   && [[ "$(quota_state_get '.accounts["other@x"].five' '')" == "3" ]]; then
  pass "写非当前账号只落到它自己那格，顶层纹丝不动"
else
  fail "写别的账号污染了顶层决策字段（顶层 five=$(quota_state_get '.five_hour' '')）"
fi
# ⚠️ 正控：上面三条都可能因为函数压根没生效而「碰巧通过」。这里确认拒绝逻辑
#    真的挂在**观测时刻**上，而不是恒拒——同一账号、更新的时刻，必须能再写进去。
quota_reading_apply oauth_api 1400 cur@x 71 23; _rc=$?; QUOTA_CACHE_MTIME=""
if (( _rc == 0 )) && [[ "$(quota_state_get '.five_hour' '')" == "71" ]]; then
  pass "再来一个更新的观测仍能写入（拒绝逻辑没退化成恒拒）"
else
  fail "新观测也被拒了 —— 闸恒拒等于把这条上游整个关掉"
fi
_up_reset

echo "── 回血盯梢：过点才查，查到就停 ──"
# ⚠️ 判据必须是**结构性**的：「快照拍摄时刻 < 回血时刻 <= 现在」＝手上这份是回血前拍的。
#    不能用「额度掉到多少以下」——那要挑一个阈值，而账号回血后可能立刻被别人用掉一截，
#    阈值判据会判成「还没回血」然后一直查下去，停不了。
WT="$TMP/watch"; mkdir -p "$WT"
QUOTA_SNAPSHOT_FILE="$WT/snap.json"
_WT_NOW=1787320000; _WT_RESET=$(( _WT_NOW - 600 ))
_wt_snap() {  # $1=快照拍摄时刻 $2=other 的 five_reset
  cat > "$QUOTA_SNAPSHOT_FILE" <<JSON
{"generated_at":$1,"accounts":[
 {"email":"cur@x","status":"active","is_current":true,"five_reset":$_WT_RESET,"week_reset":null},
 {"email":"other@x","status":"active","is_current":false,"five_reset":$2,"week_reset":null}]}
JSON
}
_wt_snap $(( _WT_RESET - 300 )) "$_WT_RESET"
if quota_reset_watch_pending "$_WT_NOW"; then
  pass "快照拍于回血前、现已过点 → 进入盯梢"
else
  fail "该盯没盯（后面几条就没意义了）"
fi
_wt_snap $(( _WT_RESET + 60 )) "$_WT_RESET"
if quota_reset_watch_pending "$_WT_NOW"; then
  fail "已经查到回血后的读数却还在盯 —— 停不下来，会一直烧请求"
else
  pass "查到回血后的读数 → 盯梢自动停"
fi
_wt_snap $(( _WT_NOW - 100 )) $(( _WT_NOW + 3600 ))
if quota_reset_watch_pending "$_WT_NOW"; then
  fail "回血时刻还没到就在盯 —— 白烧请求"
else
  pass "没到回血时刻不盯"
fi
# ⚠️ 当前账号不该开盯梢：它由 /usage 面板和 180s 影子采样各自覆盖，再开一路是重复。
_wt_snap $(( _WT_RESET - 300 )) null
if quota_reset_watch_pending "$_WT_NOW"; then
  fail "为当前账号也开了盯梢（重复覆盖，白烧请求）"
else
  pass "只盯非当前账号"
fi

echo "── 面板失灵时 OAuth 顶上：三道闸都得能拒 ──"
# ⚠️ 现状是面板读不到就整轮 return 1，一个数都不更新；持续失灵会让脚本拿着越来越旧的数，
#    而且**看不出自己在瞎**。OAuth 那条线每 180s 独立采当前账号，正好补这个缺口。
#    但它必须过三道闸，一道都不能省。
FB="$TMP/fallback"; mkdir -p "$FB"
QUOTA_SHADOW_OAUTH_STATE="$FB/shadow.json"
QUOTA_STATE="$FB/state.json"; QUOTA_CACHE_MTIME=""; QUOTA_LOG="$FB/quota.log"
_FB_NOW=1787320000
_fb_setup() {  # $1=采样账号 $2=观测时刻
  printf '%s\n' '{"account":"cur@x","five_hour":50,"seven_day":20,"accounts":{}}' > "$QUOTA_STATE"
  QUOTA_CACHE_MTIME=""; : > "$QUOTA_LOG"
  cat > "$QUOTA_SHADOW_OAUTH_STATE" <<JSON
{"last_attempt":{"outcome":"ok","observed_at":$2,
 "account":{"email":"$1"},
 "windows":{"five_hour":{"used_percentage":77},"seven_day":{"used_percentage":33}}}}
JSON
}
_fb_setup "cur@x" "$(( _FB_NOW - 60 ))"
if quota_oauth_fallback_apply "$_FB_NOW" "cur@x" \
   && [[ "$(quota_state_get '.five_hour' '')" == "77" ]] \
   && [[ "$(quota_state_get '.reading_source' '')" == "oauth_fallback" ]]; then
  pass "身份对、够新 → 顶上，并标明来源是 oauth_fallback"
else
  fail "该顶没顶上（five=$(quota_state_get '.five_hour' '') source=$(quota_state_get '.reading_source' '')）"
fi
# ⚠️ 闸一：身份不符绝不能用。那是**别人的额度**，拿来当自己的会切错号。
_fb_setup "someone_else@x" "$(( _FB_NOW - 60 ))"
if quota_oauth_fallback_apply "$_FB_NOW" "cur@x"; then
  fail "拿了别的账号的额度顶替当前账号 —— 会据此切错号"
else
  pass "采样账号与当前不一致 → 拒绝顶替"
fi
# ⚠️ 闸二：陈旧读数比没有更危险，会让脚本以为自己看得见。
_fb_setup "cur@x" "$(( _FB_NOW - QUOTA_OAUTH_FALLBACK_MAX_AGE - 1 ))"
if quota_oauth_fallback_apply "$_FB_NOW" "cur@x"; then
  fail "拿超期读数顶替 —— 脚本会以为自己看得见，其实在瞎"
else
  pass "采样超过 ${QUOTA_OAUTH_FALLBACK_MAX_AGE}s → 拒绝顶替"
fi
# ⚠️ 采样本身失败时也不能用（outcome 不是 ok）
_fb_setup "cur@x" "$(( _FB_NOW - 60 ))"
printf '%s\n' '{"last_attempt":{"outcome":"rate_limited","observed_at":'"$(( _FB_NOW - 60 ))"',"account":{"email":"cur@x"},"windows":{}}}' > "$QUOTA_SHADOW_OAUTH_STATE"
if quota_oauth_fallback_apply "$_FB_NOW" "cur@x"; then
  fail "拿一次失败的采样当读数用"
else
  pass "采样 outcome 不是 ok → 拒绝顶替"
fi

echo "── 账号额度快照：陈旧的必须当作没有 ──"
# ⚠️ 这条路的危险失败模式不是「读不到」，而是**读到一份旧的却当成新的**：
#    拿半小时前的额度排候选，会切到一个其实早就满了的账号，切过去立刻撞墙，
#    还白白消耗一次切号配额和防抖窗口。宁可判定「没有快照」，也不交出过期数据。
SN="$TMP/snapshot"; mkdir -p "$SN"
QUOTA_SNAPSHOT_FILE="$SN/snap.json"
QUOTA_STATE="$SN/state.json"; QUOTA_CACHE_MTIME=""; QUOTA_LOG="$SN/quota.log"
printf '%s\n' '{"account":"live1@x","accounts":{"live1@x":{"five":50,"week":20}}}' > "$QUOTA_STATE"
_snap_write() {  # $1=generated_at
  cat > "$QUOTA_SNAPSHOT_FILE" <<JSON
{"schema":1,"generated_at":$1,"current_account":"live1@x","accounts":[
 {"email":"live1@x","status":"active","five_hour":50,"seven_day":20,"five_reset":null,"week_reset":null,"outcome":"ok"},
 {"email":"live2@x","status":"active","five_hour":3,"seven_day":8,"five_reset":null,"week_reset":null,"outcome":"ok"}]}
JSON
}
_SN_NOW=1787300000
_snap_write "$_SN_NOW"
if quota_snapshot_read "$_SN_NOW" >/dev/null; then
  pass "新鲜快照可读"
else
  fail "新鲜快照被误判为不可用（后面几条就没意义了）"
fi
_snap_write "$(( _SN_NOW - QUOTA_SNAPSHOT_MAX_AGE - 1 ))"
if quota_snapshot_read "$_SN_NOW" >/dev/null; then
  fail "超过 ${QUOTA_SNAPSHOT_MAX_AGE}s 的陈旧快照仍被交出去 —— 会拿旧额度排候选"
else
  pass "陈旧快照判定为不可用（不交出过期数据）"
fi
# ⚠️ 未来时刻同样要拒。时钟跳变或别人写坏文件时，age 会算成负数；
#    只判「太旧」的写法会让这种明显异常的数据一路绿灯通过。
_snap_write "$(( _SN_NOW + 3600 ))"
if quota_snapshot_read "$_SN_NOW" >/dev/null; then
  fail "生成时刻在未来的快照被接受 —— 只判『太旧』漏掉了时钟异常这一半"
else
  pass "生成时刻在未来的快照也拒绝"
fi
: > "$QUOTA_SNAPSHOT_FILE"
if quota_snapshot_read "$_SN_NOW" >/dev/null; then fail "空快照被接受"; else pass "空快照判定为不可用"; fi

echo "── 快照现阶段只记账，不参与决策 ──"
# ⚠️ 放行前必须先攒证据。已有的一致性证据（±60s 内差 ≤2 点、98% 成功率）**全部来自
#    当前账号**的影子采样；查其他账号是另一条代码路径（不同 token、不同凭据文件），
#    目前只有几次手动 probe 的证据。所以先影子跑、对账，别急着让它改变行为。
_snap_write "$_SN_NOW"
_before=$(cat "$QUOTA_STATE")
: > "$QUOTA_LOG"
quota_snapshot_shadow_compare "$_SN_NOW" >/dev/null 2>&1
if [[ "$(cat "$QUOTA_STATE")" == "$_before" ]]; then
  pass "影子对账没有改动任何状态"
else
  fail "影子对账改了状态 —— 它现在只该记账"
fi
# ⚠️ 运行时输出在抽取时英文化过；断言跟着改文案，守的仍是同一件事——
#    对账必须**留下一条并排记录**，否则上面那条「状态没变」也可能只是因为它压根没跑。
if grep -q 'shadow: reconciliation only, never decides' "$QUOTA_LOG"; then
  pass "影子对账把快照与台账并排记了一笔（上一条不是因为它压根没跑）"
else
  fail "影子对账没产生记录：$(tail -1 "$QUOTA_LOG")"
fi
if [[ "$QUOTA_SNAPSHOT_DECIDE" == "0" ]]; then
  pass "放行开关默认关闭（QUOTA_SNAPSHOT_DECIDE=0）"
else
  fail "快照默认就参与决策了 —— 证据还不够，不该默认开"
fi

}

# ── the isolation gate, checked after every layer / 隔离闸，每一层跑完都查 ──
# ⚠️ Upstream this lived at the very end of the slow layer, so `--fast` alone never
#    checked it. The gate guards the 2026-08-19 incident (the regression reached into
#    production sessions), and "which layer did you run" is not a sensible input to
#    whether that check happens.
# ⚠️ 上游这一组在慢层末尾，于是单跑 --fast 从不检查它。这道闸守的是 2026-08-19
#    「回归伸手动了生产会话」，而「你跑的是哪一层」不该是「这个检查做不做」的输入。
run_isolation_check() {
echo "── 隔离闸：整轮回归不得触达真实 tmux ──"
# ⚠️ 守的是 2026-08-19 那次「测试动了生产会话」。统计的是**会改变状态**的调用
#    （send-keys / kill-session / new-session …）有没有漏到闸外。
if [[ ! -s "$TMUX_VIOLATIONS" ]]; then
  pass "全程没有未打桩的危险 tmux 调用（send-keys/kill/new-session 等）"
else
  fail "有 $(grep -c . "$TMUX_VIOLATIONS") 次危险调用漏到闸外：$(head -3 "$TMUX_VIOLATIONS" | tr '\n' ' ')"
fi
# ⚠️ 正控：闸必须真的会红。故意触发一次，确认它记得下来——否则上面那条恒绿，等于没测。
_tmux_probe="$TMP/tmux-violations.snapshot"
cp "$TMUX_VIOLATIONS" "$_tmux_probe"
tmux send-keys -t __fake_probe_session__ Escape >/dev/null 2>&1 || true
if (( $(grep -c . "$TMUX_VIOLATIONS") > $(grep -c . "$_tmux_probe") )); then
  pass "闸在故意触发时确实记录了违规（上一条不是恒绿）"
else
  fail "闸抓不住 send-keys —— 上一条断言没有区分度"
fi
cp "$_tmux_probe" "$TMUX_VIOLATIONS"
}

case "$TEST_LAYER" in
  shadow) run_shadow_tests ;;
  slow) run_decision_tests; run_slow_tests ;;
  fast|all) run_extraction_tests; run_fast_tests; run_monitor_tests; run_cadence_tests; run_reading_round_tests
            [[ "$TEST_LAYER" == all ]] && { run_shadow_tests; run_decision_tests; run_slow_tests; } ;;
  *) echo "layer $TEST_LAYER not populated yet" ;;
esac
run_isolation_check
echo
printf 'PASS %d   FAIL %d\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
