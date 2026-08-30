# shellcheck shell=bash
# lib/detect.sh — fallback UI detectors / 兜底 UI 判据
#
# Provenance: `sentinel-quota` @ e2f32279, section "三、兜底 UI 判据" (lines 2336–2426).
# 抽取来源：基线 e2f32279 的「三、兜底 UI 判据」（2336–2426 行）。
#
# ════════════════════════════════════════════════════════════════════════
# Fallback UI detectors — used only when `/usage` is unavailable. Each one can
# be exercised on its own by feeding it a text file (`quota-sentinel detect`).
# 三、兜底 UI 判据（只在 /usage 拿不到时使用；每个都可用 CLI 单独喂文本验证）
# ════════════════════════════════════════════════════════════════════════

# quota_menu_present — is the rate-limit menu currently live?
# The test is "structure + behavioural meaning", NOT "these three sentences verbatim":
#   ① no empty `❯` in the last 10 lines (a live menu has replaced the composer; a `❯`
#      present means the client is idle and what is on screen is dead text)
#   ② a footer in the last 8 lines (a live menu's footer is the pane's bottom chrome; a
#      dead scrollback copy has its footer pushed out of the window)
#   ③ "Stop and wait for limit to reset" in the last 20 lines — it describes BEHAVIOUR,
#      which is stable across versions
#   ④ at least 2 numbered items in the last 20 lines — **the wording is deliberately not
#      inspected**, because options 2 and 3 are product names and those change
#      (that is exactly the incident this whole file exists because of)
#
# quota_menu_present — 撞限选单是否活着
# 判据是「结构 + 行为语义」，不是「三条原文逐字」：
#   ① 末 10 行无空 ❯（活选单替换了 composer；有 ❯ = 客户端闲置，屏上那段是死文本）
#   ② 末 8 行有 footer（活选单的 footer 是 pane 最底 chrome；scrollback 死文本的 footer 会被顶出窗）
#   ③ 末 20 行有「Stop and wait for limit to reset」——描述行为，跨版本稳定
#   ④ 末 20 行至少有 2 个编号项——**不看文案**，因为选项 2/3 是商品名会变
# ⚠️ Every match below is a here-string, never `printf ... | grep -q`.
#    🔴 That is not style. This file runs under `set -o pipefail`, and `grep -q` exits
#    the moment it matches — which leaves the producer writing into a closed pipe, so
#    the producer dies of SIGPIPE and the PIPELINE reports 141 **even though the pattern
#    matched**. The caller then reads "no match". Measured on the extracted copy of the
#    original code: 61 misses in 800 calls (7.6%) on an idle machine, and at least one
#    miss in 9 of 10 consecutive regression runs.
#    ⭐ The symptom is a detector that intermittently reports "no menu" while a menu is
#    on screen — which is the same failure the wording-anchored detector had, arriving
#    by a different route, and it looks like load-related flakiness rather than a bug.
#    A here-string is a redirection, not a pipeline: nothing can SIGPIPE, and pipefail
#    has nothing to propagate.
# ⚠️ 下面每一处匹配都用 here-string，绝不用 `printf … | grep -q`。
#    🔴 这不是风格问题。本文件在 `set -o pipefail` 下运行，而 `grep -q` 一命中就退出，
#    上游还在往一根已关闭的管道里写 ⇒ 上游被 SIGPIPE 打死，**整条管道回报 141，尽管
#    模式明明命中了**。调用方读到的是「没匹配」。在抽取出来的同一份代码上实测：
#    800 次里错 61 次（7.6%），连续 10 轮回归里 9 轮至少错一次。
#    ⭐ 症状是判据间歇性地在「屏上有选单」时报「没有选单」——与当年那次「文案改了就哑掉」
#    是同一种后果、走的另一条路，而且看起来像负载抖动，不像缺陷。
#    here-string 是重定向不是管道：没有东西会 SIGPIPE，pipefail 也就无从传播。
quota_menu_present() {
  local t="$1" t10 t8 t20 n
  t10=$(printf '%s\n' "$t" | tail -10)
  grep -qE "$(quota_idle_cursor_regex)" <<<"$t10" && return 1
  t8=$(printf '%s\n' "$t" | tail -8)
  grep -qE "$QUOTA_MENU_FOOTER_REGEX" <<<"$t8" || return 1
  t20=$(printf '%s\n' "$t" | tail -20)
  grep -qE "$QUOTA_MENU_OPT1_REGEX" <<<"$t20" || return 1
  n=$(grep -cE "$QUOTA_MENU_NUMBERED_REGEX" <<<"$t20")
  (( n >= 2 ))
}

