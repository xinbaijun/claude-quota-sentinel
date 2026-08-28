# shellcheck shell=bash
# lib/monitor.sh — the monitor session and panel reading / 监控会话与面板读数
#
# Provenance: `sentinel-quota` @ e2f32279, section "二、监控会话" (lines 1360–2333).
# Two functions from that section did not come across: `quota_banner_pressure`
# (reads a fleet-wide screen-log archive) is dropped entirely, and
# `quota_usage_interval_adaptive` is rewritten — see the note on it below.
# Per-function baseline line ranges are in docs/PROVENANCE.md.
# 抽取来源：基线 e2f32279 的「二、监控会话」（1360–2333 行）。该节有两个函数没有原样过来：
# `quota_banner_pressure`（读全编队屏幕留档）整条不搬；`quota_usage_interval_adaptive`
# 被重写，理由写在它自己的注释里。逐函数行号见 docs/PROVENANCE.md。
#
# ════════════════════════════════════════════════════════════════════════
# The monitor session — one dedicated Claude Code session that only ever sends
# `/usage` and never talks to the model.
# 二、监控会话（专用 cc 会话，只发 /usage，从不与模型对话）
# ════════════════════════════════════════════════════════════════════════

# 🔻 CORRECTED (pipefail + SIGPIPE) — five functions in this file differ from the
#    baseline text: every `printf … | grep -q` was rewritten as a here-string. The
#    intended behaviour is unchanged; the baseline shape is defective. Under
#    `set -o pipefail`, `grep -q` exits on its first match, the producer dies of
#    SIGPIPE, and the pipeline reports 141 **even though the pattern matched** — so the
#    caller reads "no match". Measured at 7.6% on the equivalent detector.
#    Affected: quota_monitor_ready, quota_monitor_wait_ready,
#    quota_monitor_exit_to_shell, quota_panel_frame_status, quota_monitor_open_usage.
#    Full reasoning and the measurement: docs/PROVENANCE.md "Corrected against the
#    baseline". Each of the five carries a one-line marker at its definition.
# 🔻 已订正（pipefail + SIGPIPE）——本文件有五个函数与基线文本不同：所有
#    `printf … | grep -q` 都改成了 here-string。意图行为未变，是基线那个写法本身有缺陷：
#    `set -o pipefail` 下 grep -q 一命中就退出，上游被 SIGPIPE 打死，**整条管道回报 141,
#    尽管命中了** ⇒ 调用方读到「没匹配」。等价判据上实测 7.6%。理由与实测见
#    docs/PROVENANCE.md「相对基线做了订正」。五个函数各自的定义处都有一行标记。
quota_monitor_alive() { tmux has-session -t "$QUOTA_MONITOR_SESSION" 2>/dev/null; }

# 专用 monitor 的 session 名一直被当作 pane target 使用，因此它必须维持单 pane。
# 一旦有人加 window/pane，session target 会随 active pane 漂移；此时宁可停读也不把
# `/exit`、新 cc 和 /usage 分发到不同 pane。
quota_monitor_single_pane_id() {
  local panes
  panes=$(tmux list-panes -s -t "$QUOTA_MONITOR_SESSION" -F '#{pane_id}' 2>/dev/null) || return 1
  [[ "$panes" =~ ^%[0-9]+$ ]] || return 1
  printf '%s\n' "$panes"
}

# tmux session 在原 pane 内换 cc 时不会换 session_created，因此再钉一个 cc 启动代际。
# 它同时写到 tmux user option（live proof）和 quota-state（owner proof）；两边不同即拒帧。
quota_monitor_live_launch_id() {
  local launch_id
  launch_id=$(tmux display-message -p -t "$QUOTA_MONITOR_SESSION" \
    "#{${QUOTA_MONITOR_LAUNCH_OPTION}}" 2>/dev/null) || return 1
  [[ -n "$launch_id" && "$launch_id" != *$'\n'* && "$launch_id" != *$'\r'* \
     && "$launch_id" != *$'\t'* ]] || return 1
  printf '%s\n' "$launch_id"
}

quota_monitor_new_launch_id() {
  local generation
  generation=$(quota_session_created "$QUOTA_MONITOR_SESSION") || return 1
  printf '%s-%s-%s-%s\n' "$generation" "$(date +%s)" "$$" "$RANDOM"
}

# session_created + pane_id + pane_pid 是 tmux 容器身份。原 pane 内 `/exit` 时三者都必须
# 保持不变；pane 被 respawn/替换虽然同名，也不能冒充一次成功的“只换 cc”。
quota_monitor_pane_identity() {
  local identity
  identity=$(tmux display-message -p -t "$QUOTA_MONITOR_SESSION" \
    '#{session_created}|#{pane_id}|#{pane_pid}' 2>/dev/null) || return 1
  [[ "$identity" =~ ^[0-9]+\|%[0-9]+\|[0-9]+$ ]] || return 1
  printf '%s\n' "$identity"
}

quota_monitor_shell_ready() {
  local command
  command=$(tmux display-message -p -t "$QUOTA_MONITOR_SESSION" \
    '#{pane_current_command}' 2>/dev/null) || return 1
  case "$command" in
    bash|dash|fish|ksh|sh|zsh) return 0 ;;
    *) return 1 ;;
  esac
}

# quota_monitor_ready — pane 底部出现 composer 即就绪（占位提示也算，见 QUOTA_COMPOSER_REGEX）
# 🔻 CORRECTED (pipefail/SIGPIPE) — see the note at the top of this file. / 见文件开头那段。
quota_monitor_ready() {
  local t
  quota_monitor_shell_ready && return 1
  # 只看当前可见屏，不把上一代 cc 留在 tmux history 里的旧 composer 当成新进程已就绪。
  t=$(tmux capture-pane -t "$QUOTA_MONITOR_SESSION" -p 2>/dev/null) || return 1
  grep -q 'Is this a project you created or one you trust' <<<"$t" && return 1
  local t12; t12=$(printf '%s\n' "$t" | tail -12)
  grep -qE "$QUOTA_COMPOSER_REGEX" <<<"$t12"
}

# 🔻 CORRECTED (pipefail/SIGPIPE) — see the note at the top of this file. / 见文件开头那段。
quota_monitor_wait_ready() {
  local attempts i t ready_sec="$QUOTA_MONITOR_READY_SEC"
  [[ "$ready_sec" =~ ^[0-9]+$ ]] || ready_sec=40
  attempts=$(( (ready_sec + 1) / 2 ))
  (( attempts > 0 )) || attempts=1
  for (( i=0; i<=attempts; i++ )); do
    t=$(tmux capture-pane -t "$QUOTA_MONITOR_SESSION" -p 2>/dev/null || true)
    # 首次进新目录 cc 会弹信任框；只在确认是信任框时才回车，不盲拍。
    if grep -q 'Is this a project you created or one you trust' <<<"$t"; then
      tmux send-keys -t "$QUOTA_MONITOR_SESSION" Enter 2>/dev/null
    elif ! quota_monitor_shell_ready \
         && { quota_monitor_panel_open || quota_monitor_ready; }; then
      return 0
    fi
    (( i < attempts )) && sleep 2
  done
  quota_log "⚠️ monitor session not ready within ${ready_sec}s"
  return 1
}

