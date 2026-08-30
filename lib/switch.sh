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
  line=$(QS_JQ_FROM="$from" QS_JQ_TO="$to" jq -cn \
    --argjson ts "$ts" \
    --arg kind "$kind" --arg note "$note" --arg mode "$QUOTA_SWITCH_MODE" \
    '{ts:$ts, iso:($ts|todate), from:$ENV.QS_JQ_FROM, to:$ENV.QS_JQ_TO, kind:$kind, mode:$mode, note:$note}' \
    2>/dev/null) || {
    # Losing the line is survivable; losing it SILENTLY is not. The append-failure path
    # below logs, and this one did not -- so a jq failure produced a decision that left
    # no trace in the ledger and none in the log either, which contradicts the rule at
    # the top of this file. Still returns 0: bookkeeping must not unwind a completed
    # switch.
    # 丢一行还能活;**静默**丢一行不行。下面那条追加失败路径会记日志,而这条不会——
    # 于是一次 jq 失败会让某个决定在账本和日志里都不留痕,与本文件开篇的规则冲突。
    # 仍然 return 0:记账失败不该反向撤销一次已完成的切换。
    quota_log "⚠️ could not build the switch ledger entry (jq failed); this decision is unrecorded: ${from:-?} -> ${to:-(stayed put)} [$kind]"
    return 0
  }
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
# 🔴 The selector goes in on STDIN (`--use -`), not on argv.
#    It used to be `--use "$to"`, which put the account address on the command line of
#    every automatic switch, readable by any process on the host via `pgrep -af` for as
#    long as the switch ran. On the manual path that is the operator's own choice; here
#    nobody chose -- the sentinel switches on its own schedule.
#    ⚠️ The TOKEN was never here and never can be: this function does not read
#    credentials at all, account-switch reads and writes them inside its own process.
#    That separation is why `ps` cannot show a token during a switch, and it is
#    unaffected by this change. What changed is the ADDRESS.
# 🔴 选择器走 **stdin**(`--use -`),不走 argv。
#    原来是 `--use "$to"`,于是每一次自动切号都把账号地址放上命令行,切号期间宿主上任何
#    进程都能用 `pgrep -af` 读到。人工路径上那是操作者自己的选择;这里没有人做选择。
#    ⚠️ token 从来不在这里、也不可能在:本函数根本不读凭据。改的是**地址**。
#
# 🔴 An exit code of 0 is not evidence that the account changed, and the identity fence
#    has to move with it. Both halves are load-bearing:
#    ① Read the identity back. A restored backup, or another writer of the shared
#      config landing between the write and now, both produce "the tool succeeded and
#      the account is still the old one". Claiming that as a switch moves the fence
#      onto an account nobody is actually on.
#    ② Move `account_guard.expected_*` to the new account. This looks like bookkeeping
#      and is not: the guard treats `expected` as a persistent expectation and re-reads
#      it at every decision boundary. A switch that succeeds while `expected` stays on
#      the old account makes the very next guard call see actual != expected, report
#      `account-drift`, fail closed — **and never recover**, because nothing else ever
#      updates `expected`. It also writes an `external` ledger line, blaming an outside
#      writer for something this tool did. That is the shape of the three-hour outage
#      on 2026-08-12: the switch itself worked; what broke was every reading after it.
#    ③ If the fence cannot be persisted, do NOT claim success. A claimed switch with an
#      unmoved fence is exactly case ②.
#    ⚠️ REMAINING WINDOW — `return 1` closes the CLAIM, not the STATE. By the time
#      `account-switch` has returned 0 the credentials are already changed and that is
#      not undoable. If this process dies between the successful read-back and the fence
#      write, reality is: account = new, `expected_*` = old, and the ledger has no line at
#      all (the record is written by the caller, after this function returns). The next
#      round then takes the account-drift branch and fails closed permanently, exactly as
#      described above. This is still a strict improvement — before, EVERY successful
#      switch ended that way; now only a crash inside a narrow window does — but it is not
#      closed. Closing it needs an intent record written BEFORE the switch, which the
#      guard consults before declaring drift. That is a later milestone, not a TODO to be
#      quietly forgotten: it is written here because the sentence "we do not claim
#      success" reads like the hole is gone, and it is not.
#    ⚠️ 剩余窗口 —— `return 1` 关的是**声称**，不是**状态**。`account-switch` 返回 0 那一刻
#      凭据已经换了、不可撤回。若进程在「回读成功」与「fence 落盘」之间死掉，现实是：
#      账号=新、`expected_*`=旧、流水账**一行都没有**（记账在调用方、在本函数返回之后）。
#      下一拍照样走 account-drift 分支、永久 fail closed，与上面描述的一模一样。
#      这仍是严格改进——改之前是**每一次**成功切号都那样，现在只有崩在这个窄窗口里才那样
#      ——但它**没有被关上**。真正收口需要在切号**之前**先落一条 intent，让守卫在判定漂移前
#      先看它。那是后续里程碑的事；写在这里而不是悄悄留成 TODO，是因为
#      「我们不宣称成功」这句话读起来像洞已经没了，而它还在。
# 🔴 退出码 0 不是「账号真的换了」的证据，而且身份 fence 必须跟着挪。两半都承重：
#    ① 回读身份。备份恢复、或共享配置的另一个 writer 恰好落在写入与此刻之间，都会造出
#      「工具成功了、账号还是旧的」。把它当成切号成功，会把 fence 挪到一个根本没人在的账号上。
#    ② 把 account_guard.expected_* 挪到新账号。这看着像记账，其实不是：守卫把 expected
#      当持久期望值，每个决策边界都重读。切号成功而 expected 停在旧账号 ⇒ 下一次守卫就
#      看到 actual≠expected，判 account-drift、fail closed，**而且再也不会自己好**，
#      因为没有别的东西会更新 expected；它还会往流水账写一条 external，把本工具自己干的
#      事记到一个外部 writer 头上。那正是 2026-08-12 停摆三小时的形状：切号本身成功了，
#      坏掉的是它之后的每一次读数。
#    ③ fence 落不了盘就**不要**宣称成功——宣称了就等于②。
quota_switch_perform() {
  local to="$1" now="${2:-$(date +%s)}" out rc
  local before_raw="" before_email="" before_uuid="" before_usage=""
  local after_raw="" now_email="" now_uuid="" now_usage=""
  [[ -x "$QUOTA_ACCOUNT_SWITCH_BIN" ]] || {
    quota_log "❌ account-switch not executable at $QUOTA_ACCOUNT_SWITCH_BIN"; return 1; }
  before_raw=$(quota_identity_read 2>/dev/null || true)
  [[ -n "$before_raw" ]] && IFS=$'\037' read -r before_email before_uuid before_usage <<< "$before_raw"
  out=$(printf '%s\n' "$to" | "$QUOTA_ACCOUNT_SWITCH_BIN" --use - --yes 2>&1); rc=$?
  if (( rc != 0 )); then
    quota_log "❌ switch to ${to} failed (rc=${rc}): $(printf '%s' "$out" | tail -1)"
    return 1
  fi

  after_raw=$(quota_identity_read 2>/dev/null || true)
  [[ -n "$after_raw" ]] && IFS=$'\037' read -r now_email now_uuid now_usage <<< "$after_raw"
  if [[ "$now_email" != "$to" || -z "$now_uuid" ]]; then
    quota_log "❌ identity after the switch is incomplete or wrong: now [${now_email:-unreadable}], expected [$to] -> failing closed"
    return 1
  fi
  # ⚠️ The usage cache is deliberately NOT part of this check. It only refreshes when
  #    the panel runs, so right after a switch it is normally empty or still on the old
  #    account. Treating it as identity is what deadlocked upstream for three hours:
  #    the guard wanted it consistent, it needed a panel read to refresh, and the panel
  #    read needed the guard to pass.
  # ⚠️ usage 缓存**刻意**不参与这条校验：它只在面板跑过之后才刷新，所以切号刚完成时为空
  #    或还停在旧账号是正常的。把它当身份正是上游死锁三小时的原因。
  if [[ -n "$now_usage" && "$now_uuid" != "$now_usage" ]]; then
    quota_log "ℹ️ the usage cache still belongs to the previous account (normal lag); panel attribution is checked separately"
  fi
  if [[ -n "$before_email" && "$before_email" != "$to" \
     && -n "$before_uuid" && "$before_uuid" == "$now_uuid" ]]; then
    quota_log "❌ the config now claims ${to} but the account UUID did not change -> identity is not trustworthy"
    return 1
  fi

  if ! QS_JQ_E="$to" quota_state_merge '
      .account_guard.expected_email = $ENV.QS_JQ_E
      | .account_guard.expected_uuid = $u
      | .account_guard.established_ts = $t
      | .account_guard.last_ok_ts = $t
      | .last_switch_ts = $t' \
      --arg u "$now_uuid" --argjson t "$now"; then
    quota_log "❌ the new identity was read back, but the guard fence could not be persisted -> not claiming success"
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
  five=$(printf '%s' "$snap" | QS_JQ_A="$current" jq -r '(.accounts[$ENV.QS_JQ_A].five // empty)' 2>/dev/null)
  week=$(printf '%s' "$snap" | QS_JQ_A="$current" jq -r '(.accounts[$ENV.QS_JQ_A].week // empty)' 2>/dev/null)
  [[ -z "$five" || -z "$week" ]] && return 0

  # ── Fail closed on a stale ledger / 台账陈旧则不判 ──────────────────────
  # This function is a seam: today it is called right after a fresh reading, but it is
  # a public entry point and nothing stops a caller from invoking it on a beat where
  # no new reading arrived. Deciding from a frozen ledger is not a smaller version of
  # deciding — it is confidently acting on a number that stopped being true, and the
  # act it authorises rewrites live credentials.
  # ⚠️ Say so **once per stale reading**, not once per call: the whole point of the
  #    branch is that it can persist, and a line per beat would reproduce the flood it
  #    is meant to avoid. But do say it — a silent return is indistinguishable from
  #    "judged, nothing to do", and those two need opposite responses from an operator.
  # 本函数是接缝：今天它在刚采到读数之后被调用，但它是公开入口，没有任何东西阻止调用方
  # 在「本拍没有新读数」时调它。拿僵住的台账做判定，不是「弱一点的判定」——那是**自信地**
  # 按一个已经不成立的数字动作，而它授权的动作会改写在用的凭据。
  # ⚠️ **每份陈旧读数只说一次**，不是每次调用说一次：这个分支的要害正是它会持续存在。
  #    但必须说——静默返回与「判过了、没事」长得一模一样，而这两者要求操作者做相反的事。
  local fetched age
  fetched=$(printf '%s' "$snap" | jq -r '(.fetched_ts // empty)' 2>/dev/null)
  if [[ "$fetched" =~ ^[0-9]+$ ]]; then
    age=$(( now - fetched ))
    if (( age < 0 || age > QUOTA_FETCH_MAX_AGE )); then
      if [[ "$(quota_state_get '.decide_stale_logged' "")" != "$fetched" ]]; then
        quota_log "⏹ the ledger reading is ${age}s old (limit ${QUOTA_FETCH_MAX_AGE}s) -> no decision this round, waiting for a fresh one"
        quota_state_merge '.decide_stale_logged = $f' --arg f "$fetched" || true
      fi
      return 0
    fi
    [[ -n "$(quota_state_get '.decide_stale_logged' "")" ]] \
      && quota_state_merge '.decide_stale_logged = null' || true
  fi

  # Accumulate, do not assign: when both lines are crossed the ledger has to say so.
  # These two were plain assignments, so the weekly line silently overwrote the
  # five-hour one and the ledger recorded a single cause for a double exhaustion --
  # the reader then reasonably concludes the five-hour window was fine.
  # 累加而不是赋值:两条线同时超时,账本必须两条都写。原来是两次直接赋值,周额度那句
  # 会把五小时那句悄悄盖掉,双重耗尽在账本里只剩一个原因,读的人会据此以为五小时没事。
  local reason=""
  (( $(printf '%.0f' "$five") >= QUOTA_SWITCH_PCT_FIVE )) && reason="${reason:+$reason; }five_hour ${five}% >= ${QUOTA_SWITCH_PCT_FIVE}%"
  (( $(printf '%.0f' "$week") >= QUOTA_SWITCH_PCT_WEEK )) && reason="${reason:+$reason; }weekly ${week}% >= ${QUOTA_SWITCH_PCT_WEEK}%"
  [[ -z "$reason" ]] && return 0

  local target
  if ! target=$(quota_switch_pick "$current"); then
    # Every in-service account is at or over a line. Say so plainly: this is the state
    # operators most need named, and "nothing happened" is how it otherwise presents.
    # Nothing is switched -- there is nowhere better to go.
    #
    # ⚠️ Say it at most once per QUOTA_SWITCH_MIN_INTERVAL. This branch is not an
    #    exception, it is a **condition**: once the roster has no account below both
    #    lines it stays that way for hours, and every decision beat lands here. Saying
    #    it every beat floods the log AND appends a ledger line per beat, which buries
    #    the one record an operator later reads to reconstruct what happened.
    #    ⚠️ The first attempt is never delayed, and after the window it speaks again:
    #    the gate suppresses **repetition**, never the first report and never recovery.
    #    A gate that stops reporting for good is a much worse failure than a loud one.
    # ⚠️ 每 QUOTA_SWITCH_MIN_INTERVAL 最多说一次。这个分支不是异常而是一种**状态**：
    #    一旦名册里没有账号同时低于两条线，它会持续数小时，而每一拍判定都落在这里。
    #    每拍都说会同时刷爆日志**和**每拍往流水账追加一条，把操作者事后唯一会去读的那条
    #    记录埋掉。⚠️ 首次尝试永不延迟，窗口过后会重新出声：闸压的是**重复**，
    #    从不压首次报告、也从不压恢复。一道从此不再报告的闸，比一道吵闹的闸糟得多。
    local blocked_ts; blocked_ts=$(quota_state_get '.switch_blocked_ts' "")
    if [[ "$blocked_ts" =~ ^[0-9]+$ ]] && (( now - blocked_ts < QUOTA_SWITCH_MIN_INTERVAL )); then
      return 0
    fi
    quota_log "🛑 ${reason}, but every in-service account is at or over a line -> staying on ${current}"
    quota_account_switch_record "$now" "$current" "" "blocked" "$reason; no in-service account below both lines"
    quota_state_merge '.switch_blocked_ts = $t' --argjson t "$now" || true
    return 0
  fi
  # A candidate was found, so the "nowhere to go" condition is over. Clear the stamp,
  # or the next time it recurs the first report would be suppressed by a window that
  # started during a completely different episode.
  # 找到候选说明「无处可切」这个状态已经结束。清掉时间戳，否则下次它再出现时,
  # 首次报告会被一个属于另一段经历的窗口压住。
  [[ -n "$(quota_state_get '.switch_blocked_ts' "")" ]] \
    && quota_state_merge '.switch_blocked_ts = null' || true

  if [[ "$QUOTA_SWITCH_MODE" != "on" ]]; then
    quota_log "🔎 dry-run: ${reason} -> would switch ${current} -> ${target} (set QUOTA_SWITCH_MODE=on to act)"
    quota_account_switch_record "$now" "$current" "$target" "dry-run" "$reason"
    return 0
  fi

  quota_log "🔀 ${reason} -> switching ${current} -> ${target}"
  if quota_switch_perform "$target" "$now"; then
    quota_account_switch_record "$now" "$current" "$target" "auto" "$reason"
    QS_JQ_A="$target" quota_state_merge \
      '.last_switch_ts = $t | .account_guard.last_switch_recorded = $ENV.QS_JQ_A' \
      --argjson t "$now" || true
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
