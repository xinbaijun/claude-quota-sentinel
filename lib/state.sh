# shellcheck shell=bash
# lib/state.sh — the state ledger, guards and derived quantities
#                状态台账、守卫与派生量
#
# Provenance: `sentinel-quota` @ e2f32279, sections "四、状态文件" onward.
# This is a **subset**: everything belonging to the switching half (the switch
# ledger, candidate ranking, exhaustion handling) and everything depending on fleet
# session enumeration was left behind. `quota_refresh_force_due` is rewritten — see
# the note on it. Per-function baseline line ranges, and the full list of what was
# not extracted, are in docs/PROVENANCE.md.
# 抽取来源：基线 e2f32279 的「四、状态文件」及其后各节。这是一个**子集**：切号那一半
# （切号流水账、候选排序、全耗尽处置）与一切依赖编队会话枚举的东西都留在门外。
# `quota_refresh_force_due` 被重写，理由写在它自己的注释里。
# 逐函数行号与「未抽取清单」见 docs/PROVENANCE.md。
#
# ════════════════════════════════════════════════════════════════════════
# State file (one account-level fact, replacing the old per-session in-memory queue)
# 四、状态文件（账号级单一事实，取代旧的 per-session 内存队列）
#
# The old implementation used an associative array keyed by session name as a queue.
# Three problems:
#   ① purely in memory → a restart lost all of it
#   ② entries were only unset on a successful resume → a dead session's entry stayed
#      forever, so the queue held a dozen entries while only ~5 were real
#   ③ hitting the limit is an **account-level** fact (one account, the whole fleet
#      hits it together), yet it was stored as N per-session copies
# One account-level fact, persisted, made all three disappear at once — and made the
# limit state externally visible for the first time.
# 旧实现用按会话名索引的关联数组当队列，问题有三：①纯内存 → 重启全丢；②只在成功恢复时
# 才 unset → 会话死了条目永留；③撞限本是**账号级**事实，却存了 N 份 per-session 副本。
# 改成账号级单条事实 + 落盘后，这三条一起消失，并且撞限状态第一次对外可见。
# ════════════════════════════════════════════════════════════════════════

quota_state_read() { [[ -s "$QUOTA_STATE" ]] && jq -e . "$QUOTA_STATE" >/dev/null 2>&1 && cat "$QUOTA_STATE"; }

quota_state_get() {
  local path="$1" def="${2:-}"
  local v; v=$(quota_state_read 2>/dev/null | jq -r "$path // empty" 2>/dev/null)
  [[ -z "$v" ]] && v="$def"
  printf '%s' "$v"
}

# ── Timestamp rendering: always carry the offset, never consult zoneinfo ────
#    时刻渲染：一律带偏移量，且不依赖 zoneinfo
#
# See lib/config.sh (QUOTA_TZ_OFFSET_SEC) for the full reasoning. Short version:
# `date -u -d @(ts + offset)` is a UTC render plus arithmetic, so it consults no
# time-zone database at render time and therefore cannot silently degrade to UTC the
# way a bare `TZ=<name>` does on a host without tzdata.
# 完整理由见 lib/config.sh 的 QUOTA_TZ_OFFSET_SEC 一节。短版：`date -u -d @(ts+偏移)`
# 是 UTC 渲染加算术，渲染时不查时区库，因此不会像裸 `TZ=<区域名>` 那样在缺 tzdata 的
# 宿主上静默退回 UTC。
quota_fmt_ts() {
  local ts="${1:-}" fmt="${2:-%Y-%m-%d %H:%M:%S}"
  [[ "$ts" =~ ^[0-9]+$ ]] || { printf '(none)'; return 0; }
  printf '%s %s' "$(date -u -d "@$(( ts + QUOTA_TZ_OFFSET_SEC ))" "+$fmt" 2>/dev/null)" "$QUOTA_TZ_LABEL"
}