# quota_banner_present — detect a rate-limit banner and report how strong the evidence is.
# echoes "strict" / "weak"; return 1 = no banner at all.
#
# Why the evidence is graded: the old implementation counted a banner as a real limit hit
# whenever that sentence appeared anywhere after the last output block in the pane. The
# consequence was that **any session discussing a rate limit judged itself to be rate
# limited**. Hit live: a user QUOTED the banner text in conversation as an illustration,
# and the watcher immediately opened an episode for that session and pushed three false
# "quota restored" messages into it; another session that was busy ANALYSING rate-limit
# logs was pulled in the same way.
#
#   strict = structural evidence of a real banner: the client renders it as a `⎿` sub-line
#            (its shape after the menu is dismissed with Esc)
#   weak   = a text match only -> **must be cross-checked against /usage** before it may be
#            believed (see quota_banner_confirmed)
# Three disproofs; matching any one of them means this is NOT a banner:
#   ① the line starts with `❯` = a USER INPUT line. The client renders user messages as
#      `❯ <text>`, and whatever is being typed in the composer has the same shape. A real
#      banner is only ever a `⎿` sub-line or body text of a `●` block, and never hangs off
#      a `❯` line. The self-trigger incident above landed exactly here.
#   ② before the last top-level `●` block = an old banner already superseded by later output
#   ③ after the composer blank line = the input area at the bottom of the screen
#
# quota_banner_present — 撞限横幅检测，输出证据强度
# echo "strict" / "weak"；return 1 = 完全没有。
#
# 为什么要分强弱：旧实现只要 pane 里「最后一个 ● 块之后」出现这句话就算撞限，于是
# **任何讨论撞限的会话都会把自己判成撞限**。活体实撞：用户在对话里**引用**了那句横幅
# 原文作说明，监控当场给该会话建 episode、发了三次伪「额度已恢复」；
# 同期另一个正在分析撞限日志的会话也被同样抓进队列。
#
#   strict = 真横幅的结构证据：客户端把它渲染成 `⎿` 子行（Esc 退单后的形态）
#   weak   = 只有文本命中 → **必须与 /usage 交叉验证**才可采信（见 quota_banner_confirmed）
# 三道否证（任一命中即不是横幅）：
#   ① 横幅所在行以 `❯` 开头 = **用户输入行**。客户端把用户消息渲染成 `❯ <正文>`，
#      composer 里正在打的字也是这个形态；真横幅只会是 `⎿` 子行或 `●` 块正文，
#      永远不会挂在 `❯` 行上。上面那次自激正是撞在这里。
#   ② 在最后一个顶级 ● 块之前 = 已被后续输出盖过的旧横幅
#   ③ 在 composer 空行之后 = 屏幕最底部的输入区
quota_banner_present() {
  local t="$1"
  printf '%s\n' "$t" | awk -v re="$QUOTA_BANNER_REGEX" -v cur="$(quota_idle_cursor_regex)" '
    { if ($0 ~ /^●[[:space:]]/) lastdot=NR
      if ($0 ~ cur) lastcur=NR
      if ($0 ~ re) { lastban=NR; banline=$0 } }
    END {
      if (lastban == "") exit 1
      if (banline ~ /^[[:space:]]*❯/) exit 1              # 用户输入行，不是 客户端 的横幅
      if (lastdot != "" && lastban < lastdot) exit 1      # 旧横幅，已被新输出盖过
      if (lastcur != "" && lastban > lastcur) exit 1      # 在输入行之后
      if (banline ~ /^[[:space:]]*⎿/) { print "strict"; exit 0 }
      print "weak"; exit 0
    }'
}

