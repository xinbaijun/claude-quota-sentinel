#!/usr/bin/env bash
#
# Does a switch ever put a credential — or an account address — on a command line?
#
# This is the control for the claim "tokens never reach argv or the logs". It ships in
# the repository because a control that lives in someone's scratch directory cannot be
# re-run, cannot be reviewed, and cannot be migrated into a regression suite. Everything
# here is synthetic: addresses are @example.invalid, tokens are literal fake strings, and
# the target home is a throwaway directory. It must stay runnable on a machine that has
# never logged into Claude.
# 这是「token 不进 argv/日志」这条断言的正控。它进仓,是因为放在某人临时目录里的正控
# 无法复跑、无法复核、也无法迁进回归套件。全部合成:地址 @example.invalid、token 是字面
# 假串、目标 home 是一次性目录。它必须在一台从未登录过 Claude 的机器上照样能跑。
#
# Usage: tools/credential-argv-control.sh
# Exit:  0 every control behaved AND no secret was found | 1 otherwise
#
# 🔴 Read this before trusting any zero below.
#
#    Three separate things have to hold before "0 hits" means anything, and an earlier
#    version of this control only established the first:
#
#      1. LIVE      — the sampler is running and can see short-lived processes at all.
#      2. SENSITIVE — the canary carries a string that the SAME pattern used to hunt the
#                     real secret will match. The earlier version's canary said
#                     "positive-control" while the real search looked for a different
#                     shape, so its 154 sightings proved the sampler was alive and
#                     nothing whatsoever about whether the real pattern had teeth.
#      3. BLIND     — with the sampler switched off, the identical canary must produce
#                     zero. Without this, "0" and "we never looked" are the same output.
#
#    ⭐ Only after all three does a zero from the real run count as a negative result.
#
# 🔴 在相信下面任何一个「0」之前先读这段。要让「0 命中」有意义,必须同时成立三件事,
#    而本控的上一版只立住了第一件:
#      1. 活着   —— 采样器在跑,且确实看得见短命进程。
#      2. 有灵敏度 —— canary 携带的串,必须能被**搜真 secret 用的那同一个模式**匹配。
#         上一版的 canary 写的是 "positive-control",而真实搜索找的是另一个形状 ⇒
#         那 154 次命中只证明采样器活着,对「真模式有没有牙」什么都没证。
#      3. 瞎了   —— 关掉采样器、放同一个 canary,必须得 0。没有这一格,「0」与
#         「我们压根没看」输出完全一样。
#    ⭐ 三格都过之后,真实那轮的 0 才算一个阴性结果。

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
BOX="$(mktemp -d "${TMPDIR:-/tmp}/cred-argv.XXXXXX")" || exit 1
trap 'rm -rf "$BOX"' EXIT

# The ONE pattern. The real hunt and every canary use this same variable, so a canary
# that is seen proves this exact pattern can match. Divergence here is the defect the
# header describes.
# 唯一的那个模式。真实搜索与每个 canary 都用这同一个变量,于是「canary 被看到」
# 证明的正是这个模式能匹配。两边写成不同的串,就是上面讲的那个缺陷。
TOKEN_RE='FAKE-(ACCESS|REFRESH)-TOKEN-[a-z]+'
ADDR_RE='[a-z]+@example\.invalid'

pass=0; fail=0
ck(){ local ok="$1" id="$2" desc="$3" detail="${4:-}"
  if [ "$ok" = 1 ]; then printf 'PASS  %-8s %s\n' "$id" "$desc"; pass=$((pass+1))
  else printf 'FAIL  %-8s %s\n          %s\n' "$id" "$desc" "$detail"; fail=$((fail+1)); fi; }

mkacct(){ mkdir -p "$1/.claude"
  printf '{"oauthAccount":{"emailAddress":"%s@example.invalid","accountUuid":"%s"}}\n' "$2" "$3" > "$1/.claude.json"
  printf '{"claudeAiOauth":{"accessToken":"FAKE-ACCESS-TOKEN-%s","refreshToken":"FAKE-REFRESH-TOKEN-%s","expiresAt":4102416000000,"subscriptionType":"max"}}\n' "$2" "$2" > "$1/.claude/.credentials.json"
  chmod 600 "$1/.claude/.credentials.json"; }