# Human-readable duration: "3m ago" / "in 1h 13m". Negative = already past.
# 人话时长："3m ago" / "in 1h 13m"。负数=已过去。
quota_fmt_delta() {
  local sec="${1:-0}" ; local a=${sec#-}
  local out
  if   (( a < 60 ));    then out="${a}s"
  elif (( a < 3600 ));  then out="$(( a / 60 ))m"
  elif (( a < 86400 )); then out="$(( a / 3600 ))h $(( (a % 3600) / 60 ))m"
  else out="$(( a / 86400 ))d $(( (a % 86400) / 3600 ))h"
  fi
  if [[ "$sec" == -* ]]; then printf '%s ago' "$out"; else printf 'in %s' "$out"; fi
}

# ISO8601（服务端给的是 UTC，形如 2026-08-21T07:30:00+00:00）→ epoch
quota_iso_to_epoch() {
  local iso="${1:-}"
  [[ -n "$iso" ]] || return 1
  date -d "$iso" +%s 2>/dev/null
}

quota_state_merge() {
  local expr="$1"; shift
  local cur tmp
  cur=$(quota_state_read 2>/dev/null || echo '{}')
  [[ -z "$cur" ]] && cur='{}'
  mkdir -p "$(dirname "$QUOTA_STATE")" 2>/dev/null
  tmp=$(mktemp "${QUOTA_STATE}.XXXXXX") || return 1
  # ⚠️ 先带格式化跑；失败就退回**只做本来那次合并**。
  #    可读时间是给人看的附加品，绝不能因为它让状态写入失败——那会让整套停摆。
  if printf '%s' "$cur" | jq -c --argjson tzoff "$QUOTA_TZ_OFFSET_SEC" --arg tzlabel "$QUOTA_TZ_LABEL" \
        "$@" "$expr | $QUOTA_TIME_NORMALIZE_JQ" > "$tmp" 2>/dev/null \
     || printf '%s' "$cur" | jq -c "$@" "$expr" > "$tmp" 2>/dev/null; then
    if mv -f "$tmp" "$QUOTA_STATE"; then
      return 0
    fi
  fi
  rm -f "$tmp"
  return 1
}

# ── `/usage` network-refresh scheduling (decoupled from the 10s local frame sampling)
#    `/usage` 网络刷新调度（与 10s 本地画面采样解耦）─────────────────────
quota_usage_interval_current() {
  local email="$1" uuid="$2" state_email state_uuid five week
  state_email=$(quota_state_get '.account' "")
  state_uuid=$(quota_state_get '.uuid' "")
  if [[ "$state_email" != "$email" || "$state_uuid" != "$uuid" ]]; then
    printf '%s\n' "$QUOTA_USAGE_INTERVAL_NEAR"
    return 0
  fi
  five=$(quota_state_get '.five_hour' "")
  week=$(quota_state_get '.seven_day' "")
  quota_usage_interval_for_values "$five" "$week"
}

# quota_estimate_values <now> — echo "预估five 预估week"；无法预估时返回 1。
# 与真实值并行，只在两次真实读数之间起作用。
quota_estimate_values() {
  local now="$1" base_five base_week base_ts rate_f rate_w lead sw
  [[ "$QUOTA_ESTIMATE" == "1" ]] || return 1
  [[ "$now" =~ ^[0-9]+$ ]] || return 1
  base_five=$(quota_state_get '.five_hour' ""); [[ "$base_five" =~ ^[0-9]+$ ]] || return 1
  base_week=$(quota_state_get '.seven_day' ""); [[ "$base_week" =~ ^[0-9]+$ ]] || return 1
  base_ts=$(quota_state_get '.fetched_ts' "");  [[ "$base_ts"  =~ ^[0-9]+$ ]] || return 1
  # 切号之后、真实读数之前不外推：那一刻的速度属于上一个账号。
  sw=$(quota_state_get '.last_switch_ts' 0); [[ "$sw" =~ ^[0-9]+$ ]] || sw=0
  (( sw > base_ts )) && return 1
  lead=$(( now - base_ts ))
  (( lead <= 0 )) && { printf '%s %s\n' "$base_five" "$base_week"; return 0; }
  # 超过上限就不再外推：那说明查询本身出了故障，是另一个问题，不该靠外推硬撑。
  [[ "$QUOTA_ESTIMATE_MAX_LEAD" =~ ^[0-9]+$ ]] || return 1
  (( lead > QUOTA_ESTIMATE_MAX_LEAD )) && return 1
  rate_f=$(quota_state_get '.burn_rate_five' 0); [[ "$rate_f" =~ ^[0-9.]+$ ]] || rate_f=0
  rate_w=$(quota_state_get '.burn_rate_week' 0); [[ "$rate_w" =~ ^[0-9.]+$ ]] || rate_w=0
  awk -v bf="$base_five" -v bw="$base_week" -v rf="$rate_f" -v rw="$rate_w" -v l="$lead" \
    'BEGIN{printf "%d %d\n", bf + rf*l, bw + rw*l}'
}

# quota_estimate_exceeds <now> — 预估值是否已越过切换线
quota_estimate_exceeds() {
  local now="$1" vals ef ew
  vals=$(quota_estimate_values "$now") || return 1
  ef=${vals%% *}; ew=${vals##* }
  [[ "$ef" =~ ^[0-9]+$ && "$ew" =~ ^[0-9]+$ ]] || return 1
  (( ef >= QUOTA_SWITCH_PCT_FIVE || ew >= QUOTA_SWITCH_PCT_WEEK ))
}

# quota_refresh_force_due — promote this round to "due" and query `/usage` now,
# instead of sitting out the rest of the interval.
#
# 🔻 REWRITTEN DURING EXTRACTION. Upstream had three trigger sources; two of them
#    read fleet-specific data and did not come across:
#      ① a session's on-screen banner self-reporting a high level ← fleet screen log
#      ② a jump in concurrency ← enumerating fleet worker sessions
#    Only ③ (the estimate crossing the line) survives. Upstream already ranked it as
#    "the one that most deserves immediate verification", so the ordering is
#    unchanged — the other two are simply absent.
# 🔻 抽取时**重写过**。上游有三个触发源，其中两个读 Fleet 专有数据、没有过来：
#      ①会话横幅自报高水位 ← 编队屏幕留档
#      ②并发骤增 ← 枚举编队 worker 会话
#    只保留③（预估越线）。上游本来就把它排为「最该立刻核实的一种」，所以次序没变，
#    只是另外两个不在了。
quota_refresh_force_due() {
  local now="$1" last reason=""
  [[ "$QUOTA_FORCE_REFRESH" == "1" ]] || return 1
  [[ "$now" =~ ^[0-9]+$ ]] || return 1
  last=$(quota_state_get '.force_refresh_last_ts' 0)
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  (( now - last < QUOTA_FORCE_REFRESH_COOLDOWN )) && return 1

  # ③ The estimate has crossed the line: this is the one that most deserves
  #    immediate verification.
  # ③ 预估值已越线：这是最该立刻核实的一种。
  if quota_estimate_exceeds "$now"; then
    reason="estimate crossed the line ($(quota_estimate_values "$now" | tr ' ' '/'))"
  fi
  [[ -n "$reason" ]] || return 1
  quota_state_merge '.force_refresh_last_ts = $t' --argjson t "$now" || return 1
  quota_log "⚡ forcing one early /usage query: ${reason} -> not waiting for the next tier (query only; this never drives a switch)"
  return 0
}

quota_usage_refresh_due() {
  local now="$1" email="$2" uuid="$3" generation="${4:-}" launch_id="${5:-}"
  local s_email s_uuid s_gen s_launch next
  s_email=$(quota_state_get '.usage_refresh.account' "")
  s_uuid=$(quota_state_get '.usage_refresh.uuid' "")
  s_gen=$(quota_state_get '.usage_refresh.monitor_generation' "")
  s_launch=$(quota_state_get '.usage_refresh.monitor_launch_id' "")
  next=$(quota_state_get '.usage_refresh.next_due_ts' 0)
  [[ "$next" =~ ^[0-9]+$ ]] || next=0
  [[ "$s_email" == "$email" && "$s_uuid" == "$uuid" \
     && -n "$generation" && "$s_gen" == "$generation" \
     && -n "$launch_id" && "$s_launch" == "$launch_id" ]] || return 0
  (( now >= next )) && return 0
  quota_refresh_force_due "$now"
}

quota_usage_refresh_begin() {
  local now="$1" email="$2" uuid="$3" generation="$4" launch_id="$5"
  local mode="${6:-scheduled}"
  local base backoff effective seq next
  base=$(quota_usage_interval_current "$email" "$uuid")
  backoff=$(quota_state_get '.usage_refresh.backoff_seconds' 0)
  [[ "$backoff" =~ ^[0-9]+$ ]] || backoff=0
  effective=$base
  if [[ "$(quota_state_get '.usage_refresh.account' "")" == "$email" \
     && "$(quota_state_get '.usage_refresh.uuid' "")" == "$uuid" \
     && "$backoff" -gt "$effective" ]]; then
    effective=$backoff
  fi
  seq=$(quota_state_get '.usage_refresh.refresh_seq' 0)
  [[ "$seq" =~ ^[0-9]+$ ]] || seq=0
  seq=$(( seq + 1 )); next=$(( now + effective ))
  QS_JQ_E="$email" quota_state_merge '
      .usage_refresh =
        ((if ((.usage_refresh.account // "") == $ENV.QS_JQ_E and (.usage_refresh.uuid // "") == $u)
          then (.usage_refresh // {}) else {} end)
         + {account:$ENV.QS_JQ_E, uuid:$u, monitor_generation:$g,
            monitor_launch_id:$l,
            refresh_seq:$seq, last_attempt_ts:$t, next_due_ts:$next,
            interval_seconds:$interval, last_mode:$mode, last_outcome:"in_flight"})' \
    --arg u "$uuid" --argjson g "$generation" --arg l "$launch_id" \
    --argjson seq "$seq" --argjson t "$now" --argjson next "$next" \
    --argjson interval "$effective" --arg mode "$mode" || return 1
  QUOTA_REFRESH_SEQ=$seq
  QUOTA_REFRESH_INTERVAL=$effective
}

# penalize=1 只用于 429/last-known/refresh-failed 等明确不可信响应；普通 UI/解析故障
# 已在 begin 时把 next_due 推到当前档位，不会退化成每 10s 重打网络。
quota_usage_refresh_failure() {
  local now="$1" outcome="$2" penalize="${3:-0}" seq="${QUOTA_REFRESH_SEQ:-}"
  local current next_interval next
  [[ "$seq" =~ ^[0-9]+$ ]] || return 0
  current=$(quota_state_get '.usage_refresh.interval_seconds' "$QUOTA_USAGE_INTERVAL_NEAR")
  [[ "$current" =~ ^[0-9]+$ ]] || current=$QUOTA_USAGE_INTERVAL_NEAR
  next_interval=$current
  if [[ "$penalize" == "1" ]]; then
    next_interval=$(quota_usage_backoff_interval "$current")
  fi
  next=$(( now + next_interval ))
  quota_state_merge '
      if ((.usage_refresh.refresh_seq // -1) == $seq) then
        .usage_refresh.last_outcome = $outcome
        | .usage_refresh.last_failure_ts = $t
        | .usage_refresh.next_due_ts = $next
        | .usage_refresh.interval_seconds = $interval
        | .usage_refresh.backoff_seconds =
            (if $penalize then $interval else (.usage_refresh.backoff_seconds // null) end)
        | .usage_refresh.last_penalized_seq =
            (if $penalize then $seq else (.usage_refresh.last_penalized_seq // null) end)
      else . end' \
    --argjson seq "$seq" --arg outcome "$outcome" --argjson t "$now" \
    --argjson next "$next" --argjson interval "$next_interval" \
    --argjson penalize "$([[ "$penalize" == "1" ]] && echo true || echo false)"
}

# quota_panel_observations_prune_if_due — 调用方已持有 observations lock。
# 只删除 observed_at 明确早于 cutoff 的合法 JSON object；坏行、缺时间行与边界帧都保留，
# 防止单行损坏扩大成整份证据丢失。输出先写同目录临时文件，再 atomic rename。
quota_panel_observations_prune_if_due() {
  local now="${1:-}" last=0 cutoff tmp
  local stamp="${QUOTA_PANEL_PRUNE_STAMP:-${QUOTA_PANEL_OBSERVATIONS}.prune-ts}"
  [[ "$now" =~ ^[0-9]+$ \
     && "$QUOTA_PANEL_RETENTION_SEC" =~ ^[0-9]+$ \
     && "$QUOTA_PANEL_PRUNE_INTERVAL" =~ ^[0-9]+$ ]] || return 0
  (( QUOTA_PANEL_RETENTION_SEC > 0 && QUOTA_PANEL_PRUNE_INTERVAL > 0 )) || return 0

  if [[ -r "$stamp" ]]; then
    IFS= read -r last < "$stamp" || last=0
  fi
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  if (( now >= last && now - last < QUOTA_PANEL_PRUNE_INTERVAL )); then
    return 0
  fi

  cutoff=$(( now - QUOTA_PANEL_RETENTION_SEC ))
  # 先记 attempt，再做大文件扫描；即使磁盘/jq 临时失败，也不会退化成每 10 秒重扫。
  quota_shadow_atomic_write "$stamp" "$now" || return 1
  tmp=$(mktemp "${QUOTA_PANEL_OBSERVATIONS}.prune.XXXXXX") || return 1
  chmod 600 "$tmp" 2>/dev/null || true
  if ! jq -Rr --argjson cutoff "$cutoff" '
      . as $raw
      | (try ($raw | fromjson) catch null) as $event
      | (if ($event | type) == "object"
         then ($event.observed_at // null) else null end) as $ts
      | if (($event | type) == "object"
            and $event.schema == 1
            and $event.source == "usage_panel_screen"
            and ($ts | type) == "number"
            and $ts == ($ts | floor)
            and $ts > 0
            and $ts < $cutoff)
        then empty else $raw end
    ' "$QUOTA_PANEL_OBSERVATIONS" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  if cmp -s "$tmp" "$QUOTA_PANEL_OBSERVATIONS"; then
    rm -f "$tmp"
  elif ! mv -f "$tmp" "$QUOTA_PANEL_OBSERVATIONS"; then
    rm -f "$tmp"
    return 1
  fi
  chmod 600 "$QUOTA_PANEL_OBSERVATIONS" 2>/dev/null || true
  return 0
}

# 每次画面采样都写一条；这份是调查原始证据，不参与额度决策。
quota_panel_log_observation() (
  local observed="$1" email="$2" uuid="$3" mode="$4" status="$5" frame="$6"
  local parsed="" five="" week="" five_reset="" week_reset="" sha event lock_fd
  if parsed=$(quota_panel_parse "$frame" 2>/dev/null); then
    five=$(quota_panel_field "$parsed" 1)
    week=$(quota_panel_field "$parsed" 2)
    five_reset=$(quota_panel_field "$parsed" 3)
    week_reset=$(quota_panel_field "$parsed" 4)
  fi
  sha=$(printf '%s' "$frame" | sha256sum | awk '{print $1}')
  event=$(QS_JQ_EMAIL="$email" jq -cn --arg uuid "$uuid" --arg mode "$mode" \
    --arg status "$status" --arg frame "$frame" --arg sha "$sha" \
    --arg five "$five" --arg week "$week" --arg five_reset "$five_reset" \
    --arg week_reset "$week_reset" --argjson observed "$observed" \
    --argjson local_interval "$QUOTA_POLL_INTERVAL" \
    --argjson refresh_seq "$(quota_state_get '.usage_refresh.refresh_seq' 0)" \
    --argjson network_interval "$(quota_state_get '.usage_refresh.interval_seconds' "$QUOTA_USAGE_INTERVAL_NEAR")" \
    --argjson next_due "$(quota_state_get '.usage_refresh.next_due_ts' 0)" '
      {schema:1,source:"usage_panel_screen",mode:$mode,decision_eligible:false,
       observed_at:$observed,status:$status,account:{email:$ENV.QS_JQ_EMAIL,uuid:$uuid},
       parsed:{five_hour:(if $five=="" then null else ($five|tonumber) end),
               seven_day:(if $week=="" then null else ($week|tonumber) end),
               five_reset_text:(if $five_reset=="" then null else $five_reset end),
               week_reset_text:(if $week_reset=="" then null else $week_reset end)},
       cadence:{local_sample_seconds:$local_interval,network_interval_seconds:$network_interval,
                next_network_due:$next_due,refresh_seq:$refresh_seq},
       panel_sha256:$sha,panel_text:$frame}') || return 0
  mkdir -p "$(dirname "$QUOTA_PANEL_OBSERVATIONS_LOCK")" 2>/dev/null || return 0
  exec {lock_fd}> "$QUOTA_PANEL_OBSERVATIONS_LOCK" || return 0
  chmod 600 "$QUOTA_PANEL_OBSERVATIONS_LOCK" 2>/dev/null || true
  flock "$lock_fd" || return 0
  touch "$QUOTA_PANEL_OBSERVATIONS" 2>/dev/null || return 0
  chmod 600 "$QUOTA_PANEL_OBSERVATIONS" 2>/dev/null || true
  quota_panel_observations_prune_if_due "$observed" || true
  printf '%s\n' "$event" >> "$QUOTA_PANEL_OBSERVATIONS"
)

# quota_account_guard — 共享配置的持续身份 fence。
#
# 切号工具只能证明「它回读的那一刻」写对了；宿主上的长跑 Claude 进程不参加工具锁，
# 可以在下一微秒拿旧内存快照原子覆盖回来。有限次数 sleep+回读永远关不掉这个时间窗，
# 所以这里把最后一次受控切号确认的 email+UUID 持久化，并在：轮询开头、面板前后、
# 清框前后、复工投递前全部重读。任何漂移都进入 account_drift，绝不把新值静默收编。
# 第二个参数可要求此刻必须就是某个目标账号（全耗尽等待路径使用）。
quota_account_guard() {
  local context="${1:-unspecified}" required_email="${2:-}"
  local raw actual_email="" oauth_uuid="" usage_uuid=""
  local expected_email expected_uuid state_account reason="" now last_log_ts last_reason last_actual should_log=0
  QUOTA_LAST_ERROR=""
  QUOTA_GUARD_EMAIL=""
  QUOTA_GUARD_UUID=""

  raw=$(quota_identity_read 2>/dev/null || true)
  if [[ -n "$raw" ]]; then
    IFS=$'\037' read -r actual_email oauth_uuid usage_uuid <<< "$raw"
  fi
  expected_email=$(quota_state_get '.account_guard.expected_email' "")
  expected_uuid=$(quota_state_get '.account_guard.expected_uuid' "")
  state_account=$(quota_state_get '.account' "")

  # ⚠️ 身份 = oauthAccount 的 email+uuid（切号即时生效、权威）。
  # cachedUsageUtilization.accountUuid 是**缓存归属标记**，只有跑过 /usage 才刷新——
  # 切号后它天然滞后（为空或还是上一个账号的）。把它当身份的一部分会造成死锁：
  # guard 要求它一致才放行，它要跑 /usage 才更新，跑 /usage 要先过 guard。
  # 2026-08-12 13:00 实撞：自动切号到 accountB **成功**，但备份恢复的 config 里
  # usage_uuid 为空 → 判 identity-missing fail closed → 切完不认账 → expected 停在
  # accountA → 此后每轮 account-drift 拦截，系统停摆 3 小时。
  # usage_uuid 与 oauth 不一致的真正含义是「面板缓存数值可能属于旧账号」——
  # 那由面板归属校验（monitor owner guard + 陈旧帧判据）处理，不阻塞身份认定。
  if [[ -z "$actual_email" || -z "$oauth_uuid" ]]; then
    reason="identity-missing"
  elif [[ -n "$required_email" && "$actual_email" != "$required_email" ]]; then
    reason="target-mismatch"
  elif [[ -z "$expected_email" && -n "$state_account" && "$actual_email" != "$state_account" ]]; then
    # 首次升级也不能盲采“此刻文件”为基线：state.account 是上一轮已归属的面板账号；
    # 两者不同且没有受控切号写 expected，正是无成功事件的静默回退签名。
    reason="account-drift"
  elif [[ -z "$expected_email" ]]; then
    # 升级存量状态时只建立一次基线；之后再看到别的账号绝不自动改基线。
    if ! QS_JQ_E="$actual_email" quota_state_merge '
        .account_guard.expected_email = $ENV.QS_JQ_E
        | .account_guard.expected_uuid = $u
        | .account_guard.established_ts = $t
        | .account_guard.last_ok_ts = $t' \
        --arg u "$oauth_uuid" --argjson t "$(date +%s)"; then
      QUOTA_LAST_ERROR="account-guard:state-write-failed"
      return 1
    fi
    quota_log "🔒 account guard baseline established: $actual_email (context=$context)"
    QUOTA_GUARD_EMAIL="$actual_email"
    QUOTA_GUARD_UUID="$oauth_uuid"
    return 0
  elif [[ -z "$expected_uuid" ]]; then
    if [[ "$actual_email" == "$expected_email" ]]; then
      quota_state_merge '.account_guard.expected_uuid = $u' --arg u "$oauth_uuid" || return 1
      QUOTA_GUARD_EMAIL="$actual_email"
      QUOTA_GUARD_UUID="$oauth_uuid"
      return 0
    fi
    reason="account-drift"
  elif [[ "$actual_email" != "$expected_email" || "$oauth_uuid" != "$expected_uuid" ]]; then
    reason="account-drift"
  else
    # 调用方若要把面板数值归属到账号，必须直接消费这一次 guard 的同一快照；
    # guard 通过后再读一次文件会重新打开覆盖落在两次读取之间的 TOCTOU。
    QUOTA_GUARD_EMAIL="$actual_email"
    QUOTA_GUARD_UUID="$oauth_uuid"
    return 0
  fi

  now=$(date +%s)
  last_log_ts=$(quota_state_get '.account_guard.last_drift.log_ts' 0)
  last_reason=$(quota_state_get '.account_guard.last_drift.reason' "")
  last_actual=$(quota_state_get '.account_guard.last_drift.actual_email' "")
  [[ "$last_log_ts" =~ ^[0-9]+$ ]] || last_log_ts=0
  if (( now - last_log_ts >= QUOTA_ACCOUNT_DRIFT_LOG_INTERVAL )) \
     || [[ "$last_reason" != "$reason" || "$last_actual" != "$actual_email" ]]; then
    should_log=1
    last_log_ts=$now
  fi
  QUOTA_LAST_ERROR="account-guard:$reason"
  QS_JQ_AE="$actual_email" quota_state_merge '
      .phase = "account_drift"
      | .poll.last_error = $err
      | .account_guard.last_drift = {
          ts:$t, log_ts:$lt, context:$ctx, reason:$r,
          actual_email:$ENV.QS_JQ_AE, actual_oauth_uuid:$au, actual_usage_uuid:$uu
        }' \
    --arg err "$QUOTA_LAST_ERROR" --argjson t "$now" --argjson lt "$last_log_ts" \
    --arg ctx "$context" --arg r "$reason" \
    --arg au "$oauth_uuid" --arg uu "$usage_uuid" || true
  if (( should_log )); then
    quota_log "❌ account identity guard blocked ($reason, context=$context): expected [${expected_email:-not-established}], actual [${actual_email:-unreadable}] -> fail closed, not following"
  fi
  # ⚠️ 外部切号也要进流水账，但漂移每一拍都会复现，不能每拍记一条。
  #    只在「当前实际账号」与上次记过的不同时记 —— 一次切号只留一条。
  if [[ -n "$actual_email" ]]; then
    local last_rec; last_rec=$(quota_state_get '.account_guard.last_switch_recorded' "")
    if [[ "$last_rec" != "$actual_email" ]]; then
      quota_account_switch_record "$now" "${expected_email:-unknown}" "$actual_email" "external" \
        "not initiated by this tool; the guard has failed closed and is not following. If this was intended, switch with: quota-sentinel switches (to review) then account-switch --use $actual_email"
      QS_JQ_A="$actual_email" quota_state_merge \
        '.account_guard.last_switch_recorded = $ENV.QS_JQ_A' || true
    fi
  fi
  return 1
}

# quota_monitor_owner_guard — 面板归属还要与“监控会话启动时的账号”一致。
# 只做共享文件的 A→A bracket 仍挡不住 ABA：文件可在中间短暂变 B，monitor 按 B 重启，
# 面板读完前又回 A。此时 persistent expected 会通过，但 B-monitor 的数不能记给 A。
quota_monitor_owner_guard() {
  local context="${1:-monitor-owner}" monitor_email monitor_uuid monitor_gen monitor_launch
  local live_gen live_launch
  monitor_email=$(quota_state_get '.monitor_account' "")
  monitor_uuid=$(quota_state_get '.monitor_uuid' "")
  monitor_gen=$(quota_state_get '.monitor_session_created' "")
  monitor_launch=$(quota_state_get '.monitor_launch_id' "")
  live_gen=$(quota_session_created "$QUOTA_MONITOR_SESSION" 2>/dev/null || true)
  live_launch=$(quota_monitor_live_launch_id 2>/dev/null || true)
  if [[ -z "$monitor_email" || -z "$monitor_uuid" || ! "$monitor_gen" =~ ^[0-9]+$ \
     || -z "$monitor_launch" ]]; then
    QUOTA_LAST_ERROR="account-guard:monitor-owner-missing"
    quota_log "❌ monitor session ownership missing (context=$context) -> panel values voided"
    return 1
  fi
  if [[ -z "$live_gen" || "$live_gen" != "$monitor_gen" ]]; then
    QUOTA_LAST_ERROR="account-guard:monitor-generation-mismatch"
    quota_log "❌ monitor session generation does not match the owner record (context=$context) -> panel values voided"
    return 1
  fi
  if [[ -z "$live_launch" || "$live_launch" != "$monitor_launch" ]]; then
    QUOTA_LAST_ERROR="account-guard:monitor-launch-mismatch"
    quota_log "❌ monitor CLI launch generation does not match the owner record (context=$context) -> panel values voided"
    return 1
  fi
  quota_account_guard "$context" "$monitor_email" || return 1
  if [[ "$QUOTA_GUARD_UUID" != "$monitor_uuid" ]]; then
    QUOTA_LAST_ERROR="account-guard:monitor-owner-mismatch"
    quota_state_merge '.phase = "account_drift" | .poll.last_error = $e' \
      --arg e "$QUOTA_LAST_ERROR" || true
    quota_log "❌ monitor session UUID does not match the post-panel identity (context=$context) -> panel values voided"
    return 1
  fi
  return 0
}

# 新建/重启 monitor 后，把账号身份与 tmux session generation、cc launch id 一起登记。
# 只记录 email/UUID 会让同名 tmux 或原 pane 内的旧 cc 冒用新一代 owner 证明。
quota_monitor_bind_owner() {
  local context="$1" expected_email="$2" expected_uuid="$3" expected_launch="${4:-}"
  local launch_email="${5:-}" launch_uuid="${6:-}" live_gen live_launch
  [[ -n "$expected_launch" ]] || {
    QUOTA_LAST_ERROR="account-guard:monitor-bind-launch-missing"
    quota_log "❌ this monitor launch has no generation -> owner not recorded"
    return 1
  }
  if [[ "$launch_email" != "$expected_email" || -z "$launch_uuid" \
     || "$launch_uuid" != "$expected_uuid" ]]; then
    QUOTA_LAST_ERROR="account-guard:monitor-bind-launch-identity-mismatch"
    quota_log "❌ the account identity at monitor launch does not match expected -> owner not recorded"
    return 1
  fi
  quota_account_guard "$context" "$expected_email" || return 1
  if [[ -z "$expected_uuid" || "$QUOTA_GUARD_UUID" != "$expected_uuid" ]]; then
    QUOTA_LAST_ERROR="account-guard:monitor-bind-uuid-mismatch"
    quota_log "❌ the account UUID after the monitor launch differs from before it (context=$context) -> owner not recorded"
    return 1
  fi
  live_gen=$(quota_session_created "$QUOTA_MONITOR_SESSION") || return 1
  live_launch=$(quota_monitor_live_launch_id) || return 1
  if [[ "$live_launch" != "$expected_launch" ]]; then
    QUOTA_LAST_ERROR="account-guard:monitor-bind-launch-mismatch"
    quota_log "❌ the launch id was rewritten concurrently after the monitor launch -> owner not recorded"
    return 1
  fi
  if ! QS_JQ_A="$expected_email" quota_state_merge '
      .monitor_account = $ENV.QS_JQ_A
      | .monitor_uuid = $u
      | .monitor_session_created = $g
      | .monitor_launch_id = $l' \
      --arg u "$expected_uuid" \
      --argjson g "$live_gen" --arg l "$live_launch"; then
    quota_log "❌ monitor ownership/generation could not be persisted -> not reading the panel"
    return 1
  fi
}

quota_session_created() {
  local created
  created=$(tmux display-message -p -t "$1" '#{session_created}' 2>/dev/null) || return 1
  [[ "$created" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$created"
}

quota_session_generation_matches() {
  local session="$1" expected="${2:-}" current
  [[ -n "$expected" ]] || expected=$(quota_state_get ".sessions[\"$session\"].session_created" "")
  [[ "$expected" =~ ^[0-9]+$ ]] || return 1
  current=$(quota_session_created "$session") || return 1
  [[ "$current" == "$expected" ]]
}

# quota_scan_live_menus — 每轮都跑的轻量巡扫，**不依赖任何事故痕迹**。
#
# 2026-08-19 16:5x 实撞暴露的结构洞：quota_clear_menus 全脚本只在两处被调用——
# 全账号撞限，和 quota_after_recovery 里那段「有 waiting/episode 痕迹才扫」的补扫。
# 于是一旦某轮恢复得很顺利、把痕迹清干净了，**就再也没有任何一轮会去看会话的屏幕**。
# 当天 16:03 和 16:14 新建的两个会话弹着撞限框，16:11:51 收尾清掉痕迹之后无人问津，
# 直到我手工去查才发现——判据认得出它们（quota_menu_present 返回真），只是没人去问。
#
# ⚠️ 方向是反的才是要命处：**恢复得越顺利、痕迹清得越干净，越没人扫**。
#
# ⚠️ 但也不能无条件全扫。原补扫注释里那条警告仍然成立：屏幕上留着**旧**撞限横幅的
#    会话很常见（排查会话自己就是），纯 normal 状态下拿历史横幅登记 = 打扰正在正常
#    干活的人。所以这里只认**活菜单**：quota_menu_present 要求最后 8 行里有
#    `Enter to confirm · Esc to cancel` 且没有空闲光标——那是**此刻正弹着框**的
#    现在时证据，不可能是滚动区里的历史残留。
#    「只有横幅、没有活菜单」那一类继续留给原来的补扫（受事故痕迹约束），不在这里处理。
quota_capture_pane_tail() { tmux capture-pane -t "$1" -p -S -50 2>/dev/null; }

quota_ratio_update() {
  local now="$1" acct="$2" five="$3" week="$4"
  local snap l_acct l_five l_week add_f=0 add_w=0
  snap=$(quota_state_read 2>/dev/null || echo '{}')
  IFS=$'\t' read -r l_acct l_five l_week < <(printf '%s' "$snap" \
    | jq -r '(.ratio.last // {}) | "\(.acct // "")\t\(.five // -1)\t\(.week // -1)"' 2>/dev/null)
  # 只在同一账号、且两个百分比都没回退时才累计：
  #   账号变了 → 两条曲线不可比
  #   five 回退 → 五小时窗口刚重置，落差不是消耗
  #   week 回退 → 要么周重置了，要么读到了别的账号（历史上真发生过）
  if [[ "$l_acct" == "$acct" && "$l_five" =~ ^[0-9]+$ && "$l_week" =~ ^[0-9]+$ ]] \
     && (( five >= l_five && week >= l_week )); then
    add_f=$(( five - l_five )); add_w=$(( week - l_week ))
  fi
  QS_JQ_A="$acct" quota_state_merge '.ratio.last = {acct:$ENV.QS_JQ_A, five:$f, week:$w}
      | .ratio.five_total = ((.ratio.five_total // 0) + $af)
      | .ratio.week_total = ((.ratio.week_total // 0) + $aw)
      | .ratio.updated = $t' \
    --argjson f "$five" --argjson w "$week" \
    --argjson af "$add_f" --argjson aw "$add_w" --argjson t "$now"
}

# quota_ratio_value — echo "<比值> <来源>"；样本不够就用种子值
quota_ratio_value() {
  local ft wt
  IFS=$'\t' read -r ft wt < <(quota_state_read 2>/dev/null \
    | jq -r '"\(.ratio.five_total // 0)\t\(.ratio.week_total // 0)"' 2>/dev/null)
  [[ "$ft" =~ ^[0-9]+$ ]] || ft=0
  [[ "$wt" =~ ^[0-9]+$ ]] || wt=0
  if (( ft >= QUOTA_RATIO_MIN_FIVE && wt > 0 )); then
    awk -v w="$wt" -v f="$ft" 'BEGIN{printf "%.4f measured(dfive=%d)", w/f, f}'
  else
    awk -v s="$QUOTA_RATIO_SEED" -v f="$ft" 'BEGIN{printf "%.4f seed(sample dfive=%d too small)", s, f}'
  fi
}

quota_capacity_update() {
  local now="$1" snap known week_used five_used line
  snap=$(quota_state_read 2>/dev/null || echo '{}')
  line=$(printf '%s' "$snap" | jq -r '
    [ (.accounts // {}) | .[] | select(.week != null) ] as $a |
    "\($a|length)\t\([$a[].week]|add // 0)\t\([$a[] | .five // 0]|add // 0)"' 2>/dev/null) || return 0
  IFS=$'\t' read -r known week_used five_used <<< "$line"
  [[ "$known" =~ ^[0-9]+$ ]] || return 0
  (( known == 0 )) && return 0

  # 采样：每 INTERVAL 记一条。同时记下 known，取斜率时只用 known 相同的样本——
  # 第一次量到某个新账号会让总和跳一大截（未知→52%），那不是消耗，是信息补全。
  local last_ts
  last_ts=$(printf '%s' "$snap" | jq -r '(.capacity.samples // []) | (last.ts // 0)' 2>/dev/null)
  [[ "$last_ts" =~ ^[0-9]+$ ]] || last_ts=0
  if (( now - last_ts >= QUOTA_CAPACITY_SAMPLE_INTERVAL )); then
    quota_state_merge ".capacity.samples = (((.capacity.samples // []) + [{ts:\$t, known:\$k, week_used:\$w}]) | .[-${QUOTA_CAPACITY_SAMPLE_KEEP}:])" \
      --argjson t "$now" --argjson k "$known" --argjson w "$week_used"
    snap=$(quota_state_read 2>/dev/null || echo '{}')
  fi

  # 斜率：取 known 相同的那批样本的首尾
  local span delta rate="" runway=""
  line=$(printf '%s' "$snap" | jq -r --argjson k "$known" '
    [ (.capacity.samples // [])[] | select(.known == $k) ] as $s |
    if ($s|length) < 2 then "0\t0"
    else "\(($s[-1].ts) - ($s[0].ts))\t\(($s[-1].week_used) - ($s[0].week_used))" end' 2>/dev/null)
  IFS=$'\t' read -r span delta <<< "$line"
  local week_remaining=$(( known * 100 - week_used ))
  local five_remaining=$(( known * 100 - five_used ))
  if [[ "$span" =~ ^[0-9]+$ ]] && (( span >= QUOTA_CAPACITY_MIN_SPAN )) && [[ "$delta" =~ ^[0-9]+$ ]] && (( delta > 0 )); then
    rate=$(awk -v d="$delta" -v s="$span" 'BEGIN{printf "%.2f", d*3600/s}')
    runway=$(awk -v r="$week_remaining" -v d="$delta" -v s="$span" 'BEGIN{printf "%.1f", r*s/(d*3600)}')
  fi

  # 周重置地平线：取各账号里最早的一个
  local reset_in=""
  local wr; wr=$(printf '%s' "$snap" | jq -r --argjson n "$now" '
    [ (.accounts // {}) | .[] | .week_reset | select(. != null and . > $n) ] | min // empty' 2>/dev/null)
  [[ "$wr" =~ ^[0-9]+$ ]] && reset_in=$(awk -v x="$(( wr - now ))" 'BEGIN{printf "%.1f", x/3600}')

  local ratio_line ratio_val ratio_src cycles="" m_ratio="" m_five=0 m_week=0
  ratio_line=$(quota_ratio_value); ratio_val=${ratio_line%% *}; ratio_src=${ratio_line#* }
  # 累计实测值：不管够不够替换种子值的门槛都算出来并展示，好让人看着它收敛，
  # 也能一眼判断当前在用的到底是量出来的还是猜的。
  IFS=$'\t' read -r m_five m_week < <(quota_state_read 2>/dev/null \
    | jq -r '"\(.ratio.five_total // 0)\t\(.ratio.week_total // 0)"' 2>/dev/null)
  [[ "$m_five" =~ ^[0-9]+$ ]] || m_five=0
  [[ "$m_week" =~ ^[0-9]+$ ]] || m_week=0
  (( m_five > 0 )) && m_ratio=$(awk -v w="$m_week" -v f="$m_five" 'BEGIN{printf "%.4f", w/f}')
  if [[ "$ratio_val" =~ ^[0-9.]+$ ]] && awk -v r="$ratio_val" 'BEGIN{exit !(r>0)}'; then
    cycles=$(awk -v rem="$week_remaining" -v r="$ratio_val" 'BEGIN{printf "%.1f", rem/(r*100)}')
  fi
  quota_state_merge '.capacity += {
      week_five_ratio: ($rv|tonumber), week_five_ratio_src: $rs,
      week_five_ratio_measured: (if $mr == "" then null else ($mr|tonumber) end),
      ratio_sample_five: $mf, ratio_sample_week: $mw, ratio_sample_need: $mn,
      week_remaining_cycles: (if $cy == "" then null else ($cy|tonumber) end),
      updated: $t, accounts_known: $k,
      week_used_total: $wu, week_remaining_total: $wr_,
      five_remaining_total: $fr,
      week_burn_pct_per_hour: (if $rate == "" then null else ($rate|tonumber) end),
      week_runway_hours:      (if $rw   == "" then null else ($rw|tonumber) end),
      week_reset_in_hours:    (if $ri   == "" then null else ($ri|tonumber) end)
    }' \
    --argjson t "$now" --argjson k "$known" --argjson wu "$week_used" \
    --argjson wr_ "$week_remaining" --argjson fr "$five_remaining" \
    --arg rate "$rate" --arg rw "$runway" --arg ri "$reset_in" \
    --arg rv "$ratio_val" --arg rs "$ratio_src" --arg cy "$cycles" \
    --arg mr "$m_ratio" --argjson mf "$m_five" --argjson mw "$m_week" \
    --argjson mn "$QUOTA_RATIO_MIN_FIVE"
}

# 同一个 pane 的完整操作必须串行：一轮 poll 从账号 bracket、/usage、采样直到状态决策
# 都在锁内；人工 monitor-ensure/restart 与 poll-once 走同一把锁。内部 restart 不重复加锁，
# 因为它只能从这些已加锁入口或同一轮 poll 调用。poller 撞到人工操作时跳过这一拍，人工
# 命令则有界等待当前采样结束。
quota_monitor_op_run() {
  local policy="${1:-wait}" lock_fd rc wait_sec="$QUOTA_MONITOR_OP_WAIT_SEC"
  shift || return 2
  (( $# > 0 )) || return 2
  [[ "$wait_sec" =~ ^[0-9]+$ ]] || wait_sec=60
  mkdir -p "$(dirname "$QUOTA_MONITOR_OP_LOCK")" 2>/dev/null || return 1
  exec {lock_fd}> "$QUOTA_MONITOR_OP_LOCK" || return 1
  chmod 600 "$QUOTA_MONITOR_OP_LOCK" 2>/dev/null || true
  if [[ "$policy" == "try" ]]; then
    if ! flock -n "$lock_fd"; then
      exec {lock_fd}>&-
      quota_log "ℹ️ the monitor is being driven by a manual command; skipping this poll round"
      return 0
    fi
  elif ! flock -w "$wait_sec" "$lock_fd"; then
    exec {lock_fd}>&-
    quota_log "❌ timed out after ${wait_sec}s waiting for the monitor operation lock; UI untouched"
    return 1
  fi
  "$@"; rc=$?
  flock -u "$lock_fd" 2>/dev/null || true
  exec {lock_fd}>&-
  return "$rc"
}


# ════════════════════════════════════════════════════════════════════════
# The reading cycle / 读数主循环
# ════════════════════════════════════════════════════════════════════════
#
# 🔻 REWRITTEN DURING EXTRACTION, from `quota_poll_once` (`sentinel-quota`
#    4069–4275 @ e2f32279). Upstream that function did two jobs in one pass:
#    **collect a reading** and then **decide whether to switch**. Only the first
#    half is here. What was removed and why:
#      · `quota_reap_dead_sessions`  ← enumerates fleet worker sessions
#      · `quota_banner_sample_apply` ← reads the fleet screen-log archive
#      · `quota_estimate_fallback_switch` / `quota_decide_once` ← the switching half
#      · `pending_blocked` / `busy_sessions` ← fleet ledgers; both are constantly 0
#    The switching half lands in a later milestone. The seam is explicit at the
#    bottom of this function rather than implied, so that adding it back is one
#    edit in one place.
#
# 🔻 抽取时**重写过**，来源是 `quota_poll_once`（基线 4069–4275）。上游那个函数一趟做两件事：
#    **采一次读数**、然后**判断要不要切号**。这里只有前一半。删掉了什么、为什么：
#      · `quota_reap_dead_sessions`  ← 枚举编队 worker 会话
#      · `quota_banner_sample_apply` ← 读编队屏幕留档
#      · `quota_estimate_fallback_switch` / `quota_decide_once` ← 切号那一半
#      · `pending_blocked` / `busy_sessions` ← 编队账本，本仓恒为 0
#    切号那一半在后续里程碑落地。接缝在函数末尾**显式**写出来而不是暗示，
#    这样把它接回来只需改一处。
quota_read_once() {
  local now; now=$(date +%s)
  local fetched uuid email five week five_reset week_reset sample_email="" sample_uuid=""

  # Before any tmux/panel action: if the account was changed underneath us by
  # another writer of the shared config, `quota_monitor_refresh` must not restart the
  # monitor session onto the wrong account and silently rewrite state.account.
  # 放在任何 tmux / 面板动作之前：若账号被共享配置的另一个 writer 改掉，不能让
  # quota_monitor_refresh 把监控会话也跟着错误账号重启，进而静默改写 state.account。
  if ! quota_account_guard "read-start"; then
    quota_source_log_usage_failure "$(quota_shadow_now)" "" "" "account_guard_start"
    return 1
  fi
  sample_email="$QUOTA_GUARD_EMAIL"
  sample_uuid="$QUOTA_GUARD_UUID"

  # When the network refresh is not yet due, only process the resident panel's local
  # frame and write the raw observation log; do not push the same refresh result
  # through the ledger twice. A panel that closed unexpectedly is reopened early
  # (reopening itself triggers one network request).
  # 网络刷新尚未到期时，只处理常驻面板的本地画面并写原始观测日志；不把同一刷新结果
  # 重复送进台账。面板意外关闭才提前重开（重开本身会触发一次网络）。
  local monitor_gen monitor_launch observe_rc=0 needs_refresh=0
  monitor_gen=$(quota_state_get '.monitor_session_created' "")
  monitor_launch=$(quota_state_get '.monitor_launch_id' "")
  if quota_usage_refresh_due "$now" "$sample_email" "$sample_uuid" \
      "$monitor_gen" "$monitor_launch"; then
    needs_refresh=1
  else
    quota_monitor_observe "local_sample" || observe_rc=$?
    if (( observe_rc == 0 )); then
      return 0
    elif (( observe_rc == 2 )); then
      needs_refresh=1
    else
      local observe_error="${QUOTA_LAST_ERROR:-panel-observe-failed}"
      quota_state_merge '.poll.last_error = $e' --arg e "$observe_error" || true
      return 1
    fi
  fi

  if (( needs_refresh )) && ! quota_monitor_refresh "scheduled"; then
    local poll_error="${QUOTA_LAST_ERROR:-panel-read-failed}"
    # When the panel cannot be read, first see whether the OAuth line can stand in.
    # If it can, keep the round rather than voiding it — "another source" always
    # beats "nothing at all". Only report the original error if it cannot.
    # 面板读不到时先看 OAuth 那条线能不能顶上。顶上了就继续本轮，不再整轮作废——
    # 「另一个来源」总好过「什么都没有」。顶不上才按原样报错退出。
    if quota_oauth_fallback_apply "$now" "$(quota_state_get '.account_guard.expected_email' "")"; then
      quota_source_log_usage_failure "$(quota_shadow_now)" "$sample_email" "$sample_uuid" \
        "$(printf '%s' "$poll_error" | tr -c '[:alnum:]_.-' '_')_oauth_fallback"
      return 0
    fi
    quota_state_merge '.poll.last_ts = $t | .poll.last_error = $e' \
      --argjson t "$now" --arg e "$poll_error"
    quota_source_log_usage_failure "$(quota_shadow_now)" "$sample_email" "$sample_uuid" \
      "$(printf '%s' "$poll_error" | tr -c '[:alnum:]_.-' '_')"
    return 1
  fi
  if ! quota_account_guard "read-after-panel"; then
    quota_source_log_usage_failure "$(quota_shadow_now)" "$sample_email" "$sample_uuid" \
      "account_guard_after_panel"
    return 1
  fi
  # The network/stable sampling can take 6–20s; on success, re-read the same
  # completion clock. Otherwise the 300s tier would be counted from the start of the
  # tick, quietly deducting this round's network time, and last_success could even
  # predate last_attempt.
  # 网络/稳定采样可能占 6–20s；成功时重新取同一个完成时钟。否则 300s 档会从 tick
  # 开头算起，把本轮网络耗时偷偷扣掉，last_success 甚至会早于 last_attempt。
  now=$(date +%s)
  # A panel reading is the value **right now** — there is no staleness question — so
  # `fetched` is simply the completion moment.
  # (The first version read it from the config file instead; that follows Claude
  #  Code's own flush cadence, measured 5–9 minutes behind, which directly produced
  #  "the user can see 98% while the script still says 93%".)
  # 面板读数就是**此刻**的值，不存在陈旧问题——所以 fetched 直接记完成时刻。
  # （第一版从配置文件读，那是 cc 自己的落盘节奏，实测落后 5-9 分钟，
  #   直接导致「用户看到 98% 了脚本还停在 93%」。）
  local s_reset_line w_reset_line
  five=$(quota_panel_field "$QUOTA_PANEL_LAST" 1)
  week=$(quota_panel_field "$QUOTA_PANEL_LAST" 2)
  s_reset_line=$(quota_panel_field "$QUOTA_PANEL_LAST" 3)
  w_reset_line=$(quota_panel_field "$QUOTA_PANEL_LAST" 4)
  if [[ ! "$five" =~ ^[0-9]+$ || ! "$week" =~ ^[0-9]+$ ]]; then
    quota_log "⚠️ panel values did not parse (five=[$five] week=[$week]) -> no decision this round"
    quota_state_merge '.poll.last_ts = $t | .poll.last_error = "panel-parse-failed"' --argjson t "$now"
    quota_usage_refresh_failure "$now" "panel_parse_failed" 0 || true
    quota_source_log_usage_failure "$(quota_shadow_now)" "$sample_email" "$sample_uuid" \
      "panel_parse_failed"
    return 1
  fi
  fetched=$now
  local reset_now; reset_now=$now
  if ! five_reset=$(quota_window_reset_for_write "$five" "$s_reset_line" "$reset_now" "$QUOTA_SESSION_WINDOW_HORIZON"); then
    quota_log "⚠️ the panel's five-hour reset is outside the legal write window -> whole frame discarded, no percentages or ledger updated"
    quota_state_merge '.poll.last_ts = $t | .poll.last_error = "panel-invalid-five-reset"' --argjson t "$now"
    quota_usage_refresh_failure "$now" "invalid_five_reset" 0 || true
    quota_source_log_usage_failure "$(quota_shadow_now)" "$sample_email" "$sample_uuid" \
      "panel_invalid_five_reset"
    return 1
  fi
  if ! week_reset=$(quota_window_reset_for_write "$week" "$w_reset_line" "$reset_now" "$QUOTA_WEEK_WINDOW_HORIZON"); then
    quota_log "⚠️ the panel's weekly reset is outside the legal write window -> whole frame discarded, no percentages or ledger updated"
    quota_state_merge '.poll.last_ts = $t | .poll.last_error = "panel-invalid-week-reset"' --argjson t "$now"
    quota_usage_refresh_failure "$now" "invalid_week_reset" 0 || true
    quota_source_log_usage_failure "$(quota_shadow_now)" "$sample_email" "$sample_uuid" \
      "panel_invalid_week_reset"
    return 1
  fi
  # Consume **the same snapshot** the guard above used. Reading again after the guard
  # would, if an overwrite lands exactly between the two reads, attribute account A's
  # panel numbers to an internally consistent but wrong identity B.
  # 直接消费上面 guard 的**同一快照**。若 guard 后另读，覆盖恰落在两次读取之间时，
  # 会把 A-panel 的数写给一个内部自洽但错误的 B 身份。
  email="$QUOTA_GUARD_EMAIL"
  uuid="$QUOTA_GUARD_UUID"
  if [[ -z "$email" || -z "$uuid" ]]; then
    quota_log "❌ account identity is unattributable after the panel read -> discarding this round's values"
    quota_state_merge '.poll.last_ts = $t | .poll.last_error = "identity-after-panel"' --argjson t "$now"
    quota_usage_refresh_failure "$now" "identity_after_panel" 0 || true
    quota_source_log_usage_failure "$(quota_shadow_now)" "$sample_email" "$sample_uuid" \
      "identity_after_panel"
    return 1
  fi

  local refresh_seq refresh_interval refresh_next decided_seq monitor_generation monitor_launch_id
  refresh_seq="${QUOTA_REFRESH_SEQ:-0}"
  [[ "$refresh_seq" =~ ^[0-9]+$ ]] || refresh_seq=0
  decided_seq=$(quota_state_get '.usage_refresh.decided_seq' -1)
  if (( refresh_seq > 0 )) && [[ "$decided_seq" == "$refresh_seq" ]]; then
    quota_log "ℹ️ /usage refresh_seq=$refresh_seq has already been through the ledger; a repeated frame only leaves an observation record"
    return 0
  fi
  # ⚠️ The old values must be read **before** the new reading is merged into state,
  #    or `prev` is `cur` and the rate is identically zero.
  # ⚠️ 必须在把新读数合并进 state **之前**取旧值，否则 prev 就是 cur，流速恒为 0。
  local prev_five prev_week prev_ts prev_email
  prev_five=$(quota_state_get '.five_hour' "")
  prev_week=$(quota_state_get '.seven_day' "")
  prev_ts=$(quota_state_get '.fetched_ts' "")
  prev_email=$(quota_state_get '.account' "")

  # Measured burn rate (%/second, floating point). Updated only when the account is
  # unchanged, time moved forward, and the percentage went up; a drop caused by a
  # cross-account change or a window reset is not a burn rate. If it cannot be
  # computed, keep the previous value — an old speed beats an invented one.
  # 实测烧速（%/秒，浮点）。只在同账号、时间前进、百分比上涨时更新；跨账号或窗口重置
  # 导致的下降不是烧速。拿不到就沿用上一次的值（宁可旧速度，也不要凭空造一个）。
  local burn_five burn_week burn_dt
  if [[ "$QUOTA_ESTIMATE" == "1" && "$prev_email" == "$email" \
     && "$prev_five" =~ ^[0-9]+$ && "$prev_week" =~ ^[0-9]+$ && "$prev_ts" =~ ^[0-9]+$ ]]; then
    burn_dt=$(( now - prev_ts ))
    if (( burn_dt > 0 && burn_dt <= 3600 )); then
      burn_five=$(awk -v a="$five" -v b="$prev_five" -v d="$burn_dt" 'BEGIN{r=(a-b)/d; print (r>0)?r:0}')
      burn_week=$(awk -v a="$week" -v b="$prev_week" -v d="$burn_dt" 'BEGIN{r=(a-b)/d; print (r>0)?r:0}')
      quota_state_merge '.burn_rate_five = $bf | .burn_rate_week = $bw | .burn_rate_ts = $t' \
        --argjson bf "$burn_five" --argjson bw "$burn_week" --argjson t "$now" || true
    fi
  fi
  # The two fleet-sourced inputs are constantly 0 here; see the note on
  # quota_usage_interval_adaptive for what that costs.
  # 两个编队来源的输入在本仓恒为 0；代价见 quota_usage_interval_adaptive 的注释。
  refresh_interval=$(quota_usage_interval_adaptive "$five" "$week" \
      "$prev_five" "$prev_week" "$prev_ts" "$now" "$prev_email" "$email" 0 0)
  refresh_next=$(( now + refresh_interval ))
  monitor_generation=$(quota_state_get '.monitor_session_created' 0)
  [[ "$monitor_generation" =~ ^[0-9]+$ ]] || monitor_generation=0
  monitor_launch_id=$(quota_state_get '.monitor_launch_id' "")

  # The fresh value, the network success cadence and decided_seq go in **one** atomic
  # merge: one server-side refresh is acted on at most once.
  # 新鲜值、网络成功节奏与 decided_seq 同一次 atomic merge：同一个服务端刷新最多决策一次。
  if ! QS_JQ_E="$email" quota_state_merge '
      .account = $ENV.QS_JQ_E | .uuid = $u | .fetched_ts = $f
      | .five_hour = $five | .seven_day = $week
      | .five_reset_ts = $fr | .week_reset_ts = $wr
      | .poll.last_ts = $t | .poll.last_error = null
      | .accounts[$ENV.QS_JQ_E] = {five: $five, week: $week, five_reset: $fr, week_reset: $wr, checked_ts: $t, source: "usage_panel"}
      | .reading_source = "usage_panel" | .reading_source_ts = $f
      | .usage_refresh = ((.usage_refresh // {}) + {
          account:$ENV.QS_JQ_E, uuid:$u, monitor_generation:$generation,
          monitor_launch_id:$launch,
          refresh_seq:$seq, decided_seq:$seq, last_success_ts:$t,
          last_outcome:"ok", interval_seconds:$interval,
          next_due_ts:$next, backoff_seconds:null
        })' \
    --arg u "$uuid" --argjson f "$fetched" \
    --argjson five "$five" --argjson week "$week" \
    --argjson fr "$five_reset" --argjson wr "$week_reset" \
    --argjson t "$now" --argjson seq "$refresh_seq" \
    --argjson generation "$monitor_generation" --arg launch "$monitor_launch_id" \
    --argjson interval "$refresh_interval" \
    --argjson next "$refresh_next"; then
    quota_log "❌ this round's panel reading could not be persisted -> it will not be used for any decision"
    quota_source_log_usage_failure "$(quota_shadow_now)" "$email" "$uuid" "state_write_failed"
    return 1
  fi

  # Every frame from the primary source also enters the unified per-sample ledger, so
  # it can be compared account-by-account and neighbour-by-neighbour against the two
  # shadow sources by observed_at. A failure to record must not block the primary
  # state that has already been persisted.
  # 主来源每一帧也进入统一逐次账，才能按 observed_at 与两条影子来源做同账号近邻比较。
  # 记录失败不反向阻塞已经持久化的主决策状态。
  quota_source_log_usage "$(quota_shadow_now)" "$email" "$uuid" "$five" "$five_reset" "$week" "$week_reset" || true

  quota_ratio_update "$now" "$email" "$five" "$week"
  quota_capacity_update "$now"

  quota_log "reading $email five=${five}% week=${week}% (fetched $(date -d "@$fetched" '+%H:%M:%S'); next tier ${refresh_interval}s)"

  # ── Seam for the switching half / 切号那一半的接缝 ────────────────────
  # A reading that was just taken is judged on the same beat, rather than waiting for
  # the next one. `quota_decide_once` is supplied by lib/switch.sh; the guard stays
  # because the reading half must remain usable on its own — with lib/switch.sh not
  # sourced, this file still reads and records and simply never decides.
  # ⚠️ This comment used to say the switching half "is not in this milestone", and it
  #    kept saying so after the milestone that added it, sitting directly above the line
  #    that now calls it. A stale comment on a seam is worse than none: the seam is
  #    exactly where someone looks to find out whether a thing is wired up.
  # 刚采到的读数在同一拍内就被判到,不必等下一拍。`quota_decide_once` 由 lib/switch.sh 提供;
  # 这道 guard 保留,是因为读数那一半必须能独立可用——不 source lib/switch.sh 时,
  # 本文件照常读数与记录,只是从不做判定。
  # ⚠️ 这段注释原本写着切号那一半「不在本里程碑内」,而在补上它的那个里程碑之后仍这么写,
  #    就贴在**现在会调用它**的那行上面。接缝上的过期注释比没有注释更糟:
  #    接缝正是别人用来判断「这东西到底接没接上」的地方。
  if declare -F quota_decide_once >/dev/null 2>&1; then
    quota_decide_once "$now"
  fi
}
