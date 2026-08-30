# shellcheck shell=bash
# lib/reading.sh — quota reading layer / 额度读数层
#
# Provenance: `sentinel-quota` @ e2f32279, section "一、额度读数层" (lines 329–1358).
# Every function here was copied; only the marked lines were changed (state root,
# temp-file fallback, log wording). Per-function baseline line ranges are in
# docs/PROVENANCE.md.
# 抽取来源：基线 e2f32279 的 `sentinel-quota`「一、额度读数层」（329–1358 行）。
# 本文件所有函数都是复制来的，只改了标注过的那几行；逐函数行号见 docs/PROVENANCE.md。
#
# ════════════════════════════════════════════════════════════════════════
# Quota reading layer (single source of truth: the `cachedUsageUtilization`
# that Claude Code itself writes)
# 一、额度读数层（唯一真相源：cc 自己写的 cachedUsageUtilization）
# ════════════════════════════════════════════════════════════════════════

# 读快照并做新鲜度校验。返回 JSON；不可用时返回非零。
# ⚠️ 陈旧的快照比没有快照更危险——会拿半小时前的额度当现在的，切过去立刻撞墙。
#    所以这里宁可判定「没有」，也不把过期数据交出去。
quota_snapshot_read() {
  local now="$1" gen age
  [[ -s "$QUOTA_SNAPSHOT_FILE" ]] || return 1
  gen=$(jq -r '.generated_at // empty' "$QUOTA_SNAPSHOT_FILE" 2>/dev/null)
  [[ "$gen" =~ ^[0-9]+$ ]] || return 1
  age=$(( now - gen ))
  (( age < 0 || age > QUOTA_SNAPSHOT_MAX_AGE )) && return 1
  cat "$QUOTA_SNAPSHOT_FILE"
}

# ── 台账写入统一入口：多上游共写，按观测时刻新旧定胜负 ────────────────────
#
# 2026-08-21 起台账有两个上游：/usage 面板与 OAuth 接口（将来还有对话横幅）。
# 「谁当主」的问题被架构消掉了 —— **谁的观测更新，就用谁的**。依据是实测：
#
#   面板逼近阈值时会收紧到 60s 一次，而**问得越勤越容易被服务端限流**。翻 10 天日志：
#   面板因限流失明 27 次，其中 22 次（81%）发生在 five>=85% 的危险区，失明中位
#   6.4 分钟、最长 54 分钟；最要命一次（08-17 18:28）从 91% 一路瞎到 100%，
#   整个危险区间一眼没看见。OAuth 固定 180s、不随水位收紧，反而不踩这个坑。
#   ⇒ 两个上游的失败时机不重合，并联比串联强。面板瞎那 6 分钟里 OAuth 还在写。
#
# ⚠️ 不按来源定优先级，只按观测时刻。已实测两边无系统性偏差（65 对配对，有向均值
#    +0.2 点，残差只随采样间隔增长）—— 既然一样准，就没理由让谁压谁。
quota_reading_apply() {
  local source="$1" observed="$2" email="$3" five="$4" week="$5"
  local five_reset="${6:-}" week_reset="${7:-}"
  [[ -n "$source" && -n "$email" ]] || return 1
  [[ "$observed" =~ ^[0-9]+$ ]] || return 1
  [[ "$five" =~ ^[0-9]+$ && "$week" =~ ^[0-9]+$ ]] || return 1

  # 已存的观测不比这次旧就不写。两个上游各按自己节拍跑，迟到的包一定会出现；
  # 不挡住的话台账会在新旧值之间来回跳，切号判据跟着抖。
  # ⚠️ 这里**不能**用 `quota_state_get ".accounts[\"$email\"]…"`：那是把地址插进 jq 的
  #    **程序文本**，于是它照样上了 jq 的命令行。⭐ 这一处是穷举通道抓出来的，静态那条
  #    只认 `--arg` 的判据对它结构上是瞎的——「遍历到没到」与「模式集全不全」是两问。
  # ⚠️ NOT `quota_state_get ".accounts[\"$email\"]…"`: that interpolates the address into
  #    the jq PROGRAM TEXT, so it reaches the jq command line all the same. ⭐ This site was
  #    found by the exhaustive channel; the static check that only knows `--arg` was
  #    structurally blind to it. "Did the sweep reach it" and "is the pattern set complete"
  #    are two different questions.
  local stored
  stored=$(quota_state_read 2>/dev/null \
           | QS_JQ_E="$email" jq -r '.accounts[$ENV.QS_JQ_E].checked_ts // empty' 2>/dev/null)
  if [[ "$stored" =~ ^[0-9]+$ ]] && (( observed <= stored )); then
    return 2   # 2 = 有更新的数据在，本次不写（不是错误）
  fi

  local cur; cur=$(quota_state_get '.account' "")
  local fr='null' wr='null'
  [[ "$five_reset" =~ ^[0-9]+$ ]] && fr="$five_reset"
  [[ "$week_reset" =~ ^[0-9]+$ ]] && wr="$week_reset"

  # 只有当前账号才动顶层决策字段。顶层 .five_hour 的语义是「**当前**账号还剩多少」，
  # 把别人的数写进去会直接按错误水位切号。
  local expr='.accounts[$ENV.QS_JQ_E] = ((.accounts[$ENV.QS_JQ_E] // {}) + {five:$f, week:$w, checked_ts:$o, source:$s})
              | .accounts[$ENV.QS_JQ_E].five_reset = (if $fr == null then .accounts[$ENV.QS_JQ_E].five_reset else $fr end)
              | .accounts[$ENV.QS_JQ_E].week_reset = (if $wr == null then .accounts[$ENV.QS_JQ_E].week_reset else $wr end)'
  if [[ -n "$cur" && "$cur" == "$email" ]]; then
    local top_ts; top_ts=$(quota_state_get '.fetched_ts' "")
    if [[ ! "$top_ts" =~ ^[0-9]+$ ]] || (( observed > top_ts )); then
      expr="$expr | .five_hour = \$f | .seven_day = \$w | .fetched_ts = \$o
                  | .reading_source = \$s | .reading_source_ts = \$o"
    fi
  fi
  QS_JQ_E="$email" quota_state_merge "$expr" --argjson f "$five" --argjson w "$week" \
    --argjson o "$observed" --arg s "$source" --argjson fr "$fr" --argjson wr "$wr" || return 1
  return 0
}