mkacct "$BOX/home"  alfa  11111111-1111-1111-1111-111111111111
mkacct "$BOX/src"   bravo 22222222-2222-2222-2222-222222222222
mkacct "$BOX/spare" alfa  11111111-1111-1111-1111-111111111111

SAMPLES="$BOX/ps-samples.log"; : > "$SAMPLES"
sampler_start(){ ( while :; do ps -eo args >> "$SAMPLES" 2>/dev/null; done ) & SAMP=$!; sleep 0.2; }
sampler_stop(){ [ -n "${SAMP:-}" ] && kill "$SAMP" 2>/dev/null; wait "$SAMP" 2>/dev/null; SAMP=""; }
# a canary whose argv matches TOKEN_RE, i.e. the very pattern used to hunt the real one
canary(){ bash -c 'exec -a "canary FAKE-ACCESS-TOKEN-canary" sleep 0.6' & sleep 0.8; }
canary_addr(){ bash -c 'exec -a "canary canary@example.invalid" sleep 0.6' & sleep 0.8; }

# ── control 1 + 2: LIVE and SENSITIVE, in one observation ────────────────────────────
sampler_start; canary; sampler_stop
n=$(/usr/bin/grep -acE "$TOKEN_RE" "$SAMPLES")
ck "$([ "$n" -gt 0 ] && echo 1 || echo 0)" LIVE+SENS \
   "sampler sees a canary carrying the same pattern used to hunt the real token" \
   "canary sightings=$n, expected >0 (a 0 here voids every later 0)"

: > "$SAMPLES"; sampler_start; canary_addr; sampler_stop
na=$(/usr/bin/grep -acE "$ADDR_RE" "$SAMPLES")
ck "$([ "$na" -gt 0 ] && echo 1 || echo 0)" ADDR-SENS \
   "sampler sees a canary carrying an account address" \
   "address canary sightings=$na, expected >0"

# ── control 3: BLIND — the same canary, with nobody looking, must yield zero ─────────
: > "$SAMPLES"; canary
nb=$(/usr/bin/grep -acE "$TOKEN_RE" "$SAMPLES")
ck "$([ "$nb" -eq 0 ] && echo 1 || echo 0)" BLIND \
   "with the sampler stopped the identical canary yields zero" \
   "sightings=$nb while not sampling, expected 0"

# ── the measurement: an automatic switch, through the real decision path ─────────────
# Exhaustive channel first: a shim on the only external executable records EVERY spawn.
SHIM="$BOX/shim"; mkdir -p "$SHIM"
cat > "$SHIM/docker" <<'SH'
#!/usr/bin/env bash
printf '%s\0' "$0" "$@" >> "$SPAWNLOG"; printf '\n---SPAWN---\n' >> "$SPAWNLOG"
exit 1
SH
chmod +x "$SHIM/docker"
export SPAWNLOG="$BOX/spawned-argv.log"; : > "$SPAWNLOG"

# ── the exhaustive channel for jq / jq 的穷举通道 ────────────────────────────────────
#
# 🔴 Sampling `ps` can miss a process. `jq` calls are the shortest-lived things here --
#    the sampler can run flat out and still never observe one. So `jq` is shimmed on PATH
#    and every single invocation records its full argv. No gap, and no table of variable
#    names: whatever reaches a jq command line lands in this log, whether or not anyone
#    remembered to add the variable that carried it to a pattern list.
# 🔴 采样 `ps` 会漏掉进程。这里最短命的就是 `jq` 调用——采样器全速跑也可能一次都没看见。
#    所以给 `jq` 挂 PATH shim，**每一次**调用都把完整 argv 记下来。既没有采样间隙，
#    也不依赖任何变量名表：**凡是上了 jq 命令行的东西都会落进这个日志**，不管有没有人
#    记得把携带它的那个变量加进模式清单。
# ⭐ 这一条与 test 里那条静态 `--arg` 判据**盲区不重叠**，是刻意的：静态那条按变量名认地址、
#    看得见没跑到的代码；这条不认名字、但只看得见真跑到的路径。
# ⭐ Deliberately non-overlapping blind spots with the static `--arg` check in the suite:
#    that one knows names and sees code that never ran; this one knows no names but sees
#    only paths that actually executed.
export JQARGV="$BOX/jq-argv.log"; : > "$JQARGV"
REAL_JQ="$(command -v jq)"
cat > "$SHIM/jq" <<SH
#!/usr/bin/env bash
printf '%s\0' "\$@" >> "\$JQARGV"; printf '\n---JQ---\n' >> "\$JQARGV"
exec "$REAL_JQ" "\$@"
SH
chmod +x "$SHIM/jq"