# 在现有 tmux pane 的 shell 中启动一代新 cc。先写 live launch id，再把同一个 id 固化
# 进 statusLine callback；启动失败时 state 仍是旧 id，owner guard 会 fail closed。
quota_monitor_launch_in_pane() {
  local launch_identity launch_email="" launch_uuid="" launch_usage_uuid=""
  local launch_gen launch_id launch_cmd attempts i exit_sec="$QUOTA_MONITOR_EXIT_SEC"
  QUOTA_MONITOR_STARTED_LAUNCH_ID=""
  QUOTA_MONITOR_STARTED_EMAIL=""
  QUOTA_MONITOR_STARTED_UUID=""
  quota_monitor_single_pane_id >/dev/null || {
    quota_log "❌ monitor session is not a single unique pane; refusing to launch a new CLI"; return 1; }
  [[ "$exit_sec" =~ ^[0-9]+$ ]] || exit_sec=15
  attempts=$(( exit_sec * 2 ))
  (( attempts > 0 )) || attempts=1
  for (( i=0; i<=attempts; i++ )); do
    quota_monitor_shell_ready && break
    (( i < attempts )) && sleep 0.5
  done
  quota_monitor_shell_ready || {
    quota_log "❌ monitor pane did not return to a shell; cannot launch a new CLI"; return 1; }

  launch_gen=$(quota_session_created "$QUOTA_MONITOR_SESSION") || return 1
  launch_id=$(quota_monitor_new_launch_id) || return 1
  launch_identity=$(quota_identity_read 2>/dev/null || true)
  if [[ -n "$launch_identity" ]]; then
    IFS=$'\037' read -r launch_email launch_uuid launch_usage_uuid <<< "$launch_identity"
  fi
  : "${launch_usage_uuid:-}"
  launch_cmd=$(quota_monitor_launch_command "$launch_email" "$launch_uuid" "$launch_gen" "$launch_id")
  tmux set-option -q -t "$QUOTA_MONITOR_SESSION" "$QUOTA_MONITOR_LAUNCH_OPTION" \
    "$launch_id" 2>/dev/null || return 1
  # 清掉可见屏中的上一代 UI；tmux history 与独立原始帧日志都保留。这样 ready 判据不会
  # 在新 cc 尚未起来时误命中旧 composer。C-u 先清 shell 残留半行，避免重试时把两条
  # launch 命令拼接起来执行。
  tmux send-keys -t "$QUOTA_MONITOR_SESSION" C-u 2>/dev/null || return 1
  sleep 0.2
  tmux send-keys -t "$QUOTA_MONITOR_SESSION" C-l 2>/dev/null || return 1
  sleep 0.2
  tmux send-keys -t "$QUOTA_MONITOR_SESSION" -l "$launch_cmd" 2>/dev/null || return 1
  tmux send-keys -t "$QUOTA_MONITOR_SESSION" Enter 2>/dev/null || return 1
  quota_log "monitor session $QUOTA_MONITOR_SESSION launched a new CLI in the same pane, waiting for ready (launch=$launch_id, shadow statusLine=$([[ "$launch_cmd" == *shadow-statusline-ingest* ]] && echo on || echo off))"
  quota_monitor_wait_ready || return 1
  [[ "$(quota_monitor_live_launch_id 2>/dev/null || true)" == "$launch_id" ]] || {
    quota_log "❌ live launch id changed after the new CLI became ready; refusing to bind owner"; return 1; }
  QUOTA_MONITOR_STARTED_LAUNCH_ID=$launch_id
  QUOTA_MONITOR_STARTED_EMAIL=$launch_email
  QUOTA_MONITOR_STARTED_UUID=$launch_uuid
}

# 优先把已有 pane 用作容器；只有 tmux session 本来就不存在时才创建一次。
quota_monitor_ensure() {
  if quota_monitor_alive && ! quota_monitor_single_pane_id >/dev/null; then
    quota_log "❌ monitor session has multiple panes/windows; refusing to act on the session target"
    return 1
  fi
  if quota_monitor_alive && { quota_monitor_panel_open || quota_monitor_ready; }; then return 0; fi
  if ! quota_monitor_alive; then
    tmux new-session -d -s "$QUOTA_MONITOR_SESSION" -x 200 -y 50 \
      -c "$QUOTA_MONITOR_CWD" 2>/dev/null || {
      quota_log "❌ failed to create the monitor session"; return 1; }
    quota_monitor_single_pane_id >/dev/null || {
      quota_log "❌ the newly created monitor session is not a single unique pane"; return 1; }
  elif ! quota_monitor_shell_ready; then
    # 可能是上一轮仍在启动；先给它原有 ready 预算，不盲目再塞一条启动命令。
    quota_monitor_wait_ready && return 0
    return 1
  fi
  quota_monitor_launch_in_pane
}

# 只退出 pane 内的 cc，不动 tmux session/window/pane。先拿到 composer 正证，再发
# `/exit`；退出后回读 shell 与容器三元组，任何一步不确定都 fail closed。
# 🔻 CORRECTED (pipefail/SIGPIPE) — see the note at the top of this file. / 见文件开头那段。
quota_monitor_exit_to_shell() {
  local before after frame typed=0 attempts i exit_sec="$QUOTA_MONITOR_EXIT_SEC"
  quota_monitor_alive || return 1
  quota_monitor_single_pane_id >/dev/null || {
    quota_log "❌ monitor session is not a single unique pane; /exit not sent"; return 1; }
  [[ "$exit_sec" =~ ^[0-9]+$ ]] || exit_sec=15
  before=$(quota_monitor_pane_identity) || return 1
  if quota_monitor_panel_open && ! quota_monitor_dismiss; then
    # 极少数 UI 卡态给一次中断机会，仍要求随后出现 composer；绝不直接 kill tmux。
    tmux send-keys -t "$QUOTA_MONITOR_SESSION" C-c 2>/dev/null || return 1
    sleep 1
  fi
  quota_monitor_ready || {
    quota_log "❌ could not get a composer in the monitor session; /exit not sent"; return 1; }
  tmux send-keys -t "$QUOTA_MONITOR_SESSION" C-u 2>/dev/null || return 1
  sleep 0.3
  tmux send-keys -t "$QUOTA_MONITOR_SESSION" -l '/exit' 2>/dev/null || return 1
  for i in 1 2 3 4 5 6 7 8; do
    sleep 0.5
    frame=$(tmux capture-pane -t "$QUOTA_MONITOR_SESSION" -p 2>/dev/null || true)
    if grep -qE '❯.*\/exit' <<<"$frame"; then typed=1; break; fi
  done
  if (( ! typed )); then
    tmux send-keys -t "$QUOTA_MONITOR_SESSION" C-u 2>/dev/null || true
    quota_log "❌ /exit never appeared in the composer; monitor generation not rolled"
    return 1
  fi
  tmux send-keys -t "$QUOTA_MONITOR_SESSION" Enter 2>/dev/null || return 1
  attempts=$(( exit_sec * 2 ))
  (( attempts > 0 )) || attempts=1
  for (( i=0; i<=attempts; i++ )); do
    quota_monitor_shell_ready && break
    (( i < attempts )) && sleep 0.5
  done
  quota_monitor_shell_ready || {
    quota_log "❌ did not return to a shell within ${exit_sec}s after /exit"; return 1; }
  after=$(quota_monitor_pane_identity) || return 1
  if [[ "$after" != "$before" ]]; then
    quota_log "❌ tmux pane identity changed across /exit -> will not launch the CLI in an unknown pane"
    return 1
  fi
}

# quota_reset_same_window / quota_reset_later_window — reset 分钟显示抖动归一化。
# 两个 epoch 相差不超过容差时只能靠同窗单调性判新旧；超过容差才具有换窗意义。
quota_reset_same_window() {
  local left="${1:-}" right="${2:-}" delta
  [[ "$left" =~ ^[0-9]+$ && "$right" =~ ^[0-9]+$ \
     && "$QUOTA_RESET_DISPLAY_SKEW" =~ ^[0-9]+$ ]] || return 1
  delta=$(( left - right ))
  (( delta < 0 )) && delta=$(( -delta ))
  (( delta <= QUOTA_RESET_DISPLAY_SKEW ))
}

quota_reset_later_window() {
  local candidate="${1:-}" baseline="${2:-}"
  [[ "$candidate" =~ ^[0-9]+$ && "$baseline" =~ ^[0-9]+$ \
     && "$QUOTA_RESET_DISPLAY_SKEW" =~ ^[0-9]+$ ]] || return 1
  (( candidate - baseline > QUOTA_RESET_DISPLAY_SKEW ))
}

