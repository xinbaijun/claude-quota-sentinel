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

: > "$SAMPLES"; sampler_start
PATH="$SHIM:$PATH" QUOTA_STATE="$QS_STATE_DIR/quota-state.json" \
  QUOTA_SWITCH_LEDGER="$QS_STATE_DIR/switches.jsonl" QUOTA_SWITCH_MODE=on \
  QUOTA_ACCOUNT_SWITCH_BIN="$SHIM/switch-wrapper" \
  QUOTA_LOG_FILE="$QS_STATE_DIR/quota.log" \
  bash -c "cd '$REPO'
    source lib/config.sh && source lib/reading.sh && source lib/monitor.sh \
      && source lib/detect.sh && source lib/state.sh && source lib/switch.sh
    quota_decide_once \$(date +%s)" > "$BOX/run.out" 2> "$BOX/run.err"
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

# 🔴 The measurement is reported, NOT asserted, and the difference is deliberate.
#
#    Account addresses DO still reach argv, from `jq --arg <address>` call sites spread
#    across the reading and state layers (~17 of them). Those run on every poll, not
#    only during a switch, so the exposure is continuous and long-standing -- it is not
#    something this milestone introduced or can honestly claim to have removed.
#    ⭐ Writing this as a pass/fail check would ship a check that cannot pass, and a
#    check that is always red teaches people to click past red. So it is printed as a
#    number with its cause named, and whoever decides to take it on gets a real starting
#    point instead of a permanently failing assertion.
#
# 🔴 这一格是**报数**不是**判据**,区别是有意的。
#    账号地址确实仍会进 argv,来源是散布在读数层与状态层的 `jq --arg <地址>`(约 17 处)。
#    它们**每一拍轮询都在跑**,不只在切号期间 ⇒ 这是一条长期、持续的暴露面,
#    不是本里程碑引入的,本里程碑也没有诚实地把它消掉。
#    ⭐ 把它写成 pass/fail 就是发布一条**永远不可能通过**的判据,而恒红的检查训练出
#    「看到红也照过」。所以印成一个带成因的数字,让接手的人拿到真起点而不是一条恒红断言。
a_ps=$(/usr/bin/grep -acE "$ADDR_RE" "$SAMPLES")
printf 'NOTE  %-8s account addresses seen on command lines during the run: %s\n' "ADDR-PS" "$a_ps"
printf '          cause: jq --arg <address> call sites in the reading/state layers, which\n'
printf '          run every poll. Not switch-specific, not fixed here. See the report.\n'

echo "----"; echo "credential-argv-control: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
