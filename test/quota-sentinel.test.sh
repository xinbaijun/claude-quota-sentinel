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

case "$TEST_LAYER" in
  fast|all) run_extraction_tests; run_fast_tests ;;
  *) echo "layer $TEST_LAYER not populated yet" ;;
esac
echo
printf 'PASS %d   FAIL %d\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