# quota_window_sample_relation — 单个窗口里 candidate 相对 best 的窗口关系。
# 输出 new/same/old；0% 且无 reset 只在旧 reset 已到期时代表新 inactive 窗口。
quota_window_sample_relation() {
  local candidate_reset="${1:-}" candidate_pct="${2:-}" best_reset="${3:-}" best_pct="${4:-}" now
  now=$(date +%s)
  if [[ "$candidate_reset" =~ ^[0-9]+$ && "$best_reset" =~ ^[0-9]+$ ]]; then
    if quota_reset_later_window "$candidate_reset" "$best_reset"; then printf 'new\n'; return 0; fi
    if quota_reset_later_window "$best_reset" "$candidate_reset"; then printf 'old\n'; return 0; fi
    printf 'same\n'; return 0
  fi
  if [[ -z "$candidate_reset" && "$candidate_pct" == "0" \
     && "$best_reset" =~ ^[0-9]+$ ]]; then
    if (( best_reset <= now )); then printf 'new\n'; else printf 'old\n'; fi
    return 0
  fi
  if [[ "$candidate_reset" =~ ^[0-9]+$ \
     && -z "$best_reset" && "$best_pct" == "0" ]]; then
    if (( candidate_reset > now )); then printf 'new\n'; else printf 'old\n'; fi
    return 0
  fi
  if [[ -z "$candidate_reset" && "$candidate_pct" == "0" \
     && -z "$best_reset" && "$best_pct" == "0" ]]; then
    printf 'same\n'; return 0
  fi
  printf 'old\n'
}

