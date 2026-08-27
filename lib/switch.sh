# lib/switch.sh — the switching half: decide, act, and keep the ledger.
# 切号那一半：判定、执行、记账。
#
# lib/state.sh ends quota_read_once with an explicit seam that calls quota_decide_once
# if it exists. Defining it here is what closes that seam; nothing else has to change.
# lib/state.sh 的 quota_read_once 末尾留了显式接缝，存在 quota_decide_once 就调用它。
# 本文件定义它即接上，别处无需改动。
#
# 🔴 Reading order for anyone changing this file: the ledger is not decoration. Every
#    switch this tool performs rewrites the credentials of a live login, and the only
#    way anyone later reconstructs "why is this machine on that account" is the ledger.
#    A switch that happens without a ledger line is indistinguishable from a switch
#    somebody did by hand, which is exactly the state the account guard cannot resolve.
# 🔴 改本文件前先读这段:流水账不是装饰。本工具每切一次都会改写一个在用登录的凭据,
#    而后来的人要复原「这台机器为什么在那个账号上」只有流水账这一条路。**没有留痕的
#    切号与人手切号无法区分**,而那恰好是身份守卫解不开的那个状态。

# quota_switch_ledger_ensure — the ledger's directory must exist before the first append.
quota_switch_ledger_ensure() {
  local dir; dir=$(dirname "$QUOTA_SWITCH_LEDGER")
  [[ -d "$dir" ]] || mkdir -p "$dir" 2>/dev/null || return 1
  return 0
}

# quota_account_switch_record <ts> <from> <to> <kind> <note>
#
# One JSON object per line, appended, never rewritten. kind is one of:
#   auto     this tool decided and acted
#   manual   a human asked for it through this tool
#   external something outside this tool changed the account; the guard noticed
#
# ⚠️ `external` is recorded but NOT acted on. The guard has already failed closed by
#    the time this is called; writing the line is how the operator finds out. Recording
#    it must never look like endorsing it.
# ⚠️ Append is best-effort and must never fail the caller: the switch (or the guard
#    that detected one) has already happened. Losing a ledger line is bad; unwinding a
#    completed credential change because a log write failed is worse.
quota_account_switch_record() {
  local ts="$1" from="$2" to="$3" kind="$4" note="${5:-}"
  quota_switch_ledger_ensure || { quota_log "⚠️ switch ledger directory unavailable: $QUOTA_SWITCH_LEDGER"; return 0; }
  local line
  line=$(jq -cn \
    --argjson ts "$ts" --arg from "$from" --arg to "$to" \
    --arg kind "$kind" --arg note "$note" --arg mode "$QUOTA_SWITCH_MODE" \
    '{ts:$ts, iso:($ts|todate), from:$from, to:$to, kind:$kind, mode:$mode, note:$note}' \
    2>/dev/null) || return 0
  printf '%s\n' "$line" >> "$QUOTA_SWITCH_LEDGER" 2>/dev/null || \
    quota_log "⚠️ could not append to the switch ledger: $QUOTA_SWITCH_LEDGER"
  return 0
}