# The switch binary is invoked by absolute path, so a PATH shim cannot intercept it.
# Wrapping it via QUOTA_ACCOUNT_SWITCH_BIN records the exact invocation P1-3 was about,
# exhaustively -- no sampling gap.
# 切号程序是按绝对路径调用的,PATH shim 拦不到。用 QUOTA_ACCOUNT_SWITCH_BIN 包一层,
# 就能无采样间隙地记下 P1-3 说的那一次调用。
cat > "$SHIM/switch-wrapper" <<SH
#!/usr/bin/env bash
printf '%s\0' "\$0" "\$@" >> "$BOX/switchbin-argv.log"; printf '\n---SPAWN---\n' >> "$BOX/switchbin-argv.log"
exec python3 "$REPO/account-switch" "\$@"
SH
chmod +x "$SHIM/switch-wrapper"
: > "$BOX/switchbin-argv.log"

export QS_STATE_DIR="$BOX/state"; mkdir -p "$QS_STATE_DIR"
cat > "$QS_STATE_DIR/quota-state.json" <<'ST'
{ "account": "alfa@example.invalid",
  "accounts": { "alfa@example.invalid": {"five":99,"week":50},
                "bravo@example.invalid": {"five":3,"week":4} } }
ST
export ACCOUNT_SWITCH_ROOT_HOME="$BOX/home"
export ACCOUNT_SWITCH_HOST_GLOBS="$BOX/src:$BOX/spare"

# 🔴 驱动脚本落成文件，账号地址走 env 进去 —— **不能**写成 `bash -c "…alfa@example.invalid…"`。
#    那样地址会进入 `bash` 自己的 argv，而 `ps` 采样器照单全收：实测一次跑出 425 次命中，
#    再跑两次却是 0。⭐ 那不是被测代码在漏，是**脚手架在漏**，而且它漏得时有时无 ⇒
#    这条断言会变成一条**忽绿忽红**的断言。恒红训练出「看到红也照过」，忽绿忽红训练出
#    「再跑一次就好了」，两者一样有害。
# 🔴 The driver is written to a FILE and addresses arrive through the environment -- NOT
#    `bash -c "…alfa@example.invalid…"`, which would put the address into bash's own argv
#    where the `ps` sampler picks it up: measured 425 hits on one run and 0 on the next two.
#    ⭐ That is the SCAFFOLDING leaking, not the code under test, and it leaks
#    intermittently -- which would make this assertion flap. A permanently red check
#    teaches people to click past red; a flapping one teaches them to just run it again.
cat > "$BOX/driver.sh" <<'DRV'
cd "$QS_CTL_REPO" || exit 1
source lib/config.sh && source lib/reading.sh && source lib/monitor.sh \
  && source lib/detect.sh && source lib/state.sh && source lib/switch.sh
now=$(date +%s)
# 切号决策先跑：下面那几个读数层调用会改写台账水位，跑在前面会让切号条件不再成立。
# The switch decision runs FIRST: the reading-layer calls below rewrite the ledger levels,
# and running them first would stop the switch from being triggered at all.
quota_decide_once "$now"
# ⚠️ 地址落点大多在读数层与状态层，而**那些每一拍轮询都在跑**，切号只是偶发 ——
#    只测切号会把持续暴露面整个测漏。
# ⚠️ Most address sites are in the reading and state layers, and THOSE run on every poll
#    while a switch is occasional -- measuring only the switch misses the continuous part.
quota_reading_apply usage_panel "$now" "$QS_CTL_ACCT" 42 17 $((now+3600)) $((now+86400))
quota_source_log_usage "$now" "$QS_CTL_ACCT" uuid-alfa 42 null 17 null
quota_source_log_usage_failure "$now" "$QS_CTL_ACCT" uuid-alfa panel_unreadable
quota_usage_refresh_begin "$now" "$QS_CTL_ACCT" uuid-alfa 4242 launch-x near
quota_ratio_update "$now" "$QS_CTL_ACCT" 42 17
quota_account_guard control-probe "$QS_CTL_ACCT"
quota_monitor_launch_command "$QS_CTL_ACCT" uuid-alfa 4242 launch-x
DRV