# quota_panel_sample_better — 同一次网络刷新采样期间，候选帧是否比当前 best 更新。
# 抽成纯判据是为了把 66@4:00 -> 77@3:59 及逆序都钉进回归；若把这里漏改，
# 即使跨轮 stale guard 正确，也会先在单轮内选错缓存帧。
quota_panel_sample_better() {
  local candidate_reset="${1:-}" candidate_five="${2:-}" candidate_week="${3:-}"
  local best_reset="${4:-}" best_five="${5:-}" best_week="${6:-}"
  local candidate_wreset="__not_supplied" best_wreset="__not_supplied"
  local five_relation week_relation
  if (( $# >= 8 )); then candidate_wreset="$7"; best_wreset="$8"; fi
  [[ "$candidate_five" =~ ^[0-9]+$ && "$candidate_week" =~ ^[0-9]+$ \
     && "$best_five" =~ ^[0-9]+$ && "$best_week" =~ ^[0-9]+$ ]] || return 1
  # 六参数旧调用保留原语义，供已有纯判据测试与外部 source caller 兼容。
  if [[ "$candidate_wreset" == "__not_supplied" ]]; then
    five_relation=$(quota_window_sample_relation \
      "$candidate_reset" "$candidate_five" "$best_reset" "$best_five")
    [[ "$five_relation" == "new" ]] && return 0
    [[ "$five_relation" == "same" ]] || return 1
    (( candidate_five > best_five \
       || (candidate_five == best_five && candidate_week > best_week) ))
    return
  fi
  five_relation=$(quota_window_sample_relation \
    "$candidate_reset" "$candidate_five" "$best_reset" "$best_five")
  week_relation=$(quota_window_sample_relation \
    "$candidate_wreset" "$candidate_week" "$best_wreset" "$best_week")
  [[ "$five_relation" == "old" || "$week_relation" == "old" ]] && return 1
  if [[ "$five_relation" == "new" || "$week_relation" == "new" ]]; then
    # 另一维若仍在同窗就不得倒退；两维同时换窗则都可归零。
    [[ "$five_relation" != "same" || "$candidate_five" -ge "$best_five" ]] || return 1
    [[ "$week_relation" != "same" || "$candidate_week" -ge "$best_week" ]] || return 1
    return 0
  fi
  [[ "$five_relation" == "same" && "$week_relation" == "same" ]] || return 1
  (( candidate_five >= best_five && candidate_week >= best_week \
     && (candidate_five > best_five || candidate_week > best_week) ))
}

# quota_frame_stale — 这一帧是不是陈旧的（属于已过期窗口 / 比已确认读数更旧）
# return 0 = 陈旧，必须丢弃；return 1 = 可采信
#
# 2026-08-11 事故的两条真实序列都不是"回退"，而是**旧窗口的高值回来了**：
#     accountA 19:49:53 five=97%(old window) -> 19:50:13 five=0%(real reset) -> 19:50:31 five=97%(old window)
#     accountB 21:10:09 five=0%(real reset) -> 21:10:28 five=99%(old window)
# 97>0 是上涨，纯单调性判据一个都拦不住；两次都因此错切账号，第二次直接把 waiting
# 推到了 24 小时后。所以判据必须**先看帧属于哪个窗口，再看窗口内的数值**。
quota_frame_stale() {
  local acct="$1" five="$2" week="$3" s_reset="$4" w_reset="$5" now
  now=$(date +%s)

  # (1) 窗口已过期：五小时 reset 落在过去，说明这一帧是上一个窗口留下的缓存。
  #     这条与账号无关（视界钳制保证过期窗口会解析成过去的 epoch）。
  if [[ "$s_reset" =~ ^[0-9]+$ ]] && (( s_reset <= now )); then
    return 0
  fi

  local last_acct last_five last_week last_sr last_wr
  last_acct=$(quota_state_get '.account' "")
  # 账号不同不可比：切号后第一次读本来就该是另一个账号的独立读数
  [[ -n "$last_acct" && "$last_acct" == "$acct" ]] || return 1
  last_five=$(quota_state_get '.five_hour' "")
  last_week=$(quota_state_get '.seven_day' "")
  last_sr=$(quota_state_get '.five_reset_ts' "")
  last_wr=$(quota_state_get '.week_reset_ts' "")

  # ⚠️ 基准本身必须先可信。上次确认的 five_reset_ts 可能是**旧 buggy 代码写下的坏值**
  # （无视界钳制时会把 "Resets 2:10am" 解析成一天以后），或来自早已结束的窗口。
  # 用同一条物理事实校验它：五小时窗口的 reset 必然在 5 小时以内，否则不是合法的
  # 当前窗口边界，一律当"没有基准"处理。
  # 2026-08-12 11:38 活体实撞：state 里存着 08-13 02:10（距今 14.5h），把面板的真值
  # 08-12 12:10 判成了"更旧的窗口"，新 poller 每一帧都被拒，读数彻底进不来。
  # ⚠️ 基准 reset 无效 = 上次确认的读数属于**已结束的窗口**，那么它的百分比也一并作废，
  # 不能只作废 reset 留着百分比去做单调性比较。2026-08-12 12:19 实撞：accountA 12:10 重置后
  # state 顶层还留着旧窗口的 five=100，新窗口真值 20% 被「100→20 回退」拒掉，读数饿死。
  if [[ "$last_sr" =~ ^[0-9]+$ ]] \
     && { (( last_sr <= now )) || (( last_sr - now > QUOTA_SESSION_WINDOW_HORIZON )); }; then
    last_sr=""
    last_five=""
  fi
  if [[ "$last_wr" =~ ^[0-9]+$ ]] \
     && { (( last_wr <= now )) || (( last_wr - now > QUOTA_WEEK_WINDOW_HORIZON )); }; then
    last_wr=""
    last_week=""
  fi

  # (2) 五小时窗口比上次确认的更旧 -> 旧窗口帧。5 分钟内属于同窗展示/缓存抖动，
  #     不能把稍早 reset 的新鲜高值拒掉，也不能把稍晚 reset 的缓存低值当成新窗口。
  if quota_reset_later_window "$last_sr" "$s_reset"; then
    return 0
  fi
  # (3) 同一窗口内用量回退 -> 物理上不可能
  if [[ "$last_five" =~ ^[0-9]+$ && "$five" =~ ^[0-9]+$ ]] && (( five < last_five )); then
    quota_reset_later_window "$s_reset" "$last_sr" || return 0
  fi
  # (4)(5) 周窗口同理（周 reset 文案自带日期，不会跨日回卷）
  if quota_reset_later_window "$last_wr" "$w_reset"; then
    return 0
  fi
  if [[ "$last_week" =~ ^[0-9]+$ && "$week" =~ ^[0-9]+$ ]] && (( week < last_week )); then
    quota_reset_later_window "$w_reset" "$last_wr" || return 0
  fi
  return 1
}

# quota_monitor_dismiss — 反复 Esc 直到 composer 回来
# ⚠️ 单发一次 Esc 不可靠：`/usage` 的面板打开后还会继续渲染（底部挂「Scanning local
# sessions…」），而 fetchedAtMs 在 API 返回的那一刻就前进了——早于面板渲染完。此时发的
# Esc 会被吞掉，面板留在屏上。**下一轮的 `/usage` 几个字就会打进面板当导航键用**，
# 于是再也拉不到新数据，看起来像"监控会话卡死"。（2026-08-11 首次上线活体撞出：
# 第一轮成功之后连续两轮超时。）
# 所以这里不猜时序，只认结果：发一次验一次，最多 4 次。
# 进场先看现场：面板开着就先关掉再走流程，别把命令打进面板里。
# 判据用两条**互相独立**的：面板标志消失 + composer 出现。只看 composer 不够——
# 面板滚动到下半屏时底部可能没有面板标志文字，光凭"没看见面板"会误判成已关闭。
quota_monitor_dismiss() {
  local i
  for i in 1 2 3 4 5; do
    if ! quota_monitor_panel_open && quota_monitor_ready; then
      return 0
    fi
    tmux send-keys -t "$QUOTA_MONITOR_SESSION" Escape 2>/dev/null
    sleep 1
  done
  ! quota_monitor_panel_open && quota_monitor_ready
}

# quota_panel_parse — 从面板文本抽 "session_pct<TAB>week_pct<TAB>session_reset<TAB>week_reset"
# 只认 "Current session" 与 "Current week (all models)" 两段，Fable 那段明确跳过。
quota_panel_parse() {
  printf '%s\n' "$1" | awk '
    function pct(s){ if (match(s,/[0-9]+% used/)) { p=substr(s,RSTART,RLENGTH); sub(/% used/,"",p); return p } return "" }
    /^[[:space:]]*Current session[[:space:]]*$/      { sec="s"; next }
    /^[[:space:]]*Current week \(all models\)[[:space:]]*$/ { sec="w"; next }
    /^[[:space:]]*Current week \(/                   { sec="";  next }   # Fable 等分模型窗口，跳过
    {
      if (sec=="s") { if (sp=="") { v=pct($0); if (v!="") sp=v }
                      else if (sr=="" && $0 ~ /Resets/) { sr=$0; sec="" } }
      else if (sec=="w") { if (wp=="") { v=pct($0); if (v!="") wp=v }
                           else if (wr=="" && $0 ~ /Resets/) { wr=$0; sec="" } }
    }
    END {
      if (sp=="" || wp=="") exit 1
      gsub(/^[[:space:]]+|[[:space:]]+$/,"",sr); gsub(/^[[:space:]]+|[[:space:]]+$/,"",wr)
      printf "%s\t%s\t%s\t%s\n", sp, wp, sr, wr
    }'
}

# quota_panel_field — 从 TAB 协议取字段且保留空列。
# Bash 的 `IFS=$'\t' read` 会把连续 TAB 当 whitespace 折叠；0% 窗口没有 Resets 行时，
# week reset 会因此错位成 five reset。cut 的字段语义会保留连续分隔符。
quota_panel_field() {
  local row="$1" field="$2"
  [[ "$field" =~ ^[1-4]$ ]] || return 1
  printf '%s\n' "$row" | cut -f"$field"
}

# quota_panel_frame_status — 对**整张可见面板**做可信度分类，先判污染再取数字。
# 错误页仍会带上一帧百分比；若先 parse，429/last-known 会被误当成新鲜额度。
# 🔻 CORRECTED (pipefail/SIGPIPE) — see the note at the top of this file. / 见文件开头那段。
quota_panel_frame_status() {
  local frame="$1"
  if grep -qiE 'Refreshing([.]{3}|…)?' <<<"$frame"; then
    printf 'refreshing\n'; return 0
  fi
  if grep -qiE 'rate[ -]?limit(ed| reached)?|too many requests|HTTP[[:space:]]*429|\b429\b' <<<"$frame"; then
    printf 'rate_limited\n'; return 0
  fi
  if grep -qiE 'last[ -]?known usage|showing (cached|previous) usage' <<<"$frame"; then
    printf 'last_known\n'; return 0
  fi
  # ⚠️ 只在**额度块所属区域**内认这些错误文案。
  # `/usage` 页下半部分的「用量归因分析」要扫描本机会话文件来算「哪些会话吃了多少」，
  # 它扫不动时会打 `Could not refresh usage data` —— 那句属于归因块，**与上面的额度数值
  # 无关**，额度部分往往是好的。旧判据不看位置，整屏出现就判整帧失败。
  # 2026-08-20 实测误伤 6 次（12:21×3、12:37、12:51、12:54），每次丢一帧好数据并退一档；
  # 12:15-12:21 连着 19 分钟拿不到读数、最后靠横幅救场，根子就在这。
  # 做法：以 `What's contributing to your limits usage?` 为界，界之后的错误文案不作数。
  local _above
  _above=$(printf '%s\n' "$frame" | sed -n "1,/What's contributing to your limits usage/p")
  [[ -n "$_above" ]] || _above="$frame"
  if grep -qiE 'could not refresh( usage( data)?)?|failed to (load|refresh).*usage|unable to (load|refresh).*usage|usage data unavailable' <<<"$_above"; then
    printf 'refresh_failed\n'; return 0
  fi
  if grep -qE '^[[:space:]]*Current session[[:space:]]*$' <<<"$frame" \
     && grep -qE '^[[:space:]]*Current week \(all models\)[[:space:]]*$' <<<"$frame"; then
    if quota_panel_parse "$frame" >/dev/null 2>&1; then
      printf 'clean\n'
    else
      printf 'incomplete\n'
    fi
    return 0
  fi
  # 常驻后 cc 会继续渲染本机 usage 归因，额度区块可能被滚出当前 viewport；顶部 tab chrome
  # 仍在且没有 composer，说明面板没有关闭。这里仅标为 panel_detail（可留原始日志但无数值
  # 可决策），避免 quota_monitor_observe 把它当 closed 而绕过 next_due 提前重开一次网络请求。
  if grep -qE \
       '^[[:space:]]*Settings[[:space:]]+Status[[:space:]]+Config[[:space:]]+Usage[[:space:]]+Stats[[:space:]]*$' <<<"$frame" \
     && ! grep -qE "$(quota_idle_cursor_regex)" <<<"$frame"; then
    printf 'panel_detail\n'
    return 0
  fi
  printf 'closed\n'
}

# 网络 `/usage` 分档只看当前账号两个窗口里更大的 used%，即更小的 remaining%。
quota_usage_interval_for_values() {
  local five="${1:-}" week="${2:-}" worst remaining
  if [[ ! "$five" =~ ^[0-9]+$ || ! "$week" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$QUOTA_USAGE_INTERVAL_NEAR"
    return 0
  fi
  worst=$five; (( week > worst )) && worst=$week
  remaining=$(( 100 - worst ))
  if (( remaining <= QUOTA_USAGE_REMAINING_NEAR )); then
    printf '%s\n' "$QUOTA_USAGE_INTERVAL_NEAR"
  elif (( remaining <= QUOTA_USAGE_REMAINING_MID )); then
    printf '%s\n' "$QUOTA_USAGE_INTERVAL_MID"
  else
    printf '%s\n' "$QUOTA_USAGE_INTERVAL_FAR"
  fi
}

# quota_usage_interval_adaptive — layers a rate-based speed-up on top of the level tier.
# It can only make the interval **shorter**: the level tier is always the upper
# bound, and QUOTA_USAGE_INTERVAL_FLOOR is the lower one.
#
# Arguments are passed in explicitly rather than read from state inside the
# function — that makes it unit-testable, and it forces the caller to be explicit
# that these are the **pre-merge** values. This function must be called **before**
# the new reading is written into state, or `prev` becomes `cur` and the rate is
# identically zero.
#
# ⚠️ prev_email must equal the current account for the rate to mean anything.
#    Comparing percentages across two different accounts' windows is meaningless,
#    and the round right after a switch is the dangerous one (old account 100% →
#    new account 0% computes as negative).
#
# 🔻 REWRITTEN DURING EXTRACTION. Upstream had four speed-up sources; three of them
#    read fleet-specific data that is not part of this project:
#      ② on-screen banner pressure  ← a screen-log archive of every fleet session
#      ③ concurrency ("busy" count) ← enumerating fleet worker sessions by name
#      ④ pending resume deliveries  ← the fleet's blocked-session ledger
#    Only ① (measured rate) survives, because it is the only one whose input this
#    project can observe on its own. The `pending` and `busy` parameters are kept in
#    the signature so the call sites and the upstream tests still line up; they are
#    accepted and ignored, and are constantly 0 here.
#    ⚠️ The consequence is worth stating plainly rather than hiding: the rate source
#    is **reactive** — it must first see the percentage climbing before it tightens.
#    Upstream measured its blind spot on 2026-08-20 11:08: that round's reading was
#    *identical* to the previous one (both 47%), so "not climbing" was the correct
#    reading of the data, and the entire surge (53 points in 5m14s, ~10%/min)
#    happened **inside** that five-minute window without a single sample seeing it.
#    Sources ② and ③ existed to cover exactly that blind spot. Without them, a burst
#    that starts from rest is invisible until the next scheduled query.
#
# 🔻 抽取时**重写过**。上游有四个提速来源，其中三个读的是 Fleet 专有数据，不属于本项目：
#      ②屏幕横幅压力 ← 全编队会话的屏幕留档
#      ③并发数 ← 按名字枚举编队 worker 会话
#      ④待投递的复工消息 ← 编队的 blocked 会话账本
#    只保留 ①（实测流速），因为只有它的输入是本项目自己观测得到的。`pending` 与 `busy`
#    两个参数保留在签名里（让调用点与上游用例仍对得上），接受但忽略，在本仓恒为 0。
#    ⚠️ 代价要直说而不是藏起来：流速判据是**反应式**的——必须先看见百分比在涨才会收紧。
#    上游 2026-08-20 11:08 实测过它的盲区：那一轮读数与上一轮**完全相同**（都是 47%），
#    「没在涨」是对数据的正确判读，而整个飙升（5 分 14 秒涨 53 点，约 10%/分钟）
#    发生在那个五分钟窗口**内部**，一个采样都没看见。②③正是为补这个盲区而存在的。
#    没有它们，从静止直接起飞的那一类爆发，要到下一次计划查询才看得见。
quota_usage_interval_adaptive() {
  local five="$1" week="$2" prev_five="$3" prev_week="$4" prev_ts="$5" now="$6" \
        prev_email="$7" cur_email="$8" pending="${9:-0}" busy="${10:-0}"
  : "${pending}" "${busy}"   # accepted for signature compatibility, unused here / 仅为签名兼容，本仓不消费
  local base rate_interval elapsed d_five d_week need best
  base=$(quota_usage_interval_for_values "$five" "$week")
  [[ "$QUOTA_RATE_ADAPTIVE" == "1" ]] || { printf '%s\n' "$base"; return 0; }
  best="$base"

  # ① Rate: how long until the switch line, halved
  # ① 流速：还有多久到切换线，取一半
  if [[ "$prev_five" =~ ^[0-9]+$ && "$prev_week" =~ ^[0-9]+$ \
     && "$prev_ts" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ \
     && -n "$prev_email" && "$prev_email" == "$cur_email" ]]; then
    elapsed=$(( now - prev_ts ))
    if (( elapsed > 0 && elapsed <= 3600 )); then
      d_five=$(( five - prev_five ))
      d_week=$(( week - prev_week ))
      # Tighten only while **climbing**. A window reset makes the percentage drop,
      # and that is not a rate.
      # 只在**上涨**时收紧。窗口重置会让百分比掉下来，那不是流速。
      if (( d_five > 0 )) && (( five < QUOTA_SWITCH_PCT_FIVE )); then
        # need = (threshold - current) * elapsed / climb / 2 — integer arithmetic,
        # and rounding down is the conservative direction
        # need = (阈值-当前) * elapsed / 涨幅 / 2 —— 整数运算，向下取整更保守
        need=$(( (QUOTA_SWITCH_PCT_FIVE - five) * elapsed / d_five / 2 ))
        (( need < best )) && best="$need"
      fi
      if (( d_week > 0 )) && (( week < QUOTA_SWITCH_PCT_WEEK )); then
        need=$(( (QUOTA_SWITCH_PCT_WEEK - week) * elapsed / d_week / 2 ))
        (( need < best )) && best="$need"
      fi
    fi
  fi

  (( best < QUOTA_USAGE_INTERVAL_FLOOR )) && best="$QUOTA_USAGE_INTERVAL_FLOOR"
  (( best > base )) && best="$base"
  printf '%s\n' "$best"
}

quota_usage_backoff_interval() {
  local current="${1:-0}"
  [[ "$current" =~ ^[0-9]+$ ]] || current=0
  if (( current < QUOTA_USAGE_INTERVAL_MID )); then
    printf '%s\n' "$QUOTA_USAGE_INTERVAL_MID"
  else
    printf '%s\n' "$QUOTA_USAGE_INTERVAL_FAR"
  fi
}

# quota_panel_reset_epoch — the panel's `Resets` line -> epoch
# Two observed shapes: `Resets 3:29pm (Asia/Shanghai)` / `Resets Aug 13, 2:59pm (Asia/Shanghai)`
# Time-zone handling is the same as quota_parse_reset_epoch: an IANA name in
# parentheses wins, otherwise QUOTA_FALLBACK_TZ (empty = local) with a %z self-check.
# Second argument `horizon`: the maximum remaining life of that window. A five-hour
# window's reset is necessarily within five hours, so past the horizon this line
# refers to a moment that has **already passed** — the frame belongs to an expired window.
# ⚠️ Without this clamp, midnight roll-over disguises a stale frame as a *newer*
# window: the 2026-08-11 19:50:31 frame read `Resets 7:50pm`, 19:50 had just gone by,
# and naive parsing +86400 made it **tomorrow** 19:50 — later than the genuine frame's
# 00:50 today, so "compare freshness by reset" broke completely. In that incident this
# is the exact step that made the old poller accept a stale 97%.
# quota_panel_reset_epoch — 面板的 Resets 行 → epoch
# 两种形态（实测）：`Resets 3:29pm (Asia/Shanghai)` / `Resets Aug 13, 2:59pm (Asia/Shanghai)`
# 时区处理同 quota_parse_reset_epoch：括号里的 IANA 名优先，否则用 QUOTA_FALLBACK_TZ
# （留空 = 本机时区）并自检 %z。
# 第二参数 horizon：该窗口的最大剩余时长。五小时窗口的 reset 必然在 5 小时以内，
# 超出视界就说明这行文案指的是**已经过去**的那一刻 —— 即这一帧属于已过期的旧窗口。
# ⚠️ 没有这条钳制，跨日回卷会把陈旧帧伪装成"更新的窗口"：2026-08-11 19:50:31 那帧写着
# `Resets 7:50pm`，而 19:50 刚过去，裸解析 +86400 变成**明天 19:50**，比真帧的今天 00:50
# 还晚，于是"按 reset 比新旧"完全失效。事故里正是这一步让旧 poller 接受了 97% 的陈旧帧。
quota_panel_reset_epoch() {
  local line="$1" horizon="${2:-}" tz datepart timepart epoch now
  [[ -z "$line" ]] && return 1
  tz=$(printf '%s' "$line" | grep -oE '\([A-Za-z_/+-]+\)' | tr -d '()')
  if [[ -z "$tz" || "$tz" != */* ]]; then
    # No IANA zone name in the text -> fall back to QUOTA_FALLBACK_TZ (empty = this
    # machine's local zone). Self-check that we can actually resolve an offset; a
    # failure here must be a parse failure, never a silently-UTC value written to state.
    # 文本里没有 IANA 区域名 → 退到 QUOTA_FALLBACK_TZ（留空 = 本机时区）。
    # 自检必须能解析出偏移量；解析不出就判失败，绝不把静默回退 UTC 的值写进状态。
    tz="$QUOTA_FALLBACK_TZ"
    [[ "$(quota_tz_date "$tz" '+%z' 2>/dev/null)" =~ ^[+-][0-9]{4}$ ]] || return 1
  fi
  timepart=$(printf '%s' "$line" | grep -oE '[0-9]{1,2}(:[0-9]{2})?[[:space:]]?(am|pm)' | head -1)
  [[ -z "$timepart" ]] && return 1
  datepart=$(printf '%s' "$line" | grep -oE '[A-Z][a-z]{2} [0-9]{1,2},' | head -1 | tr -d ',')
  if [[ -n "$datepart" ]]; then
    epoch=$(quota_tz_date "$tz" -d "$datepart $(quota_tz_date "$tz" +%Y) $timepart" +%s 2>/dev/null) || return 1
  else
    epoch=$(quota_tz_date "$tz" -d "$(quota_tz_date "$tz" +%Y-%m-%d) $timepart" +%s 2>/dev/null) || return 1
    now=$(date +%s)
    (( epoch <= now )) && epoch=$(( epoch + 86400 ))
    # 回卷过头 → 这行文案其实指向过去；还原成过去的那个 epoch，让调用方看得出窗口已过期
    if [[ "$horizon" =~ ^[0-9]+$ ]] && (( epoch - now > horizon )); then
      epoch=$(( epoch - 86400 ))
    fi
  fi
  [[ -z "$epoch" ]] && return 1
  printf '%s\n' "$epoch"
}

# quota_reset_validate_for_write — reset 进入决策台账前的唯一合法性闸。
# 读时校验仍保留，用来挡历史坏值/人工修改；新采样则必须在写入前证明 reset 是当前窗口
# 的未来边界。任一维非法时调用方应整帧拒绝，不能写 null 或让新百分比搭配旧 reset。
quota_reset_validate_for_write() {
  local epoch="${1:-}" now="${2:-}" horizon="${3:-}"
  [[ "$epoch" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ && "$horizon" =~ ^[0-9]+$ ]] || return 1
  (( epoch > now && epoch - now <= horizon )) || return 1
  printf '%s\n' "$epoch"
}

# quota_window_reset_for_write — 把面板的一维 pct/reset 规范化成 JSON number 或 null。
# Claude Code 对尚未开始的新窗口会显示 `0% used` 但省略 Resets；这是明确的 inactive，
# 不是 schema 缺失。非 0% 或出现了坏 Resets 文案时仍严格拒绝整帧。
quota_window_reset_for_write() {
  local pct="${1:-}" line="${2:-}" now="${3:-}" horizon="${4:-}" epoch
  [[ "$pct" =~ ^[0-9]+$ ]] || return 1
  if [[ -z "$line" ]]; then
    (( pct == 0 )) || return 1
    printf 'null\n'
    return 0
  fi
  epoch=$(quota_panel_reset_epoch "$line" "$horizon" 2>/dev/null) || return 1
  quota_reset_validate_for_write "$epoch" "$now" "$horizon"
}

# quota_monitor_panel_open — 屏幕上是不是真的开着 /usage 面板
quota_monitor_panel_open() {
  local frame status
  quota_monitor_shell_ready && return 1
  frame=$(tmux capture-pane -t "$QUOTA_MONITOR_SESSION" -p 2>/dev/null) || return 1
  status=$(quota_panel_frame_status "$frame")
  [[ "$status" != "closed" ]]
}

# quota_monitor_prepare_owner — 统一处理 monitor 生存、账号归属与 tmux 代际。
quota_monitor_prepare_owner() {
  quota_account_guard "panel-before" || return 1
  local cur_acct="$QUOTA_GUARD_EMAIL" cur_uuid="$QUOTA_GUARD_UUID"
  local mon_acct mon_uuid mon_gen mon_launch live_gen live_launch
  if ! quota_monitor_alive; then
    quota_monitor_ensure || return 1
    quota_monitor_bind_owner "monitor-after-create" "$cur_acct" "$cur_uuid" \
      "${QUOTA_MONITOR_STARTED_LAUNCH_ID:-}" "${QUOTA_MONITOR_STARTED_EMAIL:-}" \
      "${QUOTA_MONITOR_STARTED_UUID:-}" || return 1
  elif ! quota_monitor_single_pane_id >/dev/null; then
    quota_log "❌ monitor session has multiple panes/windows -> will neither read nor act on an unknown active pane"
    return 1
  elif quota_monitor_shell_ready; then
    # tmux 是长寿容器，里面的 cc 可能已正常退出或启动失败。此时无需 `/exit`，直接在
    # 原 shell 拉起一代并绑定；否则 session 活着会掩盖 monitor 实际已死。
    quota_log "monitor tmux is alive but the CLI fell back to a shell -> relaunching in the same pane and rebinding"
    quota_monitor_restart "$cur_acct" "$cur_uuid" || return 1
  elif ! quota_monitor_panel_open && ! quota_monitor_ready; then
    # 可能恰逢上一轮启动中；给它一次正常 ready 预算，超时后 fail closed，不叠加命令。
    quota_monitor_wait_ready || return 1
  fi
  mon_acct=$(quota_state_get '.monitor_account' "")
  mon_uuid=$(quota_state_get '.monitor_uuid' "")
  mon_gen=$(quota_state_get '.monitor_session_created' "")
  mon_launch=$(quota_state_get '.monitor_launch_id' "")
  live_gen=$(quota_session_created "$QUOTA_MONITOR_SESSION" 2>/dev/null || true)
  live_launch=$(quota_monitor_live_launch_id 2>/dev/null || true)
  if [[ -n "$cur_acct" \
     && ( "$mon_acct" != "$cur_acct" || "$mon_uuid" != "$cur_uuid" \
          || -z "$live_gen" || "$mon_gen" != "$live_gen" \
          || -z "$live_launch" || "$mon_launch" != "$live_launch" ) ]]; then
    quota_log "monitor session owner/generation changed (recorded=${mon_acct:-unknown}/${mon_gen:-unknown}/${mon_launch:-unknown}, current=$cur_acct/${live_gen:-unknown}/${live_launch:-unknown}) -> restarting the CLI in the same pane and rebinding"
    quota_monitor_restart "$cur_acct" "$cur_uuid" || return 1
    live_gen=$(quota_session_created "$QUOTA_MONITOR_SESSION" 2>/dev/null || true)
    live_launch=$(quota_monitor_live_launch_id 2>/dev/null || true)
  fi
  QUOTA_MONITOR_CURRENT_ACCOUNT=$cur_acct
  QUOTA_MONITOR_CURRENT_UUID=$cur_uuid
  QUOTA_MONITOR_CURRENT_GENERATION=$live_gen
  QUOTA_MONITOR_CURRENT_LAUNCH_ID=$live_launch
  [[ "$live_gen" =~ ^[0-9]+$ && -n "$live_launch" ]]
}

# composer 中选中 `/usage`，并在真正回车前持久化本次网络 attempt。
# 🔻 CORRECTED (pipefail/SIGPIPE) — see the note at the top of this file. / 见文件开头那段。
quota_monitor_open_usage() {
  local acct="$1" uuid="$2" generation="$3" launch_id="$4" mode="$5"
  local i typed=0 opened=0 now _uframe
  quota_monitor_ready || return 1
  tmux send-keys -t "$QUOTA_MONITOR_SESSION" C-u 2>/dev/null
  sleep 0.3
  tmux send-keys -t "$QUOTA_MONITOR_SESSION" -l '/usage' 2>/dev/null || return 1
  for i in 1 2 3 4 5 6 7 8; do
    sleep 0.5
    _uframe=$(tmux capture-pane -t "$QUOTA_MONITOR_SESSION" -p 2>/dev/null || true)
    if grep -qE '❯.*\/usage' <<<"$_uframe"; then typed=1; break; fi
  done
  (( typed )) || return 1
  sleep 0.5
  now=$(date +%s)
  quota_usage_refresh_begin "$now" "$acct" "$uuid" "$generation" "$launch_id" "$mode" || return 1
  tmux send-keys -t "$QUOTA_MONITOR_SESSION" Enter 2>/dev/null || {
    quota_usage_refresh_failure "$now" "panel_enter_failed" 0 || true; return 1; }
  for i in $(seq 1 20); do
    sleep 0.5
    if quota_monitor_panel_open; then opened=1; break; fi
  done
  if (( ! opened )); then
    QUOTA_LAST_ERROR="panel:open-failed"
    quota_usage_refresh_failure "$(date +%s)" "panel_open_failed" 0 || true
    return 1
  fi
}

# 纯本地观察：只 capture/classify/parse/log，绝不按键、绝不进入额度决策。
quota_monitor_observe() {
  local mode="${1:-local_sample}" frame status now seq penalized
  quota_monitor_prepare_owner || return 1
  if ! quota_monitor_panel_open; then
    QUOTA_PANEL_STATUS_LAST="closed"
    return 2
  fi
  frame=$(tmux capture-pane -t "$QUOTA_MONITOR_SESSION" -p 2>/dev/null) || return 1
  status=$(quota_panel_frame_status "$frame")
  now=$(date +%s)
  QUOTA_PANEL_FRAME_LAST=$frame
  QUOTA_PANEL_STATUS_LAST=$status
  quota_panel_log_observation "$now" "$QUOTA_MONITOR_CURRENT_ACCOUNT" \
    "$QUOTA_MONITOR_CURRENT_UUID" "$mode" "$status" "$frame" || true
  case "$status" in
    rate_limited|last_known|refresh_failed)
      seq=$(quota_state_get '.usage_refresh.refresh_seq' 0)
      penalized=$(quota_state_get '.usage_refresh.last_penalized_seq' -1)
      if [[ "$seq" =~ ^[0-9]+$ && "$seq" != "$penalized" ]]; then
        QUOTA_REFRESH_SEQ=$seq
        quota_usage_refresh_failure "$now" "$status" 1 || true
        quota_log "⚠️ the 10s local observation caught /usage $status -> penalise this refresh once and back off a tier"
      fi
      ;;
  esac
  quota_monitor_owner_guard "panel-observe-after" || return 1
  return 0
}

# stale 帧已经经过本轮多帧稳定采样；此时允许用一代全新 cc 作一次仲裁。先把冷却账
# 持久化再退出旧进程，保证中途崩溃也不会每 10 秒重启/重发请求。重启后的第二次 stale
# 以 mode=stale_recovery 进入，绝不递归；人工 monitor-restart 不受本冷却限制。
quota_monitor_stale_recovery_claim() {
  local now="$1" email="$2" five="$3" week="$4" five_reset="$5" week_reset="$6"
  local last cooldown
  cooldown=$QUOTA_MONITOR_STALE_RESTART_COOLDOWN
  [[ "$cooldown" =~ ^[0-9]+$ ]] || cooldown=1800
  last=$(quota_state_get '.monitor_recovery.last_restart_ts' 0)
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  (( now - last >= cooldown )) || return 1
  quota_state_merge '
      .monitor_recovery = {
        last_restart_ts:$t, reason:"stale_frame", account:$e,
        observed:{five:$five, week:$week, five_reset:$fr, week_reset:$wr}
      }' \
    --argjson t "$now" --arg e "$email" --argjson five "$five" --argjson week "$week" \
    --arg fr "$five_reset" --arg wr "$week_reset"
}

quota_monitor_recover_stale_frame() {
  local mode="$1" email="$2" uuid="$3" five="$4" week="$5" five_reset="$6" week_reset="$7"
  local now
  [[ "$mode" != "stale_recovery" ]] || return 1
  now=$(date +%s)
  quota_monitor_stale_recovery_claim "$now" "$email" "$five" "$week" \
    "$five_reset" "$week_reset" || return 1
  quota_log "♻️ the stable panel is still stale relative to the ledger (five=${five}% week=${week}%) -> restarting the CLI in the same pane for one arbitration round"
  if ! quota_monitor_restart "$email" "$uuid"; then
    quota_log "❌ stale-frame self-heal could not restart the monitor; no automatic retry during the cooldown"
    return 1
  fi
  if quota_monitor_refresh "stale_recovery"; then
    quota_log "✅ the new CLI completed the stale-frame arbitration refresh"
    return 0
  fi
  quota_log "⚠️ arbitration by the new CLI still produced no trustworthy reading; keeping the old decision ledger, no restart loop during the cooldown"
  return 1
}

# quota_monitor_refresh — 到期时只发**一次**网络请求，结束后把 /usage 面板留在屏幕上。
# clean 面板在 Claude Code 2.1.226 中没有 r action，故正常刷新需 Esc 后重开 `/usage`；
# 只有错误页显示 `r to retry` 时才直接按 r。两条路径都先落 attempt，失败不会 10s 狂打。
quota_monitor_refresh() {
  local mode="${1:-scheduled}" frame status action now i
  local cur="" got="" best="" best_five=-1 best_week=-1 best_sreset="" best_wreset="" no_improve=0
  local c_five c_week c_sl c_wl c_sreset c_wreset improved
  QUOTA_PANEL_LAST=""; QUOTA_REFRESH_SEQ=""; QUOTA_LAST_ERROR=""
  quota_monitor_prepare_owner || return 1

  if quota_monitor_panel_open; then
    frame=$(tmux capture-pane -t "$QUOTA_MONITOR_SESSION" -p 2>/dev/null || true)
    status=$(quota_panel_frame_status "$frame")
  else
    frame=""; status="closed"
  fi

  case "$status" in
    rate_limited|last_known|refresh_failed)
      action="retry"
      now=$(date +%s)
      quota_usage_refresh_begin "$now" "$QUOTA_MONITOR_CURRENT_ACCOUNT" \
        "$QUOTA_MONITOR_CURRENT_UUID" "$QUOTA_MONITOR_CURRENT_GENERATION" \
        "$QUOTA_MONITOR_CURRENT_LAUNCH_ID" "$mode" || return 1
      tmux send-keys -t "$QUOTA_MONITOR_SESSION" -l 'r' 2>/dev/null || {
        QUOTA_LAST_ERROR="panel:retry-key-failed"
        quota_usage_refresh_failure "$now" "retry_key_failed" 0 || true
        return 1
      }
      ;;
    refreshing)
      # 观察到前一请求仍在飞时不叠加第二个请求，也不重复消费它的旧百分比。
      QUOTA_LAST_ERROR="panel:already-refreshing"
      now=$(date +%s)
      quota_usage_refresh_begin "$now" "$QUOTA_MONITOR_CURRENT_ACCOUNT" \
        "$QUOTA_MONITOR_CURRENT_UUID" "$QUOTA_MONITOR_CURRENT_GENERATION" \
        "$QUOTA_MONITOR_CURRENT_LAUNCH_ID" "network_deferred" || return 1
      quota_usage_refresh_failure "$now" "already_refreshing" 0 || true
      quota_panel_log_observation "$(date +%s)" "$QUOTA_MONITOR_CURRENT_ACCOUNT" \
        "$QUOTA_MONITOR_CURRENT_UUID" "network_deferred" "$status" "$frame" || true
      return 1
      ;;
    *)
      action="reopen"
      if quota_monitor_panel_open && ! quota_monitor_dismiss; then
        quota_log "cannot get the composer back in the monitor session -> restarting it"
        quota_monitor_restart "$QUOTA_MONITOR_CURRENT_ACCOUNT" \
          "$QUOTA_MONITOR_CURRENT_UUID" || return 1
        QUOTA_MONITOR_CURRENT_GENERATION=$(quota_session_created "$QUOTA_MONITOR_SESSION" 2>/dev/null || true)
        QUOTA_MONITOR_CURRENT_LAUNCH_ID=$(quota_monitor_live_launch_id 2>/dev/null || true)
      fi
      if ! quota_monitor_open_usage "$QUOTA_MONITOR_CURRENT_ACCOUNT" "$QUOTA_MONITOR_CURRENT_UUID" \
          "$QUOTA_MONITOR_CURRENT_GENERATION" "$QUOTA_MONITOR_CURRENT_LAUNCH_ID" "$mode"; then
        QUOTA_LAST_ERROR="${QUOTA_LAST_ERROR:-panel:open-failed}"
        return 1
      fi
      ;;
  esac

  # 网络动作后逐秒看整张可见屏。污染状态优先于其中残留的百分比。
  for i in $(seq 1 "$QUOTA_PANEL_SAMPLE_SEC"); do
    sleep 1
    frame=$(tmux capture-pane -t "$QUOTA_MONITOR_SESSION" -p 2>/dev/null || true)
    status=$(quota_panel_frame_status "$frame")
    QUOTA_PANEL_FRAME_LAST=$frame; QUOTA_PANEL_STATUS_LAST=$status
    quota_panel_log_observation "$(date +%s)" "$QUOTA_MONITOR_CURRENT_ACCOUNT" \
      "$QUOTA_MONITOR_CURRENT_UUID" "network_sample" "$status" "$frame" || true
    case "$status" in
      refreshing|incomplete|closed) continue ;;
      rate_limited|last_known|refresh_failed)
        QUOTA_LAST_ERROR="panel:$status"
        quota_usage_refresh_failure "$(date +%s)" "$status" 1 || true
        quota_log "⚠️ /usage returned untrustworthy status $status -> whole frame with its stale percentages discarded, network cadence backed off one tier"
        return 1
        ;;
      clean) ;;
      *) continue ;;
    esac
    cur=$(quota_panel_parse "$frame" 2>/dev/null) || continue
    c_five=$(quota_panel_field "$cur" 1); c_week=$(quota_panel_field "$cur" 2)
    c_sl=$(quota_panel_field "$cur" 3); c_wl=$(quota_panel_field "$cur" 4)
    [[ "$c_five" =~ ^[0-9]+$ && "$c_week" =~ ^[0-9]+$ ]] || continue
    c_sreset=$(quota_panel_reset_epoch "$c_sl" "$QUOTA_SESSION_WINDOW_HORIZON" 2>/dev/null || echo "")
    c_wreset=$(quota_panel_reset_epoch "$c_wl" "$QUOTA_WEEK_WINDOW_HORIZON" 2>/dev/null || echo "")
    improved=0
    if [[ -z "$best" ]]; then
      improved=1
    elif quota_panel_sample_better \
           "$c_sreset" "$c_five" "$c_week" "$best_sreset" "$best_five" "$best_week" \
           "$c_wreset" "$best_wreset"; then
      improved=1
    fi
    if (( improved )); then
      best="$cur"; best_five="$c_five"; best_week="$c_week"
      best_sreset="$c_sreset"; best_wreset="$c_wreset"; no_improve=0
    else
      no_improve=$(( no_improve + 1 ))
    fi
    if (( i >= QUOTA_PANEL_MIN_SEC && no_improve >= QUOTA_PANEL_STABLE_N )); then
      got="$best"; break
    fi
  done
  [[ -z "$got" && -n "$best" ]] && got="$best"
  if [[ -z "$got" ]]; then
    QUOTA_LAST_ERROR="panel:no-stable-frame"
    quota_usage_refresh_failure "$(date +%s)" "no_stable_frame" 0 || true
    return 1
  fi

  local g_five g_week g_sl g_wl g_sr g_wr
  g_five=$(quota_panel_field "$got" 1); g_week=$(quota_panel_field "$got" 2)
  g_sl=$(quota_panel_field "$got" 3); g_wl=$(quota_panel_field "$got" 4)
  g_sr=$(quota_panel_reset_epoch "$g_sl" "$QUOTA_SESSION_WINDOW_HORIZON" 2>/dev/null || echo "")
  g_wr=$(quota_panel_reset_epoch "$g_wl" "$QUOTA_WEEK_WINDOW_HORIZON" 2>/dev/null || echo "")
  # 在 stale 判断（它可能触发一次 monitor 换代）之前先闭合采样期身份 bracket；账号若
  # 已漂移，只丢帧，不退出/重拉任何 cc。
  quota_monitor_owner_guard "panel-after" || {
    quota_usage_refresh_failure "$(date +%s)" "owner_guard_after_panel" 0 || true
    return 1
  }
  if quota_frame_stale "$QUOTA_MONITOR_CURRENT_ACCOUNT" "$g_five" "$g_week" "$g_sr" "$g_wr"; then
    QUOTA_LAST_ERROR="panel:stale-frame"
    quota_usage_refresh_failure "$(date +%s)" "stale_frame" 0 || true
    quota_log "⚠️ panel is stale relative to the confirmed reading (five=${g_five}% week=${g_week}%) -> discarded; the panel is kept for the 10s observation"
    if quota_monitor_recover_stale_frame "$mode" "$QUOTA_MONITOR_CURRENT_ACCOUNT" \
        "$QUOTA_MONITOR_CURRENT_UUID" "$g_five" "$g_week" "$g_sr" "$g_wr"; then
      return 0
    fi
    return 1
  fi
  QUOTA_PANEL_LAST="$got"
  return 0
}

# quota_monitor_restart — 保留 tmux 容器，只在原 pane 内退出并重启 cc；如果 cc 已经
# 退回 shell，则跳过 `/exit` 直接重拉。
# expected 省略时用于人工 CLI：先由账号守卫取得当前受控身份。restart 自己完成 owner 绑定，
# 调用方不得再 bind；这样 tmux 代际不变时也不会出现人工重启后 poller 再重启一次。
quota_monitor_restart() {
  local expected_email="${1:-}" expected_uuid="${2:-}"
  local launched_id="" launched_email="" launched_uuid=""
  if [[ -z "$expected_email" || -z "$expected_uuid" ]]; then
    quota_account_guard "monitor-restart-before" || return 1
    expected_email=$QUOTA_GUARD_EMAIL
    expected_uuid=$QUOTA_GUARD_UUID
  else
    # 调用方传入的是早一时刻的 bracket；在碰 UI 前再核一次，挡住采样/切号间隙的 TOCTOU。
    quota_account_guard "monitor-restart-before" "$expected_email" || return 1
    if [[ "$QUOTA_GUARD_UUID" != "$expected_uuid" ]]; then
      QUOTA_LAST_ERROR="account-guard:monitor-restart-uuid-mismatch"
      quota_log "❌ the account UUID changed before the monitor restart -> /exit not sent"
      return 1
    fi
  fi
  if quota_monitor_alive; then
    quota_monitor_single_pane_id >/dev/null || {
      quota_log "❌ a monitor restart requires a single unique pane; /exit not sent"; return 1; }
    quota_monitor_shell_ready || quota_monitor_exit_to_shell || return 1
    quota_monitor_launch_in_pane || return 1
  else
    quota_monitor_ensure || return 1
  fi
  launched_id="${QUOTA_MONITOR_STARTED_LAUNCH_ID:-}"
  launched_email="${QUOTA_MONITOR_STARTED_EMAIL:-}"
  launched_uuid="${QUOTA_MONITOR_STARTED_UUID:-}"
  [[ -n "$launched_id" ]] || {
    quota_log "❌ the monitor launch returned no launch id; refusing to bind owner"; return 1; }
  quota_monitor_bind_owner "monitor-after-restart" "$expected_email" "$expected_uuid" \
    "$launched_id" "$launched_email" "$launched_uuid"
}