quota_oauth_fallback_apply() {
  local now="$1" expect="$2" raw em five week fts obs age
  [[ "$QUOTA_OAUTH_FALLBACK" == "1" ]] || return 1
  [[ -s "$QUOTA_SHADOW_OAUTH_STATE" ]] || return 1
  raw=$(jq -r '
      .last_attempt // empty
      | select(.outcome == "ok")
      | [ (.account.email // ""), (.observed_at // 0),
          (.windows.five_hour.used_percentage // -1),
          (.windows.seven_day.used_percentage // -1) ] | @tsv' \
      "$QUOTA_SHADOW_OAUTH_STATE" 2>/dev/null) || return 1
  [[ -n "$raw" ]] || return 1
  IFS=$'\t' read -r em obs five week <<< "$raw"
  # ① 身份
  [[ -n "$expect" && "$em" == "$expect" ]] || {
    quota_log "⚠️ OAuth fallback unusable: sampled account [$em] != current [$expect] -> will not stand in"
    return 1
  }
  # ② 新鲜度
  [[ "$obs" =~ ^[0-9]+$ ]] || return 1
  age=$(( now - obs ))
  (( age < 0 || age > QUOTA_OAUTH_FALLBACK_MAX_AGE )) && {
    quota_log "⚠️ OAuth fallback unusable: last sample is ${age}s old (limit ${QUOTA_OAUTH_FALLBACK_MAX_AGE}s) -> will not pass a stale reading off as current"
    return 1
  }
  [[ "$five" =~ ^[0-9]+$ && "$week" =~ ^[0-9]+$ ]] || return 1
  # ③ 落盘并标明来源
  QS_JQ_E="$em" quota_state_merge '
      .five_hour = $f | .seven_day = $w | .fetched_ts = $o
      | .accounts[$ENV.QS_JQ_E].five = $f | .accounts[$ENV.QS_JQ_E].week = $w
      | .accounts[$ENV.QS_JQ_E].checked_ts = $o
      | .reading_source = "oauth_fallback" | .reading_source_ts = $n' \
    --argjson f "$five" --argjson w "$week" --argjson o "$obs" --argjson n "$now" \
    || { quota_log "❌ OAuth fallback reading could not be persisted -> this round still counts as no reading"; return 1; }
  quota_log "🛟 panel unreadable -> using OAuth reading $em five=${five}% week=${week}% (sampled $(quota_fmt_ts "$obs"), ${age}s ago)"
  return 0
}

# quota_reset_watch_pending — 有没有账号「刚过回血时刻但手上的数还是旧的」
#
# 判据是**结构性**的，不猜阈值：
#     快照拍摄时刻 < 该账号回血时刻 <= 现在
# 读作「这份快照是在它回血之前拍的，而现在已经过了那一刻」⇒ 手上这份必然是旧的。
# 一旦重查成功，新快照的拍摄时刻就晚于回血时刻，条件自动不成立，**轮询自己停**。
# 不用「额度掉到多少以下」当判据：那要挑一个阈值，而账号回血后可能立刻被别人用掉一截，
# 阈值判据会误判成「还没回血」然后一直查下去。
#
# 只看非当前账号：当前账号由 /usage 面板和 180s 影子采样各自覆盖，不需要这条。
quota_reset_watch_pending() {
  local now="$1"
  [[ -s "$QUOTA_SNAPSHOT_FILE" ]] || return 1
  jq -e --argjson n "$now" '
      .generated_at as $g
      | [ .accounts[]
          | select(.status == "active")
          | select(.is_current | not)
          | select((.five_reset  != null and .five_reset  <= $n and $g < .five_reset)
                or (.week_reset  != null and .week_reset  <= $n and $g < .week_reset))
        ] | length > 0' "$QUOTA_SNAPSHOT_FILE" >/dev/null 2>&1
}

# 供日志用：把在等的账号名列出来
quota_reset_watch_list() {
  local now="$1"
  [[ -s "$QUOTA_SNAPSHOT_FILE" ]] || return 1
  jq -r --argjson n "$now" '
      .generated_at as $g
      | [ .accounts[]
          | select(.status == "active") | select(.is_current | not)
          | select((.five_reset != null and .five_reset <= $n and $g < .five_reset)
                or (.week_reset != null and .week_reset <= $n and $g < .week_reset))
          | (.email | split("@")[0]) ] | join(" ")' "$QUOTA_SNAPSHOT_FILE" 2>/dev/null
}

# 到点就在**后台**生成一次快照。
# ⚠️ 必须后台跑：probe 每个账号约 2 秒、三个账号 6 秒起，同步调用会把轮询节拍拖垮，
#    而轮询在近阈值时收紧到 60s —— 拖 6 秒就是十分之一个周期。
# ⚠️ 用锁防堆积：上一次还没跑完就不再起新的。网络慢的时候不加锁会越堆越多。
quota_snapshot_refresh_due() {
  local now="$1" last interval watching=""
  [[ -x "$QUOTA_SNAPSHOT_TOOL" ]] || return 1
  last=$(quota_state_get '.snapshot_refresh_ts' 0)
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  if [[ -n "$QUOTA_SNAPSHOT_REFRESH_INTERVAL" ]]; then
    interval="$QUOTA_SNAPSHOT_REFRESH_INTERVAL"
  elif quota_reset_watch_pending "$now"; then
    interval="$QUOTA_SNAPSHOT_WATCH_INTERVAL"
    watching=$(quota_reset_watch_list "$now")
  else
    interval="$QUOTA_SNAPSHOT_IDLE_INTERVAL"
  fi
  (( now - last < interval )) && return 1
  quota_state_merge '.snapshot_refresh_ts = $t' --argjson t "$now" || return 1
  [[ -n "$watching" ]] && quota_log "⏱ waiting for ${watching} to reset -> snapshot tightened to ${interval}s (stops by itself once a post-reset reading arrives)"
  local lock="$QUOTA_LOCK_DIR/account-snapshot.lock"
  mkdir -p "$(dirname "$lock")" 2>/dev/null
  (
    flock -n 9 || exit 0
    QUOTA_SNAPSHOT_FILE="$QUOTA_SNAPSHOT_FILE" \
    PROBE_SNAPSHOT="$QUOTA_SNAPSHOT_FILE" \
      "$QUOTA_SNAPSHOT_TOOL" --snapshot >/dev/null 2>&1
  ) 9>"$lock" &
  return 0
}

# 影子对账：把快照说的和台账现有的并排记一笔，供事后判断能不能放行。
# 只写日志，不改任何状态。
quota_snapshot_shadow_compare() {
  local now="$1" snap
  snap=$(quota_snapshot_read "$now") || return 0
  local line
  line=$(printf '%s' "$snap" | jq -r --argjson n "$now" '
      .generated_at as $g
      | [ .accounts[]
          | select(.status == "active")
          | select(.five_hour != null)
          | "\(.email|split("@")[0])=\(.five_hour)/\(.seven_day)%" ]
        | join(" ")
      | "snapshot(\($n - $g)s ago) " + .' 2>/dev/null) || return 0
  [[ -n "$line" ]] || return 0
  # 台账侧同样只取在役账号，便于逐个对照
  local ledger
  ledger=$(quota_state_read 2>/dev/null | jq -r --argjson oos "$(quota_out_of_service_json)" '
      [ (.accounts // {}) | to_entries[]
        | select(.key as $k | ($oos | index($k)) == null)
        | "\(.key|split("@")[0])=\(.value.five // "?")/\(.value.week // "?")%" ] | join(" ")' 2>/dev/null)
  # ⚠️ 对账日志只在**内容变化**时打。拆成每拍决策之后，这行从每分钟一条变成每 10s 一条，
  #    08-22 起每天 2183 行 —— 一份逐行心跳会把真正的变化埋掉，而对账要看的恰恰是变化。
  #    「还活着」由快照文件自己的 generated_at 提供，不需要日志逐行复述。
  # ⚠️ 去重签名写**旁路文件**，不写台账。「影子对账一个字节都不碰台账」是「影子」这个词
  #    的定义，也是回归里守着的强不变量 —— 为了省几行日志去弱化它不划算。
  #    （台账里已有 scan_menus_ts 之类的记账字段，但那些是**运维动作**的痕迹；
  #      影子路径不同，它的全部承诺就是「只看不碰」。）
  local _cmp_sig _cmp_prev _cmp_f="${QUOTA_SNAPSHOT_FILE}.compare-sig"
  _cmp_sig=$(printf '%s|%s' "${line#*) }" "${ledger:-none}" | sha256sum | cut -c1-16)
  _cmp_prev=$(cat "$_cmp_f" 2>/dev/null || true)
  [[ "$_cmp_sig" == "$_cmp_prev" ]] && return 0
  printf '%s\n' "$_cmp_sig" > "$_cmp_f" 2>/dev/null || true
  quota_log "🔎 ${line} | ledger ${ledger:-none} (shadow: reconciliation only, never decides)"
  return 0
}

quota_account_retired() { [[ " $QUOTA_RETIRED_ACCOUNTS " == *" $1 "* ]]; }

quota_account_paused()  { [[ " $QUOTA_DISABLED_ACCOUNTS " == *" $1 "* ]]; }

# 在役 = 既没退役也没暂停。凡是「能不能切过去」「算不算进分母」都用这个判据。
quota_account_out_of_service() { quota_account_retired "$1" || quota_account_paused "$1"; }

# quota_out_of_service_json — the roster as ONE JSON array, for `jq --argjson`.
#
# 🔴 The obvious implementation of this is wrong in a way that passes the obvious check.
#    It used to be a pipeline ending in `... | grep -v '^$' | jq -R . | jq -sc . || printf '[]'`.
#    With BOTH rosters empty, `grep -v` filters every line away and exits 1; `pipefail`
#    (see quota-sentinel) makes the whole pipeline non-zero, so `jq -sc .` has ALREADY
#    printed `[]` and the `||` fallback prints a second one. The result is `[]\n[]` —
#    two JSON documents, not one array.
#    ⭐ And `jq -e .` returns 0 on it. The handiest validity check you would reach for
#    passes, which is exactly why it survived; `--argjson` is what actually rejects it,
#    and the caller had that stderr going to /dev/null.
#    Consequence when it bit: every candidate was filtered out, so the switcher could
#    never switch, and the ledger recorded "no in-service account below both lines"
#    while two accounts in the very same data sat far below both lines. A ledger that
#    states a false reason is worse than one that says nothing.
#    ⚠️ Same family as the SIGPIPE/pipefail defect fixed in tools/dod4-scan.posctrl.sh:
#    a pipeline's exit status describing something other than what the pipeline produced.
#
# 🔴 这个函数的「显然写法」是错的,而且错得能通过那个「显然的检查」。
#    旧写法在两张名册都为空时:`grep -v` 把所有行滤掉后退出 1,`pipefail` 令整条管道非零,
#    于是 `jq -sc .` **已经打印过一个 `[]`**、`||` 兜底又打印一个 ⇒ 得到 `[]\n[]`,
#    是**两个 JSON 文档**而不是一个数组。⭐ 而 `jq -e .` 对它返回 0——最顺手的那个
#    有效性检查是通过的,这正是它藏住的原因;真正会拒绝它的是 `--argjson`,
#    而调用方把那条 stderr 丢进了 /dev/null。
#    后果:候选被全部滤掉 ⇒ 永不切号,而账本写下「没有任何在役账号低于两条线」,
#    同一份数据里其实有两个远低于两条线。**说假理由的流水账比不说话更糟。**
#
# The rewrite has no filtering pipeline at all: jq does the splitting, so there is no
# grep exit status for pipefail to pick up.
# 重写后整条链里没有过滤环节:拆分交给 jq,于是不存在能被 pipefail 捡起来的 grep 退出码。
quota_out_of_service_json() {
  printf '%s %s' "$QUOTA_RETIRED_ACCOUNTS" "$QUOTA_DISABLED_ACCOUNTS" \
    | jq -Rc 'split(" ") | map(select(length > 0))' 2>/dev/null || printf '[]'
}

quota_claude_json() { printf '%s' "${QUOTA_CLAUDE_JSON:-$HOME/.claude.json}"; }

# quota_identity_read — 对同一个 inode 做一次 jq，避免 email / UUID 分三次读取时刚好跨过
# 另一个进程的原子 replace。输出用非空白分隔符，保留空字段供守卫 fail closed：
#   email<US>oauthAccount.accountUuid<US>cachedUsageUtilization.accountUuid
quota_identity_read() {
  local f; f=$(quota_claude_json)
  [[ -r "$f" ]] || return 1
  jq -er '[.oauthAccount.emailAddress // "",
           .oauthAccount.accountUuid // "",
           .cachedUsageUtilization.accountUuid // ""]
          | join("\u001f")' "$f" 2>/dev/null
}

# quota_iso_epoch — 带偏移的 ISO8601 → epoch。
# cc 写的是 "2026-08-11T08:10:00.492913+00:00"，偏移显式携带 → GNU date 直接吃，
# 不经过任何本地时区推断，因此**不存在**旧实现那个 8 小时 bug
# （旧实现兜底用 `tz=$(date +%Z)`，本机返回裸 `CST`，glibc 把它当 UTC+0 → 整体偏 8 小时；
#  实测：同一句 "resets 3:10pm" 一次解析成 15:10 一次解析成 23:10）。
quota_iso_epoch() {
  local iso="$1"
  [[ -z "$iso" || "$iso" == "null" ]] && return 1
  date -d "$iso" +%s 2>/dev/null
}

# ── 影子采样公共落盘 ────────────────────────────────────────────────────
# 这些文件只供后续对比研究，不能复用 quota_state_merge；物理隔离可防止异步 OAuth
# writer 与 10 秒主 poller 竞争同一个 atomic rename，也让“绝不参与决策”可机械审计。
quota_shadow_json_read() {
  local file="$1"
  [[ -s "$file" ]] && jq -e . "$file" >/dev/null 2>&1 && cat "$file"
}

quota_shadow_atomic_write() {
  local file="$1" json="$2" tmp
  mkdir -p "$(dirname "$file")" 2>/dev/null || return 1
  tmp=$(mktemp "${file}.XXXXXX") || return 1
  chmod 600 "$tmp" 2>/dev/null || true
  if printf '%s' "$json" | jq -ce . > "$tmp" 2>/dev/null && mv -f "$tmp" "$file"; then
    chmod 600 "$file" 2>/dev/null || true
    return 0
  fi
  rm -f "$tmp"
  return 1
}

quota_shadow_append_event() {
  local file="$1" json="$2"
  mkdir -p "$(dirname "$file")" 2>/dev/null || return 1
  touch "$file" 2>/dev/null || return 1
  chmod 600 "$file" 2>/dev/null || true
  printf '%s' "$json" | jq -ce . >> "$file" 2>/dev/null
}

quota_shadow_credential_marker() {
  [[ -r "$QUOTA_CREDENTIALS_FILE" ]] || return 1
  # 只存 inode/大小/纳秒 mtime，不复制 token，也不留下 token hash。
  stat -Lc '%d:%i:%s:%y' "$QUOTA_CREDENTIALS_FILE" 2>/dev/null
}

quota_shadow_now() { date +%s; }

# 输出当前实验档位 JSON。首次调用原子钉住 started_at，两个影子来源因此共用同一时钟。
# 20/40/60/120 秒每档 10 分钟；第四档结束后不循环，继续保持 120 秒。
quota_shadow_schedule() (
  local now="${1:-$(quota_shadow_now)}" lock_fd state started stage_seconds elapsed stage planned
  local stage_start stage_end penalty_interval penalty_until effective next_state
  [[ "$now" =~ ^[0-9]+$ ]] || return 1
  stage_seconds="$QUOTA_SHADOW_STAGE_SECONDS"
  [[ "$stage_seconds" =~ ^[0-9]+$ ]] && (( stage_seconds >= 60 )) || stage_seconds=600
  mkdir -p "$(dirname "$QUOTA_SHADOW_SCHEDULE_LOCK")" 2>/dev/null || return 1
  exec {lock_fd}> "$QUOTA_SHADOW_SCHEDULE_LOCK" || return 1
  chmod 600 "$QUOTA_SHADOW_SCHEDULE_LOCK" 2>/dev/null || true
  flock "$lock_fd" || return 1
  state=$(quota_shadow_json_read "$QUOTA_SHADOW_SCHEDULE_STATE" 2>/dev/null || echo '{}')
  started=$(printf '%s' "$state" | jq -r '.started_at // 0' 2>/dev/null || echo 0)
  if [[ ! "$started" =~ ^[0-9]+$ ]] || (( started <= 0 )); then
    started=$now
    next_state=$(jq -cn --argjson started "$started" --argjson seconds "$stage_seconds" '
      {schema:1, started_at:$started, stage_seconds:$seconds,
       plan:[{stage:1,interval_seconds:20}, {stage:2,interval_seconds:40},
             {stage:3,interval_seconds:60}, {stage:4,interval_seconds:120}],
       penalty_interval:null, penalty_until:null, last_rate_limited_at:null}') || return 1
    quota_shadow_atomic_write "$QUOTA_SHADOW_SCHEDULE_STATE" "$next_state" || return 1
    state="$next_state"
  fi
  elapsed=$(( now - started )); (( elapsed < 0 )) && elapsed=0
  if (( elapsed < stage_seconds )); then
    stage=1; planned=20
  elif (( elapsed < stage_seconds * 2 )); then
    stage=2; planned=40
  elif (( elapsed < stage_seconds * 3 )); then
    stage=3; planned=60
  else
    stage=4; planned=120
  fi
  stage_start=$(( started + (stage - 1) * stage_seconds ))
  if (( stage < 4 )); then stage_end=$(( stage_start + stage_seconds )); else stage_end=null; fi
  penalty_interval=$(printf '%s' "$state" | jq -r '.penalty_interval // 0' 2>/dev/null || echo 0)
  penalty_until=$(printf '%s' "$state" | jq -r '.penalty_until // 0' 2>/dev/null || echo 0)
  [[ "$penalty_interval" =~ ^[0-9]+$ ]] || penalty_interval=0
  [[ "$penalty_until" =~ ^[0-9]+$ ]] || penalty_until=0
  effective=$planned
  if (( now < penalty_until && penalty_interval > effective )); then effective=$penalty_interval; fi
  jq -cn --argjson started "$started" --argjson stage "$stage" \
    --argjson planned "$planned" --argjson effective "$effective" \
    --argjson stage_start "$stage_start" --argjson stage_end "$stage_end" \
    --argjson experiment_end "$(( started + stage_seconds * 4 ))" \
    --argjson penalty_interval "$penalty_interval" --argjson penalty_until "$penalty_until" '
      {started_at:$started, stage:$stage, planned_interval_seconds:$planned,
       interval_seconds:$effective, stage_started_at:$stage_start,
       stage_ends_at:$stage_end, experiment_ends_at:$experiment_end,
       penalty_interval:(if $penalty_interval > 0 then $penalty_interval else null end),
       penalty_until:(if $penalty_until > 0 then $penalty_until else null end)}'
)

# 429 时把有效间隔至少升一档并保持一个阶段；重复 429 会继续 40→60→120→240→480→600。
quota_shadow_schedule_penalize() (
  local now="$1" current="$2" lock_fd state bumped existing until next_state
  [[ "$now" =~ ^[0-9]+$ && "$current" =~ ^[0-9]+$ ]] || return 1
  if (( current < 40 )); then bumped=40
  elif (( current < 60 )); then bumped=60
  elif (( current < 120 )); then bumped=120
  elif (( current < 600 )); then bumped=$(( current * 2 )); (( bumped > 600 )) && bumped=600
  else bumped=600
  fi
  mkdir -p "$(dirname "$QUOTA_SHADOW_SCHEDULE_LOCK")" 2>/dev/null || return 1
  exec {lock_fd}> "$QUOTA_SHADOW_SCHEDULE_LOCK" || return 1
  chmod 600 "$QUOTA_SHADOW_SCHEDULE_LOCK" 2>/dev/null || true
  flock "$lock_fd" || return 1
  state=$(quota_shadow_json_read "$QUOTA_SHADOW_SCHEDULE_STATE" 2>/dev/null || echo '{}')
  existing=$(printf '%s' "$state" | jq -r '.penalty_interval // 0' 2>/dev/null || echo 0)
  [[ "$existing" =~ ^[0-9]+$ ]] || existing=0
  (( existing > bumped )) && bumped=$existing
  until=$(( now + QUOTA_SHADOW_STAGE_SECONDS ))
  next_state=$(printf '%s' "$state" | jq -c --argjson interval "$bumped" \
    --argjson until "$until" --argjson now "$now" '
      .penalty_interval=$interval | .penalty_until=$until | .last_rate_limited_at=$now') || return 1
  quota_shadow_atomic_write "$QUOTA_SHADOW_SCHEDULE_STATE" "$next_state" || return 1
  printf '%s' "$bumped"
)

quota_shadow_source_interval() {
  local source="$1" cadence="$2" interval
  case "$source" in
    statusline) interval=$(printf '%s' "$cadence" | jq -r '.planned_interval_seconds // 120' 2>/dev/null) ;;
    # ⚠️ 兜底值必须与 QUOTA_SHADOW_OAUTH_INTERVAL 一致：cadence 缺字段时若掉回 120，
    #    就绕过了「180 秒才安全」这个实测结论，而且不会有任何报错。
    oauth_api)  interval=$(printf '%s' "$cadence" | jq -r --argjson d "$QUOTA_SHADOW_OAUTH_INTERVAL" '.interval_seconds // $d' 2>/dev/null) ;;
    *) return 1 ;;
  esac
  [[ "$interval" =~ ^[0-9]+$ ]] || interval=120
  # oauth 这条不许低于实测安全下限
  [[ "$source" == "oauth_api" ]] && (( interval < QUOTA_SHADOW_OAUTH_INTERVAL )) \
    && interval=$QUOTA_SHADOW_OAUTH_INTERVAL
  printf '%s' "$interval"
}

quota_source_append() (
  local event="$1" lock_fd
  mkdir -p "$(dirname "$QUOTA_SOURCE_EVENTS_LOCK")" 2>/dev/null || return 1
  exec {lock_fd}> "$QUOTA_SOURCE_EVENTS_LOCK" || return 1
  chmod 600 "$QUOTA_SOURCE_EVENTS_LOCK" 2>/dev/null || true
  flock "$lock_fd" || return 1
  quota_shadow_append_event "$QUOTA_SOURCE_EVENTS" "$event"
)

# /usage 是当前唯一决策来源；成功解析的每一帧同时镜像到统一逐次日志，供三方按时间对齐。
quota_source_log_usage() {
  local observed="$1" email="$2" uuid="$3" five="$4" five_reset="$5" week="$6" week_reset="$7"
  local cadence event source_interval
  cadence=$(quota_shadow_schedule "$observed" 2>/dev/null || echo '{}')
  source_interval=$(quota_state_get '.usage_refresh.interval_seconds' "$QUOTA_USAGE_INTERVAL_NEAR")
  [[ "$source_interval" =~ ^[0-9]+$ ]] || source_interval=$QUOTA_USAGE_INTERVAL_NEAR
  event=$(QS_JQ_EMAIL="$email" jq -cn --arg uuid "$uuid" \
    --argjson observed "$observed" --argjson five "$five" \
    --argjson five_reset "${five_reset:-null}" --argjson week "$week" \
    --argjson week_reset "${week_reset:-null}" --argjson cadence "$cadence" \
    --argjson source_interval "$source_interval" '
      {schema:1,source:"usage_panel",mode:"primary",decision_eligible:true,outcome:"ok",
       observed_at:$observed,account:{email:$ENV.QS_JQ_EMAIL,uuid:$uuid},
       windows:{five_hour:{period_seconds:18000,used_percentage:$five,resets_at:$five_reset},
                seven_day:{period_seconds:604800,used_percentage:$week,resets_at:$week_reset}},
       cadence:($cadence + {source_interval_seconds:$source_interval})}') || return 0
  quota_source_append "$event" || true
}

quota_source_log_usage_failure() {
  local observed="$1" email="${2:-}" uuid="${3:-}" outcome="${4:-unknown_error}"
  local cadence event source_interval
  cadence=$(quota_shadow_schedule "$observed" 2>/dev/null || echo '{}')
  source_interval=$(quota_state_get '.usage_refresh.interval_seconds' "$QUOTA_USAGE_INTERVAL_NEAR")
  [[ "$source_interval" =~ ^[0-9]+$ ]] || source_interval=$QUOTA_USAGE_INTERVAL_NEAR
  event=$(QS_JQ_EMAIL="$email" jq -cn --arg uuid "$uuid" --arg outcome "$outcome" \
    --argjson observed "$observed" --argjson cadence "$cadence" \
    --argjson source_interval "$source_interval" '
      {schema:1,source:"usage_panel",mode:"primary",decision_eligible:false,
       outcome:$outcome,observed_at:$observed,account:{email:$ENV.QS_JQ_EMAIL,uuid:$uuid},
       windows:null,cadence:($cadence + {source_interval_seconds:$source_interval})}') || return 0
  quota_source_append "$event" || true
}

# statusLine command 的 stdin 是 Claude Code 官方提供的会话 JSON。这个入口只接受
# monitor 启动时固化的账号/UUID/代际，并再次核验主状态、活 tmux 与当前凭据；任一项
# 不同都静默丢帧，挡住切号中途的旧 monitor 和“同名会话重建”ABA。
# ⚠️ 只接受 `--owner-file <path>`，**故意不保留**「四个位置参数」那种调用方式。
#    留着它就等于留着一条把账号地址放上命令行的合法路径，而这个子命令正是被 Claude Code
#    每 20 秒调起来一次的那个 —— 留一条后门，它就会被每 20 秒走一次。
# ⚠️ Only `--owner-file <path>` is accepted; the four-positional-argument form is
#    deliberately NOT kept. Keeping it would keep a supported way to put an account
#    address on a command line -- and this subcommand is the one Claude Code invokes every
#    20 seconds, so a back door here is a back door taken every 20 seconds.
quota_shadow_statusline_ingest() (
  local owner_file="" expected_email="" expected_uuid="" expected_gen="" expected_launch=""
  while (( $# )); do
    case "$1" in
      --owner-file) owner_file="${2:-}"; shift 2 || return 0 ;;
      *) return 0 ;;
    esac
  done
  local _own
  _own=$(quota_statusline_owner_read "$owner_file" 2>/dev/null) || return 0
  IFS=$'\037' read -r expected_email expected_uuid expected_gen expected_launch <<< "$_own"
  local payload state owner owner_uuid owner_gen owner_launch live_gen live_launch
  local identity actual_email="" actual_uuid="" usage_uuid=""
  local normalized now shadow lock_fd next_due event next_state cadence interval outcome windows
  [[ "$QUOTA_SHADOW_ENABLED" == "1" ]] || return 0
  [[ -n "$expected_email" && -n "$expected_uuid" && -n "$expected_gen" \
     && -n "$expected_launch" ]] || return 0
  payload=$(cat 2>/dev/null) || return 0

  state=$(quota_shadow_json_read "$QUOTA_STATE" 2>/dev/null) || return 0
  owner=$(printf '%s' "$state" | jq -r '.monitor_account // empty' 2>/dev/null)
  owner_uuid=$(printf '%s' "$state" | jq -r '.monitor_uuid // empty' 2>/dev/null)
  owner_gen=$(printf '%s' "$state" | jq -r '.monitor_session_created // empty | tostring' 2>/dev/null)
  owner_launch=$(printf '%s' "$state" | jq -r '.monitor_launch_id // empty' 2>/dev/null)
  [[ "$owner" == "$expected_email" && "$owner_uuid" == "$expected_uuid" \
     && "$owner_gen" == "$expected_gen" && "$owner_launch" == "$expected_launch" ]] || return 0
  live_gen=$(quota_session_created "$QUOTA_MONITOR_SESSION" 2>/dev/null || true)
  [[ "$live_gen" == "$expected_gen" ]] || return 0
  live_launch=$(quota_monitor_live_launch_id 2>/dev/null || true)
  [[ "$live_launch" == "$expected_launch" ]] || return 0
  identity=$(quota_identity_read 2>/dev/null || true)
  [[ -n "$identity" ]] || return 0
  IFS=$'\037' read -r actual_email actual_uuid usage_uuid <<< "$identity"
  [[ "$actual_email" == "$expected_email" && "$actual_uuid" == "$expected_uuid" ]] || return 0
  : "${usage_uuid:-}"

  now=$(quota_shadow_now)
  cadence=$(quota_shadow_schedule "$now" 2>/dev/null || echo '{}')
  # OAuth 429 的 penalty 只约束网络直查；statusLine 是 Claude Code 的本地回调，
  # 继续按原始四阶段计划采样，才能独立评估它的刷新及时性。
  interval=$(quota_shadow_source_interval statusline "$cadence" 2>/dev/null || echo 120)
  cadence=$(printf '%s' "$cadence" | jq -c --argjson interval "$interval" \
    '. + {source_interval_seconds:$interval}' 2>/dev/null || printf '%s' "$cadence")
  mkdir -p "$(dirname "$QUOTA_SHADOW_STATUSLINE_LOCK")" 2>/dev/null || return 0
  exec {lock_fd}> "$QUOTA_SHADOW_STATUSLINE_LOCK" || return 0
  chmod 600 "$QUOTA_SHADOW_STATUSLINE_LOCK" 2>/dev/null || true
  flock -n "$lock_fd" || return 0
  shadow=$(quota_shadow_json_read "$QUOTA_SHADOW_STATUSLINE_STATE" 2>/dev/null || echo '{}')
  next_due=$(printf '%s' "$shadow" | jq -r '.next_due // 0' 2>/dev/null || echo 0)
  [[ "$next_due" =~ ^[0-9]+$ ]] || next_due=0
  (( now >= next_due )) || return 0

  normalized=$(printf '%s' "$payload" | jq -ce '
    def win($v; $seconds):
      if (($v | type) == "object")
         and (($v.used_percentage | type) == "number")
         and (($v.resets_at | type) == "number")
         and ($v.used_percentage >= 0) and ($v.resets_at > 0)
      then {period_seconds:$seconds,
            used_percentage:$v.used_percentage,
            resets_at:($v.resets_at | floor)}
      else null end;
    {session_id:(.session_id // "" | if type == "string" then . else "" end),
     version:(.version // "" | if type == "string" then . else "" end),
     windows:{five_hour:win(.rate_limits.five_hour; 18000),
              seven_day:win(.rate_limits.seven_day; 604800)}}' 2>/dev/null) || normalized=''
  if [[ -z "$normalized" ]]; then
    outcome="malformed_json"
    normalized='{"session_id":"","version":"","windows":{"five_hour":null,"seven_day":null}}'
  elif printf '%s' "$normalized" | jq -e \
      '(.windows.five_hour != null) or (.windows.seven_day != null)' >/dev/null 2>&1; then
    outcome="ok"
  else
    outcome="missing_rate_limits"
  fi
  windows=$(printf '%s' "$normalized" | jq -c '.windows' 2>/dev/null || echo null)
  event=$(printf '%s' "$normalized" | QS_JQ_EMAIL="$expected_email" jq -c \
    --arg uuid "$expected_uuid" \
    --arg monitor "$QUOTA_MONITOR_SESSION" --arg generation "$expected_gen" \
    --arg launch "$expected_launch" \
    --arg outcome "$outcome" --argjson observed "$now" --argjson next "$(( now + interval ))" \
    --argjson cadence "$cadence" '
      {schema:1, source:"statusline", mode:"shadow", decision_eligible:false,
       observed_at:$observed, outcome:$outcome, next_due:$next,
       account:{email:$ENV.QS_JQ_EMAIL, uuid:$uuid},
       monitor:{session:$monitor, generation:$generation, launch_id:$launch},
       claude:{session_id:.session_id, version:.version},
       windows:.windows,
       cadence:$cadence,
       freshness:{kind:"collector_observed", server_fetched_at:null,
                  note:"statusLine may replay its last known rate_limits"}}' 2>/dev/null) || return 0
  next_state=$(QS_JQ_EMAIL="$expected_email" jq -cn --arg uuid "$expected_uuid" \
    --arg generation "$expected_gen" --arg launch "$expected_launch" \
    --arg outcome "$outcome" --argjson now "$now" \
    --argjson next "$(( now + interval ))" --argjson cadence "$cadence" \
    --argjson windows "$windows" '
      {schema:1, mode:"shadow", decision_eligible:false, last_write:$now,
       next_due:$next, last_outcome:$outcome, last_windows:$windows,
       account:{email:$ENV.QS_JQ_EMAIL,uuid:$uuid}, monitor_generation:$generation,
       monitor_launch_id:$launch,
       cadence:$cadence}' 2>/dev/null) || return 0
  quota_shadow_append_event "$QUOTA_SHADOW_STATUSLINE_EVENTS" "$event" || true
  quota_source_append "$event" || true
  quota_shadow_atomic_write "$QUOTA_SHADOW_STATUSLINE_STATE" "$next_state" || true
  return 0
)

# 🔻 REWRITTEN DURING EXTRACTION. Baseline: `sentinel-quota:991-1011` @ e2f32279.
#    What changed: the four ownership values (account, uuid, generation, launch id) used
#    to be four positional arguments inside the `--settings` JSON. What that cost: they
#    were then part of the monitor CLI process argv, so an account address was readable
#    by any user from `/proc/<pid>/cmdline` for the whole session. They now travel in a
#    0600 file. The fence is unchanged in effect: a stale generation reads no ownership
#    and returns, exactly as it previously failed the value comparison.
# 🔻 抽取时重写。基线 `sentinel-quota:991-1011` @ e2f32279。
#    改了什么：归属四值（账号、UUID、代际、launch id）原本是 `--settings` JSON 里的四个
#    位置参数。代价是什么：它们因此成了 monitor CLI 进程 argv 的一部分，账号地址在**整个
#    会话期间**都能被任意用户从 `/proc/<pid>/cmdline` 读到。现在改走 0600 文件。
#    围栏效果不变：旧代际读不到归属就直接返回，与原来「值对不上所以自我拒绝」同果。
# 构造专用 monitor 的命令。--settings 是仅此进程的 overlay，不改用户全局 settings。
#
# 🔴 归属那四个值（账号、UUID、代际、launch id）**走文件，不走命令行**。
#    它们曾经是四个位置参数，于是躺在 `--settings` 的 JSON 里，而那串 JSON 是
#    monitor CLI 进程 argv 的一部分 ⇒ 一个账号地址在**整个会话期间**都能被任意用户
#    从 `/proc/<pid>/cmdline` 读到。⭐ 这和 `jq --arg` 那一类不是一个量级：
#    jq 调用只活几微秒，这个活到会话结束。命令行上现在只剩一个不敏感的文件路径。
# 🔴 The ownership values (account, uuid, generation, launch id) travel in a FILE, not on
#    the command line. As four positional arguments they sat inside the `--settings` JSON,
#    which is part of the monitor CLI process argv -- so an account address was readable
#    by ANY user from `/proc/<pid>/cmdline` for the WHOLE session. ⭐ Not the same order of
#    magnitude as the `jq --arg` sites: a jq call lives microseconds, this lives until the
#    session ends. Only a non-sensitive path is left on the command line.
#
# ⚠️ 写文件前先把该目录下其他 owner 文件删掉，两个理由，第二个才是要紧的：
#    ① 不留「只增不减」的凭据相关文件（本项目对这种默认值有明确立场）；
#    ② **上一代 CLI 的 owner 文件被删掉，正是我们要的**——它的采集器读不到归属就直接
#       返回，等于把旧代际挡在门外，与原来「值对不上所以自我拒绝」是同一个结果。
# ⚠️ Other owner files are removed first. Two reasons, and the second is the load-bearing
#    one: ① nothing credential-adjacent should be append-only here; ② deleting the PREVIOUS
#    generation file is exactly what we want -- its collector then reads no ownership and
#    returns, which fences out the stale generation just as the old value-mismatch did.
quota_monitor_launch_command() {
  local email="${1:-}" uuid="${2:-}" generation="${3:-}" launch_id="${4:-}"
  local self ingest settings quoted refresh owner_file
  if [[ "$QUOTA_SHADOW_ENABLED" != "1" || -z "$email" || -z "$uuid" \
     || -z "$generation" || -z "$launch_id" ]]; then
    printf '%s' "$QUOTA_MONITOR_LAUNCH"
    return 0
  fi
  refresh="$QUOTA_SHADOW_STATUSLINE_REFRESH"
  [[ "$refresh" =~ ^[0-9]+$ ]] && (( refresh >= 1 )) || refresh=20
  self=$(readlink -f "${BASH_SOURCE[0]}")
  # ⚠️ 落不下这个文件就退回「不带 statusLine 的启动命令」，与 shadow 关闭时同一条路。
  #    宁可少一个影子读数源，也不要把地址放回命令行换取它。
  # ⚠️ If the file cannot be written, fall back to the launch command WITHOUT statusLine --
  #    the same path as shadow being disabled. Better to lose a shadow reading source than
  #    to buy it back by putting the address on a command line again.
  quota_statusline_owner_write "$email" "$uuid" "$generation" "$launch_id" || {
    printf '%s' "$QUOTA_MONITOR_LAUNCH"; return 0; }
  owner_file="$QUOTA_SHADOW_STATUSLINE_OWNER_DIR/$launch_id.json"
  printf -v ingest '%q shadow-statusline-ingest --owner-file %q' "$self" "$owner_file"
  settings=$(jq -cn --arg command "$ingest" --argjson refresh "$refresh" \
    '{statusLine:{type:"command",command:$command,padding:0,refreshInterval:$refresh}}') || {
      printf '%s' "$QUOTA_MONITOR_LAUNCH"; return 0; }
  printf -v quoted '%q' "$settings"
  printf '%s --settings %s' "$QUOTA_MONITOR_LAUNCH" "$quoted"
}

# 写归属文件（0600），并清掉同目录下其余 owner 文件。返回非 0 表示没写成。
# Write the ownership file (0600) and remove every other owner file in that directory.
quota_statusline_owner_write() {
  local email="$1" uuid="$2" generation="$3" launch_id="$4" dir tmp f
  dir="$QUOTA_SHADOW_STATUSLINE_OWNER_DIR"
  mkdir -p "$dir" 2>/dev/null || return 1
  chmod 700 "$dir" 2>/dev/null || true
  for f in "$dir"/*.json; do
    [[ -e "$f" ]] || continue
    [[ "$(basename "$f")" == "$launch_id.json" ]] || rm -f "$f" 2>/dev/null
  done
  tmp=$(mktemp "$dir/.owner.XXXXXX") || return 1
  chmod 600 "$tmp" 2>/dev/null || true
  if ! QS_JQ_EMAIL="$email" QS_JQ_UUID="$uuid" jq -cn \
        --arg generation "$generation" --arg launch "$launch_id" \
        '{account:$ENV.QS_JQ_EMAIL, uuid:$ENV.QS_JQ_UUID,
          generation:$generation, launch_id:$launch}' > "$tmp" 2>/dev/null; then
    rm -f "$tmp"; return 1
  fi
  mv -f "$tmp" "$dir/$launch_id.json" || { rm -f "$tmp"; return 1; }
  return 0
}

# 读归属文件，用 \037 分隔回吐四个值。文件不存在/不完整都返回非 0。
# Read the ownership file back, emitting the four values separated by \037.
quota_statusline_owner_read() {
  local file="$1" out
  [[ -n "$file" && -s "$file" ]] || return 1
  out=$(jq -r '[.account//"", .uuid//"", .generation//"", .launch_id//""] | join("\u001f")' \
        "$file" 2>/dev/null) || return 1
  [[ -n "$out" ]] || return 1
  printf '%s' "$out"
}

# 生产实现从凭据文件取 accessToken，但 header 经匿名 pipe fd 交给 curl；token 不进入
# argv、落盘文件、日志或 JSONL。此函数单独成 seam，回归测试可完全离线打桩。
# stdout: HTTP status；return !=0: 本地凭据/网络失败。
quota_shadow_oauth_http_fetch() {
  local body_file="$1" header_file="$2" token http rc
  token=$(jq -er '.claudeAiOauth.accessToken
                  | select(type == "string" and length > 0)' \
    "$QUOTA_CREDENTIALS_FILE" 2>/dev/null) || return 90
  http=$(curl --silent --show-error --proto '=https' --retry 0 \
    --connect-timeout "$QUOTA_SHADOW_OAUTH_CONNECT_TIMEOUT" \
    --max-time "$QUOTA_SHADOW_OAUTH_MAX_TIME" \
    --output "$body_file" --dump-header "$header_file" --write-out '%{http_code}' \
    --header @<(printf 'Authorization: Bearer %s\n' "$token") \
    --header "User-Agent: ${QUOTA_SHADOW_OAUTH_UA:-claude-code/2.1.226}" \
    --header 'anthropic-beta: oauth-2025-04-20' \
    --header 'Content-Type: application/json' \
    "$QUOTA_SHADOW_OAUTH_URL" 2>/dev/null)
  rc=$?
  unset token
  (( rc == 0 )) || return "$rc"
  printf '%s' "$http"
}

quota_shadow_retry_after() {
  local header_file="$1" now="$2" raw epoch
  raw=$(awk 'BEGIN{IGNORECASE=1} /^Retry-After:[[:space:]]*/ {v=$0}
             END{sub(/^[^:]*:[[:space:]]*/,"",v); sub(/\r$/, "", v); print v}' \
    "$header_file" 2>/dev/null)
  if [[ "$raw" =~ ^[0-9]+$ ]]; then
    printf '%s' "$raw"
    return 0
  fi
  epoch=$(date -d "$raw" +%s 2>/dev/null || true)
  [[ "$epoch" =~ ^[0-9]+$ ]] && (( epoch > now )) || return 1
  printf '%s' "$(( epoch - now ))"
}

# return 0 = 到点。401 后凭据文件代次一变就提前放行，脚本本身不刷新 token。
quota_shadow_oauth_due() {
  local now="${1:-$(quota_shadow_now)}" state next outcome old_marker marker
  state=$(quota_shadow_json_read "$QUOTA_SHADOW_OAUTH_STATE" 2>/dev/null || echo '{}')
  next=$(printf '%s' "$state" | jq -r '.next_due // 0' 2>/dev/null || echo 0)
  [[ "$next" =~ ^[0-9]+$ ]] || next=0
  (( now >= next )) && return 0
  outcome=$(printf '%s' "$state" | jq -r '.last_outcome // empty' 2>/dev/null || true)
  if [[ "$outcome" == "auth_error" ]]; then
    old_marker=$(printf '%s' "$state" | jq -r '.credential_marker // empty' 2>/dev/null || true)
    marker=$(quota_shadow_credential_marker 2>/dev/null || true)
    [[ -n "$marker" && "$marker" != "$old_marker" ]] && return 0
  fi
  return 1
}

# 单次 OAuth 影子采样。无论网络、schema、身份漂移或落盘如何失败，都不把错误传播给
# poller 主循环；事件只保留 allowlist 字段，响应正文与 token 永不入日志。
quota_shadow_oauth_sample() (
  [[ "$QUOTA_SHADOW_ENABLED" == "1" ]] || return 0
  local lock_fd state now marker marker_after claim identity_before before_email="" before_uuid="" before_usage_uuid=""
  local identity_after after_email="" after_uuid="" after_usage_uuid="" body_file header_file
  local http="" fetch_rc=0 start_ms end_ms latency_ms=0 outcome="" windows='null'
  local values five five_iso five_epoch week week_iso week_epoch failures prev_fail next_due delay retry_after=0
  local event next_state http_json received cadence interval penalty_interval=0
  mkdir -p "$(dirname "$QUOTA_SHADOW_OAUTH_LOCK")" 2>/dev/null || return 0
  exec {lock_fd}> "$QUOTA_SHADOW_OAUTH_LOCK" || return 0
  chmod 600 "$QUOTA_SHADOW_OAUTH_LOCK" 2>/dev/null || true
  flock -n "$lock_fd" || return 0
  now=$(quota_shadow_now)
  quota_shadow_oauth_due "$now" || return 0
  state=$(quota_shadow_json_read "$QUOTA_SHADOW_OAUTH_STATE" 2>/dev/null || echo '{}')
  marker=$(quota_shadow_credential_marker 2>/dev/null || true)
  cadence=$(quota_shadow_schedule "$now" 2>/dev/null || echo '{}')
  interval=$(quota_shadow_source_interval oauth_api "$cadence" 2>/dev/null || echo "$QUOTA_SHADOW_OAUTH_INTERVAL")
  cadence=$(printf '%s' "$cadence" | jq -c --argjson interval "$interval" \
    '. + {source_interval_seconds:$interval}' 2>/dev/null || printf '%s' "$cadence")
  claim=$(printf '%s' "$state" | jq -c --argjson now "$now" \
    --argjson due "$(( now + interval ))" --arg marker "$marker" '
      .schema=1 | .mode="shadow" | .decision_eligible=false
      | .attempt_in_progress=$now | .next_due=$due | .credential_marker=$marker' 2>/dev/null) || return 0
  quota_shadow_atomic_write "$QUOTA_SHADOW_OAUTH_STATE" "$claim" || return 0

  identity_before=$(quota_identity_read 2>/dev/null || true)
  if [[ -n "$identity_before" ]]; then
    IFS=$'\037' read -r before_email before_uuid before_usage_uuid <<< "$identity_before"
  fi
  : "${before_usage_uuid:-}"
  if [[ -z "$before_email" || -z "$before_uuid" ]]; then
    outcome="identity_unavailable"
  else
    body_file=$(mktemp "${TMPDIR:-/tmp}/quota-sentinel-oauth-body.XXXXXX") || return 0
    header_file=$(mktemp "${TMPDIR:-/tmp}/quota-sentinel-oauth-header.XXXXXX") || {
      rm -f "$body_file"; return 0; }
    chmod 600 "$body_file" "$header_file" 2>/dev/null || true
    start_ms=$(date +%s%3N)
    http=$(quota_shadow_oauth_http_fetch "$body_file" "$header_file")
    fetch_rc=$?
    end_ms=$(date +%s%3N)
    [[ "$start_ms" =~ ^[0-9]+$ && "$end_ms" =~ ^[0-9]+$ ]] && latency_ms=$(( end_ms - start_ms ))

    identity_after=$(quota_identity_read 2>/dev/null || true)
    if [[ -n "$identity_after" ]]; then
      IFS=$'\037' read -r after_email after_uuid after_usage_uuid <<< "$identity_after"
    fi
    marker_after=$(quota_shadow_credential_marker 2>/dev/null || true)
    : "${after_usage_uuid:-}"
    if [[ "$after_email" != "$before_email" || "$after_uuid" != "$before_uuid" \
          || -z "$after_email" || -z "$after_uuid" ]]; then
      outcome="identity_changed"
    elif [[ "$marker_after" != "$marker" ]]; then
      outcome="credential_changed"
    elif (( fetch_rc != 0 )); then
      outcome="network_error"
      http=""
    elif [[ "$http" == "200" ]]; then
      # ⚠️ 空字段必须占位，不能直接 @tsv。tab 属于 IFS **空白**字符，read 会把
      #    **连续的制表符当成一个分隔符** —— 中间字段一空，后面全部错位：
      #      服务端 0 <空> 31 <ISO>  会被读成  five=0 five_iso=31 week=<ISO> week_iso=空
      #    而 resets_at 恰恰在窗口闲置时就是空的。原来那条「四个都必须是数字」的判据
      #    其实一直在**掩盖这个错位**：它把错位的结果挡在门外，于是从没表现成错误的
      #    数值，只表现为 schema_error（2026-08-22～24 三天 25 次）。
      #    ⇒ 该修的是解析不是判据。null 统一换成 "-" 占位，字段就不会塌。
      values=$(jq -er '[.five_hour.utilization, .five_hour.resets_at,
                         .seven_day.utilization, .seven_day.resets_at]
                       | map(if . == null then "-" else tostring end) | @tsv' \
        "$body_file" 2>/dev/null || true)
      if [[ -n "$values" ]]; then
        IFS=$'\t' read -r five five_iso week week_iso <<< "$values"
        [[ "$five_iso" == "-" ]] && five_iso=""
        [[ "$week_iso" == "-" ]] && week_iso=""
        [[ "$five" == "-" ]] && five=""
        [[ "$week" == "-" ]] && week=""
        five_epoch=$(quota_iso_epoch "$five_iso" 2>/dev/null || true)
        week_epoch=$(quota_iso_epoch "$week_iso" 2>/dev/null || true)
      else
        five=""; week=""; five_epoch=""; week_epoch=""
      fi
      # ⚠️ resets_at 是**可选**的：窗口闲着没用过时服务端根本不返回它。
      #    首版要求四个字段全是数字，于是每当五小时窗口空闲，整条样本被判成
      #    schema_error 整个丢掉 —— **连好好的周额度一起扔了**。2026-08-22～24
      #    三天丢了 25 条（约 5%），全部集中在当前账号的低用量时段。
      #    而且它伪装得好：outcome=schema_error 看起来像服务端返回了畸形数据，
      #    实际是我们的判据太严。
      #
      # ⚠️ 但不能一律放行 —— 那会把真正的畸形响应也当成正常。分开判：
      #    使用率为 0 且没有 resets_at  → 正常（窗口没启用，无重置可言）
      #    使用率不为 0 却没有 resets_at → 仍判 schema_error（服务端该知道何时重置）
      #    决策要用的是使用率；resets_at 只影响回血盯梢，缺了记成 null 即可。
      local _f_ok=0 _w_ok=0
      if [[ "$five" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        if [[ "$five_epoch" =~ ^[0-9]+$ ]]; then _f_ok=1
        elif awk -v v="$five" 'BEGIN{exit !(v+0==0)}'; then _f_ok=1; five_epoch=""
        fi
      fi
      if [[ "$week" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        if [[ "$week_epoch" =~ ^[0-9]+$ ]]; then _w_ok=1
        elif awk -v v="$week" 'BEGIN{exit !(v+0==0)}'; then _w_ok=1; week_epoch=""
        fi
      fi
      if (( _f_ok && _w_ok )); then
        local _fe='null' _we='null'
        [[ "$five_epoch" =~ ^[0-9]+$ ]] && _fe="$five_epoch"
        [[ "$week_epoch" =~ ^[0-9]+$ ]] && _we="$week_epoch"
        windows=$(jq -cn --argjson five "$five" --arg five_iso "$five_iso" \
          --argjson five_epoch "$_fe" --argjson week "$week" \
          --arg week_iso "$week_iso" --argjson week_epoch "$_we" '
            {five_hour:{period_seconds:18000,used_percentage:$five,
                        resets_at:$five_epoch,resets_at_iso:$five_iso},
             seven_day:{period_seconds:604800,used_percentage:$week,
                        resets_at:$week_epoch,resets_at_iso:$week_iso}}')
        outcome="ok"
      else
        outcome="schema_error"
      fi
    elif [[ "$http" == "429" ]]; then
      outcome="rate_limited"
    elif [[ "$http" == "401" ]]; then
      outcome="auth_error"
    elif [[ "$http" =~ ^5[0-9][0-9]$ ]]; then
      outcome="server_error"
    else
      outcome="client_error"
    fi
  fi

  prev_fail=$(printf '%s' "$claim" | jq -r '.consecutive_failures // 0' 2>/dev/null || echo 0)
  [[ "$prev_fail" =~ ^[0-9]+$ ]] || prev_fail=0
  if [[ "$outcome" == "ok" ]]; then
    failures=0
    delay=$interval
  elif [[ "$outcome" == "identity_changed" || "$outcome" == "credential_changed" ]]; then
    failures=$prev_fail
    delay=$interval
  else
    failures=$(( prev_fail + 1 ))
    case "$outcome" in
      rate_limited)
        penalty_interval=$(quota_shadow_schedule_penalize "$now" "$interval" 2>/dev/null || echo "$(( interval * 2 ))")
        [[ "$penalty_interval" =~ ^[0-9]+$ ]] || penalty_interval=$(( interval * 2 ))
        delay=$penalty_interval
        retry_after=$(quota_shadow_retry_after "$header_file" "$now" 2>/dev/null || echo 0)
        [[ "$retry_after" =~ ^[0-9]+$ ]] || retry_after=0
        (( retry_after > delay )) && delay=$retry_after
        quota_log "⚠️ OAuth shadow sample got HTTP 429 (experiment stage=$(printf '%s' "$cadence" | jq -r '.stage // "?"'), this interval=${interval}s) -> effective interval backed off to at least ${penalty_interval}s, next_due=$(date -d "@$(( now + delay ))" '+%H:%M:%S')"
        ;;
      auth_error|client_error) delay=86400 ;;
      schema_error)
        delay=$(( 600 * (1 << (failures > 4 ? 4 : failures - 1)) ))
        (( delay > 21600 )) && delay=21600
        ;;
      *)
        delay=$(( interval * (1 << (failures > 4 ? 4 : failures)) ))
        (( delay > 3600 )) && delay=3600
        ;;
    esac
  fi
  [[ "$delay" =~ ^[0-9]+$ ]] || delay=$interval
  received=$(quota_shadow_now)
  # ── 采样成功 → 写台账（OAuth 自此不再只是影子）──────────────────────
  # ⚠️ 必须放在 received 赋值**之后**：它就是这次读数的观测时刻。首版放在 outcome
  #    判定处，那时 received 还没赋值，set -u 让整个采样当场失败、连影子事件都写不出来。
  # 身份用 before_email：上面已比对过 before/after，不一致会判成 identity_changed
  # 走不到这里，所以到这一步身份是已核验的。
  # 百分比可能是小数 —— 用截断不用四舍五入：宁可把 89.6 报成 89，也不要报成 90
  # 去触发一次本不该发生的切号。
  if [[ "$outcome" == "ok" && "$QUOTA_OAUTH_WRITES_LEDGER" == "1" && -n "$before_email" ]]; then
    local _li _lw _rc=0
    _li=$(awk -v v="$five" 'BEGIN{printf "%d", int(v)}' 2>/dev/null || echo "")
    _lw=$(awk -v v="$week" 'BEGIN{printf "%d", int(v)}' 2>/dev/null || echo "")
    if [[ "$_li" =~ ^[0-9]+$ && "$_lw" =~ ^[0-9]+$ ]]; then
      quota_reading_apply "oauth_api" "$received" "$before_email" "$_li" "$_lw" \
        "${five_epoch:-}" "${week_epoch:-}" || _rc=$?
      (( _rc == 1 )) && quota_log "❌ OAuth reading could not be written to the ledger ($before_email five=${_li}%)"
    fi
  fi
  next_due=$(( received + delay ))
  if [[ "$http" =~ ^[0-9]{3}$ ]]; then http_json=$((10#$http)); else http_json=null; fi
  event=$(QS_JQ_EMAIL="$before_email" QS_JQ_AFTER_EMAIL="$after_email" \
    jq -cn --arg outcome "$outcome" --arg uuid "$before_uuid" \
    --arg after_uuid "$after_uuid" \
    --argjson attempted "$now" --argjson observed "$received" --argjson latency "$latency_ms" \
    --argjson status "$http_json" --argjson next "$next_due" --argjson windows "$windows" \
    --argjson cadence "$cadence" --argjson adaptive_interval "$penalty_interval" '
      {schema:1, source:"oauth_api", mode:"shadow", decision_eligible:false,
       attempted_at:$attempted, observed_at:$observed, latency_ms:$latency,
       account:{email:$ENV.QS_JQ_EMAIL,uuid:$uuid},
       identity_after:{email:$ENV.QS_JQ_AFTER_EMAIL,uuid:$after_uuid},
       http_status:$status, outcome:$outcome, next_due:$next,
       windows:$windows, cadence:$cadence,
       adaptive_interval_seconds:(if $adaptive_interval > 0 then $adaptive_interval else null end)}' 2>/dev/null) || event=''
  next_state=$(printf '%s' "$claim" | jq -c --arg outcome "$outcome" \
    --arg marker "$marker" --argjson failures "$failures" --argjson next "$next_due" \
    --argjson event "${event:-null}" '
      .schema=1 | .mode="shadow" | .decision_eligible=false
      | .attempt_in_progress=null | .updated_at=($event.observed_at // 0)
      | .next_due=$next | .last_outcome=$outcome
      | .consecutive_failures=$failures | .credential_marker=$marker
      | .last_attempt=$event
      | if $outcome == "ok" then .last_good=$event else . end' 2>/dev/null || true)
  [[ -n "$event" ]] && quota_shadow_append_event "$QUOTA_SHADOW_OAUTH_EVENTS" "$event" || true
  [[ -n "$event" ]] && quota_source_append "$event" || true
  [[ -n "$next_state" ]] && quota_shadow_atomic_write "$QUOTA_SHADOW_OAUTH_STATE" "$next_state" || true
  [[ -n "${body_file:-}" ]] && rm -f "$body_file"
  [[ -n "${header_file:-}" ]] && rm -f "$header_file"
  return 0
)

# OAuth 的实验频率不能搭载在 /usage 主循环上：主循环自身约 8 秒再 sleep 10 秒，
# 20 秒档会被量化成约 36 秒。独立轻量 worker 按 next_due 睡眠；它只写影子文件，
# The main decision state does not observe it at all.
# 主决策状态完全不感知它。
quota_shadow_poller_loop() {
  [[ "$QUOTA_SHADOW_ENABLED" == "1" && "$QUOTA_SHADOW_OAUTH_ENABLED" == "1" ]] || return 0
  echo $$ > "$QUOTA_SHADOW_PIDFILE"
  trap '
    owner=$(cat "$QUOTA_SHADOW_PIDFILE" 2>/dev/null || true)
    [[ "$owner" == "$$" ]] && rm -f "$QUOTA_SHADOW_PIDFILE"
    exit 0
  ' TERM INT EXIT
  quota_log "OAuth shadow sampler started pid=$$"
  while true; do
    local owner now next wait_s
    owner=$(cat "$QUOTA_SHADOW_PIDFILE" 2>/dev/null || echo "$$")
    if [[ "$owner" =~ ^[0-9]+$ ]] && [[ "$owner" != "$$" ]] \
       && kill -0 "$owner" 2>/dev/null; then
      quota_log "OAuth shadow sampler $$ found the pidfile owned by live $owner -> exiting"
      trap - EXIT
      exit 0
    fi
    quota_shadow_oauth_sample || true
    now=$(quota_shadow_now)
    next=$(quota_shadow_json_read "$QUOTA_SHADOW_OAUTH_STATE" 2>/dev/null \
      | jq -r '.next_due // 0' 2>/dev/null || echo 0)
    [[ "$next" =~ ^[0-9]+$ ]] || next=0
    wait_s=$(( next - now ))
    (( wait_s < 1 )) && wait_s=1
    # 最长 30 秒醒一次，便于进程替换和人工观察；due 未到不会发网络请求。
    (( wait_s > 30 )) && wait_s=30
    sleep "$wait_s"
  done
}

quota_shadow_poller_ensure() {
  [[ "$QUOTA_SHADOW_ENABLED" == "1" && "$QUOTA_SHADOW_OAUTH_ENABLED" == "1" ]] || return 0
  if [[ -f "$QUOTA_SHADOW_PIDFILE" ]]; then
    local p; p=$(cat "$QUOTA_SHADOW_PIDFILE" 2>/dev/null || echo 0)
    [[ "$p" =~ ^[0-9]+$ ]] && kill -0 "$p" 2>/dev/null && return 0
  fi
  local self pid; self=$(readlink -f "${BASH_SOURCE[0]}")
  nohup "$self" shadow-poller >/dev/null 2>&1 &
  pid=$!
  echo "$pid" > "$QUOTA_SHADOW_PIDFILE"
  quota_log "OAuth shadow sampler was not running; started pid=$pid"
}

# quota_snapshot — 读一份额度快照
# echo: fetched_ts<TAB>uuid<TAB>email<TAB>five_pct<TAB>five_reset_ts<TAB>week_pct<TAB>week_reset_ts
# return 1 = 文件不可读 / 无 cachedUsageUtilization
quota_snapshot() {
  local f; f=$(quota_claude_json)
  [[ -r "$f" ]] || return 1
  local raw
  raw=$(jq -r '
    (.cachedUsageUtilization // {}) as $c |
    [ (($c.fetchedAtMs // 0) / 1000 | floor),
      ($c.accountUuid // ""),
      (.oauthAccount.emailAddress // ""),
      ($c.utilization.five_hour.utilization // -1),
      ($c.utilization.five_hour.resets_at // ""),
      ($c.utilization.seven_day.utilization // -1),
      ($c.utilization.seven_day.resets_at // "")
    ] | @tsv' "$f" 2>/dev/null) || return 1
  [[ -z "$raw" ]] && return 1
  local ft; ft=$(printf '%s' "$raw" | cut -f1)
  [[ "$ft" =~ ^[0-9]+$ ]] || return 1
  (( ft > 0 )) || return 1
  printf '%s\n' "$raw"
}

# quota_snapshot_fresh — 快照 + 新鲜度闸。陈旧一律 return 1（当「未知」，不动作）。
quota_snapshot_fresh() {
  local now="$1" max_age snap ft
  # 用可用窗口，不用 interval×factor：cc 的 /usage 拉取带缓存，轮询再密也拿不到更新的值，
  # 拿 interval 推出来的 120s 会把完全可用的读数一律判成陈旧、整个系统空转。
  max_age=$QUOTA_FETCH_MAX_AGE
  snap=$(quota_snapshot) || return 1
  ft=$(printf '%s' "$snap" | cut -f1)
  (( now - ft > max_age )) && return 1
  printf '%s\n' "$snap"
}