: > "$SAMPLES"; sampler_start
PATH="$SHIM:$PATH" QUOTA_STATE="$QS_STATE_DIR/quota-state.json" \
  QUOTA_SWITCH_LEDGER="$QS_STATE_DIR/switches.jsonl" QUOTA_SWITCH_MODE=on \
  QUOTA_ACCOUNT_SWITCH_BIN="$SHIM/switch-wrapper" \
  QUOTA_LOG_FILE="$QS_STATE_DIR/quota.log" \
  QUOTA_SHADOW_ENABLED=1 \
  QUOTA_SHADOW_STATUSLINE_OWNER_DIR="$QS_STATE_DIR/statusline-owner" \
  QS_CTL_REPO="$REPO" QS_CTL_ACCT="alfa@example.invalid" \
  bash "$BOX/driver.sh" > "$BOX/run.out" 2> "$BOX/run.err"
sleep 0.3; sampler_stop

switched=$(python3 -c "import json;print(json.load(open('$BOX/home/.claude.json'))['oauthAccount']['emailAddress'])" 2>/dev/null)
ck "$([ "$switched" = "bravo@example.invalid" ] && echo 1 || echo 0)" SWITCHED \
   "the automatic path actually performed the switch (else nothing was measured)" \
   "account is now '$switched', expected bravo@example.invalid"

t_ps=$(/usr/bin/grep -acE "$TOKEN_RE" "$SAMPLES")
t_spawn=$(/usr/bin/grep -acE "$TOKEN_RE" "$SPAWNLOG")
t_log=$(cat "$QS_STATE_DIR/quota.log" "$QS_STATE_DIR/switches.jsonl" "$BOX/run.out" "$BOX/run.err" 2>/dev/null | /usr/bin/grep -acE "$TOKEN_RE")
ck "$([ "$t_ps" -eq 0 ] && echo 1 || echo 0)"    TOKEN-PS    "no token in any sampled process argv"        "sightings=$t_ps"
ck "$([ "$t_spawn" -eq 0 ] && echo 1 || echo 0)" TOKEN-SPAWN "no token in any spawned argv (exhaustive)"   "sightings=$t_spawn"
ck "$([ "$t_log" -eq 0 ] && echo 1 || echo 0)"   TOKEN-LOG   "no token in the log, the ledger, or output"  "sightings=$t_log"

# ── the account ADDRESS: one assertion, and one measurement that is NOT an assertion ──
#
# The assertion covers what was actually fixed: the switch binary is now handed its
# selector on stdin (`--use -`), so its own argv carries no address.
a_bin=$(/usr/bin/grep -acE "$ADDR_RE" "$BOX/switchbin-argv.log")
ck "$([ "$a_bin" -eq 0 ] && echo 1 || echo 0)" ADDR-BIN \
   "the switch binary is invoked with no address on its argv (selector via stdin)" \
   "sightings=$a_bin -- expected 0 since --use - reads the selector from stdin"