# quota_switch_ranked_candidates — in-service accounts, best first, as "email<TAB>five<TAB>week".
#
# Ranked by WEEKLY usage first, five-hour second. That order is deliberate and is the
# one thing here worth arguing about:
#   * the weekly window does not come back within any useful horizon. Spending it is
#     the irreversible move, so the account with the most weekly headroom wins.
#   * the five-hour window refills on its own, so it is the tiebreak, not the key.
# ⚠️ And a 0% account is NOT automatically the best one: the five-hour window starts
#    at that account's first real message, not when you switch to it. A freshly
#    selected 0% account therefore does not hand you a full window on arrival -- it
#    hands you one that starts whenever traffic starts. Ranking on weekly headroom
#    sidesteps that trap; ranking on the five-hour number would walk straight into it.
quota_switch_ranked_candidates() {
  local snap; snap=$(quota_state_read 2>/dev/null || echo '{}')
  printf '%s' "$snap" | jq -r --argjson skip "$(quota_out_of_service_json)" '
      (.accounts // {})
      | to_entries
      | map(select(.value.week != null and .value.five != null))
      | map(select((.key as $k | $skip | index($k)) | not))
      | sort_by(.value.week, .value.five)
      | .[] | "\(.key)\t\(.value.five)\t\(.value.week)"' 2>/dev/null
}

# quota_switch_pick <current-email> — best candidate that is not the current account
# and is under both switch lines. Empty output means "nothing to switch to".
quota_switch_pick() {
  local current="$1" email five week
  while IFS=$'\t' read -r email five week; do
    [[ -z "$email" ]] && continue
    [[ "$email" == "$current" ]] && continue
    # A candidate must be under BOTH lines. Being under only one is how you switch into
    # an account that is about to trip the other line and switch straight back out.
    (( $(printf '%.0f' "$five") >= QUOTA_SWITCH_PCT_FIVE )) && continue
    (( $(printf '%.0f' "$week") >= QUOTA_SWITCH_PCT_WEEK )) && continue
    printf '%s\n' "$email"
    return 0
  done < <(quota_switch_ranked_candidates)
  return 1
}

# quota_switch_perform <to-email> — hand the actual credential move to account-switch.
#
# ⚠️ The address is passed as a selector on argv; the TOKEN never is, and never can be
#    from here -- this function does not read credentials at all. account-switch reads
#    and writes them itself, in its own process. Keeping the two apart is the reason
#    `ps` cannot show a token during a switch.
quota_switch_perform() {
  local to="$1" out rc
  [[ -x "$QUOTA_ACCOUNT_SWITCH_BIN" ]] || {
    quota_log "❌ account-switch not executable at $QUOTA_ACCOUNT_SWITCH_BIN"; return 1; }
  out=$("$QUOTA_ACCOUNT_SWITCH_BIN" --use "$to" --yes 2>&1); rc=$?
  if (( rc != 0 )); then
    quota_log "❌ switch to ${to} failed (rc=${rc}): $(printf '%s' "$out" | tail -1)"
    return 1
  fi
  return 0
}

# quota_decide_once <now> — the seam lib/state.sh calls after every applied reading.
quota_decide_once() {
  local now="$1"
  [[ "$QUOTA_SWITCH_MODE" == "off" ]] && return 0

  local snap current five week
  snap=$(quota_state_read 2>/dev/null || echo '{}')
  current=$(printf '%s' "$snap" | jq -r '.account // ""' 2>/dev/null)
  [[ -z "$current" ]] && return 0
  five=$(printf '%s' "$snap" | jq -r --arg a "$current" '(.accounts[$a].five // empty)' 2>/dev/null)
  week=$(printf '%s' "$snap" | jq -r --arg a "$current" '(.accounts[$a].week // empty)' 2>/dev/null)
  [[ -z "$five" || -z "$week" ]] && return 0

  local reason=""
  (( $(printf '%.0f' "$five") >= QUOTA_SWITCH_PCT_FIVE )) && reason="five_hour ${five}% >= ${QUOTA_SWITCH_PCT_FIVE}%"
  (( $(printf '%.0f' "$week") >= QUOTA_SWITCH_PCT_WEEK )) && reason="weekly ${week}% >= ${QUOTA_SWITCH_PCT_WEEK}%"
  [[ -z "$reason" ]] && return 0

  local target
  if ! target=$(quota_switch_pick "$current"); then
    # Every in-service account is at or over a line. Say so once and plainly: this is
    # the state operators most need named, and "nothing happened" is how it otherwise
    # presents. Nothing is switched -- there is nowhere better to go.
    quota_log "🛑 ${reason}, but every in-service account is at or over a line -> staying on ${current}"
    quota_account_switch_record "$now" "$current" "" "blocked" "$reason; no in-service account below both lines"
    return 0
  fi

  if [[ "$QUOTA_SWITCH_MODE" != "on" ]]; then
    quota_log "🔎 dry-run: ${reason} -> would switch ${current} -> ${target} (set QUOTA_SWITCH_MODE=on to act)"
    quota_account_switch_record "$now" "$current" "$target" "dry-run" "$reason"
    return 0
  fi

  quota_log "🔀 ${reason} -> switching ${current} -> ${target}"
  if quota_switch_perform "$target"; then
    quota_account_switch_record "$now" "$current" "$target" "auto" "$reason"
    quota_state_merge '.last_switch_ts = $t | .account_guard.last_switch_recorded = $a' \
      --argjson t "$now" --arg a "$target" || true
    quota_log "✅ switched ${current} -> ${target}"
  else
    # A failed switch is still a ledger event. The credentials were restored by
    # account-switch's own recovery path, but an operator reading the ledger has to be
    # able to see that an attempt was made and did not take.
    quota_account_switch_record "$now" "$current" "$target" "failed" "$reason"
  fi
  return 0
}

# quota_cmd_switches [--json] [N] — read the ledger back out.
quota_cmd_switches() {
  local as_json=0 limit=20
  while (( $# )); do
    case "$1" in
      --json) as_json=1 ;;
      *[0-9]*) limit="$1" ;;
    esac
    shift
  done
  if [[ ! -f "$QUOTA_SWITCH_LEDGER" ]]; then
    echo "no switch ledger yet at $QUOTA_SWITCH_LEDGER" >&2
    return 1
  fi
  if (( as_json )); then
    tail -n "$limit" "$QUOTA_SWITCH_LEDGER"
    return 0
  fi
  # ⚠️ The stored `iso` is UTC, because jq's todate is always UTC. It is printed WITH
  #    its Z. Trimming the Z to make the column narrower turns a UTC timestamp into
  #    something that reads as local time, which is the same silent-offset mistake this
  #    repo documents for `TZ=<name> date` -- and a ledger is read precisely when
  #    somebody is trying to line up "when did it switch" against another log.
  printf '%-21s %-9s %-8s %s\n' 'WHEN (UTC)' 'KIND' 'MODE' 'FROM -> TO'
  tail -n "$limit" "$QUOTA_SWITCH_LEDGER" | jq -r '
    "\(.iso // "-")\t\(.kind // "-")\t\(.mode // "-")\t\(.from // "?") -> \((.to | select(. != null and . != "")) // "(stayed put)")\t\(.note // "")"' \
    2>/dev/null | while IFS=$'\t' read -r iso kind mode move note; do
      printf '%-21s %-9s %-8s %s\n' "$iso" "$kind" "$mode" "$move"
      [[ -n "$note" ]] && printf '%-40s%s\n' '' "$note"
    done
  return 0
}