# quota_banner_confirmed — 兜底路径的最终判定
# strict → 直接采信；weak → 要求 /usage 新鲜读数确认确实满了，否则不采信。
quota_banner_confirmed() {
  local t="$1" now="$2" strength snap five week
  strength=$(quota_banner_present "$t") || return 1
  [[ "$strength" == "strict" ]] && return 0
  snap=$(quota_snapshot_fresh "$now") || return 1     # 拿不到新鲜读数 → 不采信弱证据
  five=$(printf '%s' "$snap" | cut -f4)
  week=$(printf '%s' "$snap" | cut -f6)
  (( five >= QUOTA_SWITCH_PCT_FIVE || week >= QUOTA_SWITCH_PCT_WEEK ))
}

# quota_parse_reset_epoch — 从横幅文本抓 "resets 4:10pm (Asia/Shanghai)" → epoch
# Used only when no ISO timestamp is available. Time-zone handling follows one hard rule:
#   ① 括号里的 IANA 名（含 `/`）才采信
#   ① only an IANA name in parentheses (one containing `/`) is trusted
#   ② otherwise fall back to QUOTA_FALLBACK_TZ — empty means this machine's local zone
#   ③ the fallback path **self-checks that %z parses as an offset**; if it does not,
#      this is a parse failure. A value that silently degraded to UTC must never be
#      written to state.
# The earlier implementation used `date +%Z` for ② — that returns a bare abbreviation
# which glibc reads as UTC+0, so every parsed time was off by a whole offset and
# nothing reported an error.
#   ① 括号里的 IANA 名（含 `/`）才采信
#   ② 否则退到 QUOTA_FALLBACK_TZ（留空 = 本机时区）
#   ③ 兜底路径**自检 %z 能解析成偏移量**，否则判解析失败——绝不把静默回退 UTC 的值写进状态
# 旧实现在②用 `date +%Z`（返回裸缩写，被 glibc 当 UTC+0）→ 整体偏掉一个偏移量且不报错。
quota_parse_reset_epoch() {
  local text="$1" m timestr tz today epoch now
  m=$(printf '%s\n' "$text" | grep -oE "${QUOTA_RESET_TIME_REGEX}( \([A-Za-z_/+-]+\))?" | tail -1)
  [[ -z "$m" ]] && return 1
  timestr=$(printf '%s' "$m" | grep -oE '[0-9]{1,2}(:[0-9]{2})?[[:space:]]?(am|pm)')
  [[ -z "$timestr" ]] && return 1
  tz=$(printf '%s' "$m" | grep -oE '\([A-Za-z_/+-]+\)' | tr -d '()')
  if [[ -z "$tz" || "$tz" != */* ]]; then
    # No IANA zone name in the text -> fall back to QUOTA_FALLBACK_TZ (empty = this
    # machine's local zone). Self-check that we can actually resolve an offset; a
    # failure here must be a parse failure, never a silently-UTC value written to state.
    # 文本里没有 IANA 区域名 → 退到 QUOTA_FALLBACK_TZ（留空 = 本机时区）。
    # 自检必须能解析出偏移量；解析不出就判失败，绝不把静默回退 UTC 的值写进状态。
    tz="$QUOTA_FALLBACK_TZ"
    [[ "$(quota_tz_date "$tz" '+%z' 2>/dev/null)" =~ ^[+-][0-9]{4}$ ]] || return 1
  fi
  today=$(quota_tz_date "$tz" +%Y-%m-%d 2>/dev/null) || return 1
  epoch=$(quota_tz_date "$tz" -d "$today $timestr" +%s 2>/dev/null) || return 1
  [[ -z "$epoch" ]] && return 1
  now=$(date +%s)
  (( epoch <= now )) && epoch=$(( epoch + 86400 ))   # 跨午夜
  printf '%s\n' "$epoch"
}