# ── the account ADDRESS, now asserted rather than reported ──────────────────────────
#
# This block used to print a NOTE instead of a check, and the reason it gave was sound at
# the time: account addresses really did still reach argv from `jq --arg <address>` call
# sites in the reading and state layers, they ran on every poll, and shipping a check that
# cannot pass teaches people to click past red. Those call sites are now gone -- the values
# travel in the environment -- so the number has become a claim that can carry a check.
# 这一格从前印的是 NOTE 而不是判据，当时的理由是成立的：账号地址确实仍从读数层与状态层的
# `jq --arg <地址>` 进 argv、每一拍都在跑，而发布一条**永远不可能通过**的检查会训练出
# 「看到红也照过」。那些落点现在没有了（值改走环境变量）⇒ 这个数字才配得上一条判据。
#
# 🔴 买到的是什么，说准确：`/proc/<pid>/cmdline` 世界可读，`/proc/<pid>/environ` 只同 UID
#    可读 ⇒ 准确说法是「**不再对任意用户可读**」，**不是**「地址不再暴露」。在一台你本来
#    就是 root 的机器上，root 一直都读得到 `environ`。
# 🔴 State plainly what this buys: `/proc/<pid>/cmdline` is world-readable while
#    `/proc/<pid>/environ` is readable only by the same UID. The accurate claim is
#    "no longer readable by ANY user", NOT "the address is no longer exposed". On a box
#    where you are root anyway, root could always read `environ`.
# ⚠️ `ps -eo args` samples the WHOLE system, so this assertion has three sensitivity
#    controls above it and **no specificity control**: it cannot tell "our process leaked an
#    address" from "some unrelated process on this machine happens to contain a string that
#    matches". On a shared host that is a false red pointing at this repository.
#    ⇒ The judgement is not weakened; the DIAGNOSIS printed with it is. A tool should report
#    what it observed and let the reader see whether the hit is even ours.
# ⚠️ `ps -eo args` 采的是**全系统**，所以这条断言上面有三条灵敏度控制、**没有特异性控制**：
#    它分不出「我们的进程漏了地址」与「这台机器上某个无关进程恰好含一个匹配的串」。
#    在共享宿主上那就是一次指向本仓的假红。
#    ⇒ 不弱化判据，弱化的是它给人的那句话：工具该报**观测**，并让读的人看得出这次命中
#    是不是我们自己的。
a_ps=$(/usr/bin/grep -acE "$ADDR_RE" "$SAMPLES")
a_ps_detail=""
if [ "$a_ps" -gt 0 ]; then
  a_ps_detail=$(/usr/bin/grep -aoE ".{0,40}$ADDR_RE.{0,40}" "$SAMPLES" | sort -u | head -3 | tr '\n' '|')
fi
ck "$([ "$a_ps" -eq 0 ] && echo 1 || echo 0)" ADDR-PS \
   "no account address on any sampled process command line" \
   "sightings=$a_ps ; matched: ${a_ps_detail:-none} ; NOTE: this sampler reads ps -eo args for the WHOLE system. If the matched text does not belong to a process THIS run started, it is a bystander hit on a shared host, not a leak from this repository -- check the pid before treating it as one."

a_jq=$(/usr/bin/grep -acE "$ADDR_RE" "$JQARGV")
ck "$([ "$a_jq" -eq 0 ] && echo 1 || echo 0)" ADDR-JQ \
   "no account address on any jq command line (exhaustive: every jq call was recorded)" \
   "sightings=$a_jq"

# 🔴 这一格必须在 ADDR-JQ 之后跑，且必须是**同一个日志、同一个模式**：它证明那个 0
#    不是因为 shim 没挂上、日志没写、或模式匹配不到。没有它，「0 命中」与「压根没记」
#    输出一模一样 —— 本文件开头那三格讲的就是这件事。
# 🔴 Runs AFTER ADDR-JQ and against the SAME log with the SAME pattern: it proves the zero
#    above is not "the shim never attached", "nothing was written", or "the pattern cannot
#    match". Without it, "0 hits" and "we never recorded" produce identical output -- which
#    is the point the three controls at the top of this file are making.
jq_before=$(wc -c < "$JQARGV")
PATH="$SHIM:$PATH" jq -n --arg x "canary@example.invalid" '$x' >/dev/null 2>&1
jq_canary=$(/usr/bin/grep -acE "$ADDR_RE" "$JQARGV")
ck "$([ "$jq_canary" -gt 0 ] && echo 1 || echo 0)" ADDR-JQ-SENS \
   "a deliberate address on a jq command line IS recorded by the same channel" \
   "canary sightings=$jq_canary (log grew from $jq_before bytes), expected >0 -- a 0 voids ADDR-JQ"

echo "----"; echo "credential-argv-control: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
