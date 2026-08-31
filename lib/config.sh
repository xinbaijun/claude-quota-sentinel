# shellcheck shell=bash
# lib/config.sh — configuration layer / 配置层
#
# Provenance: rewritten from `sentinel-quota` lines 45–684 @ baseline e2f32279.
# This is the ONE file in the extraction that was rewritten rather than copied:
# everything Fleet-specific lived here (root location, state root, session naming,
# account roster, tool paths). The incident notes attached to each constant are
# copied verbatim and are the reason those constants have the values they do —
# they are the product, not decoration. Real account names have been replaced with
# accountA…accountE; see docs/REDACTION.md.
#
# 抽取来源：基线 e2f32279 的 `sentinel-quota` 45–684 行。
# 这是整次抽取中唯一被**重写**而非复制的文件——所有 Fleet 专有物都在这里（根定位、
# 状态根、会话命名、账号名册、工具路径）。每个常量旁的事故注释是**原样搬过来的**，
# 它们正是这些取值的理由，是产品本身而不是装饰。真实账号名已替换为 accountA…accountE，
# 对照见 docs/REDACTION.md。

# ── Root location / 根定位 ──────────────────────────────────────────────
# Replaces sentinel-quota:45–63, which located a Fleet root and then sourced
# `fleet-env.sh` (and `prompt-transport.sh`). This project has no such ambient
# environment: it locates its own repo root and nothing else.
# 取代 sentinel-quota:45–63 的「找 Fleet 根 → source fleet-env.sh」那套。本项目没有
# 那种环境，只定位自己的仓根。
if [[ -z "${QS_ROOT:-}" ]]; then
  QS_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
fi

# ── State root / 状态根 ─────────────────────────────────────────────────
# Replaces the upstream variable at sentinel-quota:64, which pointed at the shared
# runtime directory of the environment this came from. Everything writable in this
# project hangs off this one path.
# 取代上游 sentinel-quota:64 那个变量——它指向被抽取环境的共享运行目录。
# 本项目所有可写路径都挂在这一个目录下。
QS_STATE_DIR="${QS_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/quota-sentinel}"

# sentinel-quota:65–66 defined two more variables specific to that environment.
# The first only fed its session-enumeration regex (that whole feature is not
# extracted — see docs/PROVENANCE.md "not extracted"); the second was dead code,
# assigned once and never read anywhere in the 5124-line file. Neither survives here.
# 65–66 定义的另外两个变量都是那套环境专有的：前者只服务它的会话枚举（整个功能都
# 未抽取），后者是死配置——赋值一次，全文件零引用。两个都不带过来。

# ── Monitor session / 监控会话 ──────────────────────────────────────────
# The mechanism — drive one dedicated Claude Code session that only ever types
# `/usage` — is the core of this project, not a fleet dependency. Only the
# *naming* was fleet-specific.
# 「用 tmux 驱动一个只发 /usage 的专用 客户端会话」这个机制是本项目的核心，不是 Fleet 的
# 一部分；Fleet 专有的只有命名。
#
# ⚠️ Upstream note kept, with its reason rewritten for this repo: the session name
# there deliberately carried no supervisor-parseable suffix, so the fleet's daemon
# would not adopt it — no keys sent to it, no bookkeeping row, no renaming. Here there is no
# such supervisor, but the constraint still matters for a different reason: **do not
# point this at a session you actually work in.** This session gets keys sent to it
# and gets restarted; anything else living in it will be disturbed.
# ⚠️ 上游那条注释保留，理由按本仓改写：上游名字**故意不带监督器可解析的后缀**，
#    这样就天然不被 daemon 纳管——不会被拍 Enter、不会被登记造册、不会被改名。
#    本仓没有那个监督器，但这条约束仍然要紧，只是理由变了：**别把它指向你真在用的
#    会话**。这个会话会被发按键、会被重启，里面的任何别的东西都会被打扰。
QUOTA_MONITOR_SESSION="${QUOTA_MONITOR_SESSION:-quota-monitor}"
# cwd is /tmp on purpose: starting in a project directory makes the CLI ingest that
# project's whole instruction context (measured upstream: 59s vs 15s to become
# ready). The monitor session never talks to the model, so that context is pure
# startup cost.
# cwd 用 /tmp 是有意的：在项目目录下起会吞掉整套项目上下文（上游实测 59s vs 15s）。
# 监控会话从不与模型对话，那些上下文纯属浪费启动时间。
QUOTA_MONITOR_CWD="${QUOTA_MONITOR_CWD:-/tmp}"
# Proxy: upstream hard-coded a machine-local proxy into the launch command. That is
# correct on exactly one machine and wrong everywhere else, so it is parameterised
# and **empty by default**. Set it only if your Claude Code needs a proxy.
# 代理：上游把本机代理写死在启动命令里——那在恰好一台机器上对，在别处一定错。
# 这里参数化并**默认留空**，只有你的 Claude Code 确实需要代理时才设。
QUOTA_MONITOR_PROXY="${QUOTA_MONITOR_PROXY:-}"
QUOTA_MONITOR_CMD="${QUOTA_MONITOR_CMD:-claude}"
if [[ -z "${QUOTA_MONITOR_LAUNCH:-}" ]]; then
  QUOTA_MONITOR_LAUNCH="DISABLE_AUTOUPDATER=1"
  if [[ -n "$QUOTA_MONITOR_PROXY" ]]; then
    QUOTA_MONITOR_LAUNCH+=" HTTPS_PROXY=$QUOTA_MONITOR_PROXY HTTP_PROXY=$QUOTA_MONITOR_PROXY"
  fi
  QUOTA_MONITOR_LAUNCH+=" $QUOTA_MONITOR_CMD"
fi
QUOTA_MONITOR_READY_SEC="${QUOTA_MONITOR_READY_SEC:-40}"   # max wait from launch to ready / 启动到就绪的最长等待
QUOTA_MONITOR_EXIT_SEC="${QUOTA_MONITOR_EXIT_SEC:-15}"     # max wait for /exit to return to the shell / 回到 shell 的最长等待
QUOTA_MONITOR_LAUNCH_OPTION="${QUOTA_MONITOR_LAUNCH_OPTION:-@quota_sentinel_launch_id}"
QUOTA_MONITOR_STALE_RESTART_COOLDOWN="${QUOTA_MONITOR_STALE_RESTART_COOLDOWN:-1800}"
QUOTA_MONITOR_OP_LOCK="${QUOTA_MONITOR_OP_LOCK:-$QS_STATE_DIR/quota-monitor-op.lock}"
QUOTA_MONITOR_OP_WAIT_SEC="${QUOTA_MONITOR_OP_WAIT_SEC:-60}"
# The `/usage` panel now stays open; it is no longer periodically `/clear`ed. The
# variable is kept only so old environment overrides do not break; the loop does
# not read it.
# `/usage` 面板现在常驻，不再周期性 `/clear`。保留变量只为兼容旧环境注入，主循环不消费。
QUOTA_MONITOR_CLEAR_EVERY="${QUOTA_MONITOR_CLEAR_EVERY:-0}"

# ── Thresholds and cadence / 阈值与节奏 ─────────────────────────────────
# The two thresholds were set on 2026-08-13 at five-hour 94 / weekly 99, and the
# five-hour one was later moved to 90 (see the note further down). Both numbers are
# recorded here because the later change only makes sense against the original.
# 两个阈值 2026-08-13 定为五小时 94、周 99，五小时那个后来改到 90（见下面那段）。
# 两个数都记在这里，因为后来那次改动只有对着原值才读得懂。
#
# Two windows, two thresholds, and they move in **opposite** directions:
#   The 5-hour window burns fast (measured peak 1.3%/min). Starting a switch at 94
#   leaves ~6 points of headroom, enough to notice, measure a candidate and switch
#   (one switch measured at 17s, but discovery + monitor restart + measuring the new
#   account all need room).
#   The weekly window is the reverse: give away as little as possible. By the
#   measured conversion constant 0.120, **one weekly point ≈ 8.3 five-hour points**
#   — so every point you move the weekly threshold earlier throws away 8.3 five-hour
#   points of capacity, and weekly capacity only comes back at the weekly reset. It
#   is the scarcest dimension. 99 wastes one point, and the margin is still fine:
#   1 point left ≈ 8 minutes, while a switch takes 17s and polling is every 10s.
# 两个窗口分别设阈值，且方向**相反**：
#   五小时烧得快（实测峰值 1.3%/分钟），94 起切能留约 6 点缓冲，覆盖发现与候选实测；
#   从容完成一次切号（实测一次切号 17 秒，但要留出发现、重启监控会话、量新账号的时间）。
#   周窗口相反，要留得尽量少。按实测换算常数 0.120，**1 个周额度点 ≈ 8.3 个五小时点**
#   ——周阈值每早 1 个点，就等于主动扔掉 8.3 个五小时点的产能，而周额度要等到周重置
#   才回来，是最稀缺的那一维。定 99 只浪费 1 点；安全边际仍然够：剩 1 点 ≈ 8 分钟，
#   而切号只要 17 秒，轮询 10 秒一轮也保证发现得及时。
#
# 2026-08-19: five-hour switch line 94 → 90 (accept line 93 → 89 in step).
# Cause, same day 11:40: panel read 77% at 11:35:39, then 100% at 11:40:52 — it
# stepped straight over the 94 line between two queries, the switch happened at
# 100%, and six sessions hit the wall *before* the switch. Rate-adaptive polling was
# added the same day; dropping the line another 4 points is the second margin — even
# if a round is missed again, 90 → wall is still 10 points of room.
# Cost: about 4 percentage points per account. The five-hour window heals itself in
# a few hours, so waiting on that dimension actually pays, which makes giving up
# those points worth it. The weekly window is the exact opposite — it does not come
# back — so the weekly line stays at 99.
# 2026-08-19 用户直令：五小时切换线 94 → 90（接受线同步 93 → 89）。
# 起因是当天 11:40 实撞：11:35:39 面板 77% → 11:40:52 面板 100%，两次查询之间直接
# 越过 94 线，切号发生在 100%，6 个会话在切号前就撞了墙。同日已加流速自适应缩短查询
# 间隔；把切换线再降 4 个点是第二道余量 —— 即使某次仍然漏看一轮，从 90 到撞墙也还有
# 10 个点的缓冲。
# 代价：每个账号少用约 4 个百分点。五小时窗口几小时会自己回血，这一维等待有收益，
# 所以让出这几个点是划算的（周额度就完全相反，等不回来，所以周线仍是 99）。
QUOTA_SWITCH_PCT_FIVE="${QUOTA_SWITCH_PCT_FIVE:-90}"
QUOTA_SWITCH_PCT_WEEK="${QUOTA_SWITCH_PCT_WEEK:-99}"

# off | dry-run | on.
# 🔴 The default is dry-run, and that is a deliberate choice rather than timidity. On
#    an install that has just been pointed at a machine, this tool has not yet been
#    seen to discover the right set of accounts -- and its action is to rewrite the
#    credentials of a live login. Deciding and recording without acting lets you read
#    `quota-sentinel switches` and check the decisions it WOULD have made against what
#    you would have done. Flipping to `on` is one variable, once you agree with it.
#    An automatic credential change that happens before the operator has ever seen the
#    candidate list is not a feature, it is a surprise with a rollback attached.
# off | dry-run | on。默认 dry-run 是有意为之,不是保守:刚装上时它还没被验证过能发现
#    正确的账号集合,而它的动作是改写一个在用登录的凭据。先判定、先记账、不动手,
#    你就能用 `quota-sentinel switches` 核对它「本来会怎么切」。认可之后改一个变量即可。
QUOTA_SWITCH_MODE="${QUOTA_SWITCH_MODE:-dry-run}"

# How long to stay quiet after a decision round found nowhere to switch to.
# 一轮判定发现「无处可切」之后，安静多久。
#
# 🔴 This is not a cosmetic log knob. When every in-service account is at or over a
#    line — which upstream measured as an all-day, every-day state once the roster
#    shrank to one usable account — the "nowhere to go" branch is reached on **every**
#    decision beat. Upstream that flooded the log (hundreds of lines in five minutes,
#    measured 2026-08-24 12:00). Here it would also append a ledger line every beat,
#    and the ledger is the audit trail: burying it is worse than burying the log.
#    ⚠️ Quiet is not silence forever. After this window the attempt is made again and
#    said out loud again — a gate that never reopens is much worse than a noisy one.
# 🔴 这不是个日志美观开关。当在役账号全都在线上（上游实测：名册缩到只剩一个可用账号
#    之后，这个状态天天出现、持续数小时），「无处可切」分支**每一拍**都会走到。上游那次
#    把日志刷了几百行（2026-08-24 12:00 实撞）。在本仓它还会**每拍往流水账追加一条**，
#    而流水账是审计线索——把它埋掉比把日志埋掉更糟。
#    ⚠️ 安静不是永久闭嘴：窗口过后必须重新尝试、重新出声。一道再也不打开的闸，
#    比一道吵闹的闸糟得多。
QUOTA_SWITCH_MIN_INTERVAL="${QUOTA_SWITCH_MIN_INTERVAL:-300}"

# The switch ledger. Append-only JSONL: one line per decision, including the ones that
# decided NOT to switch. See lib/switch.sh for why the non-events are recorded too.
# 切号流水账。只追加的 JSONL,每个决定一行,**包括决定不切的那些**;理由见 lib/switch.sh。
QUOTA_SWITCH_LEDGER="${QUOTA_SWITCH_LEDGER:-$QS_STATE_DIR/switches.jsonl}"

# The tool that performs the credential move. Separate process on purpose: this half
# never reads a token, which is why `ps` cannot show one during a switch.
# 真正搬凭据的工具。刻意分成独立进程:本侧从不读 token,所以切号过程中 `ps` 看不到它。
QUOTA_ACCOUNT_SWITCH_BIN="${QUOTA_ACCOUNT_SWITCH_BIN:-$QS_ROOT/account-switch}"
QUOTA_NEAR_PCT="${QUOTA_NEAR_PCT:-90}"          # at or above this, phase is recorded as `near` (a label only; it no longer changes cadence) / ≥ 此值 phase 记为 near（只是状态标记，不再影响轮询节奏）
# The local panel is sampled every 10s; the cadence that actually triggers a
# `/usage` network request is tiered by level separately.
# 本地面板固定每 10s 采样；真正触发 `/usage` 网络请求的节奏另按水位分档。
QUOTA_POLL_INTERVAL="${QUOTA_POLL_INTERVAL:-10}"
# Take whichever window is tighter: <=20% left every 60s, 21–50% every 300s,
# >50% every 600s. An unknown reading uses the tightest 60s, so that a fresh switch
# or a damaged state file does not inherit the previous account's 600s blind window.
# 两个窗口取更紧张的一维：剩余 <=20% 每 60s、21–50% 每 300s、>50% 每 600s。
# 未知读数按最紧 60s，避免刚切号/状态损坏时继承旧账号的 600s 盲窗。
QUOTA_USAGE_INTERVAL_NEAR="${QUOTA_USAGE_INTERVAL_NEAR:-60}"
QUOTA_USAGE_INTERVAL_MID="${QUOTA_USAGE_INTERVAL_MID:-300}"
QUOTA_USAGE_INTERVAL_FAR="${QUOTA_USAGE_INTERVAL_FAR:-600}"
QUOTA_USAGE_REMAINING_NEAR="${QUOTA_USAGE_REMAINING_NEAR:-20}"
QUOTA_USAGE_REMAINING_MID="${QUOTA_USAGE_REMAINING_MID:-50}"

# ── Rate adaptation / 流速自适应（2026-08-19）───────────────────────────
# The three tiers above look only at **level** (how much is left), never at **rate**
# (how fast it is climbing). Measured 2026-08-19 11:40:
#   11:35:39 panel 77%  →  11:40:52 panel 100%
# At 77% the level tier says 300 seconds, but climbing from 77% to the 94 switch line
# took 3.9 minutes — **the interval was longer than the time to the line, so missing
# it was guaranteed.** The switch happened at 100%, six sessions hit the wall first,
# and preventive switching had degraded into after-the-fact cleanup.
# Worse is the moment right after a switch: the level is necessarily 0%, which lands
# in the slowest 600-second tier — and that is exactly when burn is heaviest (a pile
# of sessions all resume at once). Measured: accountA went 0% → 100% in 15m50s.
#
# Fix: compute the climb rate from the last two readings, estimate "how long until
# the switch line", and use half of that as the next interval, taking whichever is
# smaller against the level tier. It can only shorten the interval, never lengthen
# it — the level tier remains the upper bound.
# 上面那三档只看**水位**（还剩多少），不看**流速**（涨得多快）。2026-08-19 11:40 实撞：
#   11:35:39 面板 77%  →  11:40:52 面板 100%
# 77% 时按水位判定是 300 秒一档，而从 77% 涨到切换线 94% 只要 3.9 分钟——**间隔比到线
# 时间还长，必然漏过**。结果切号发生在 100%，6 个会话在切号前就撞了墙，预防性切号
# 退化成事后补救。
# 更糟的是刚切号那一刻：水位必然是 0%，直接判成最慢的 600 秒档，而那恰恰是烧得最猛的
# 时候（一堆会话同时恢复工作）。实测 accountA 从 0% 到 100% 只用了 15 分 50 秒。
#
# 修法：按上两次读数算涨速，估出"还有多久到切换线"，用它的一半做下次间隔，并与水位档
# 取更小者。只会让间隔变短不会变长——水位档仍是上界。
QUOTA_RATE_ADAPTIVE="${QUOTA_RATE_ADAPTIVE:-1}"
QUOTA_USAGE_INTERVAL_FLOOR="${QUOTA_USAGE_INTERVAL_FLOOR:-60}"   # never go below 60s however fast it climbs / 再快也不低于 60s

# ── Estimated quota / 预估额度 ──────────────────────────────────────────
# Maintain an estimate **alongside** the real reading, to fill the gap between two
# real readings:
#     estimate = last real reading + last measured burn rate × minutes elapsed
#
# ⚠️ The extrapolation input is the **measured burn rate**, not the concurrency
#    count. Estimating from concurrency was the first proposal and the measurements
#    killed it: across three samples on 2026-08-20 concurrency was nearly identical
#    (9–10 sessions) while the burn rate differed by 7× (11.1%/min, 2.69%/min,
#    1.62%/min). A "request in flight" marker says nothing about size — a
#    million-token context request and a one-line question are not the same order of
#    magnitude — and concurrency is an instantaneous snapshot, not an interval
#    average. **Any constant k in "burn = k × concurrency" is badly wrong at one end
#    or the other.** The burn rate is measured directly and needs no calibration.
#
# ⚠️ Three guard rails: never extrapolate past QUOTA_ESTIMATE_MAX_LEAD (going past it
#    means the *query* is broken, which is a different problem and must not be
#    papered over by extrapolation); zero it immediately after a switch and after a
#    window reset (never carry the previous account's rate); the estimate only
#    operates between real readings and stands down the moment a real one arrives.
# 与真实额度**并行**维护一份预估值，填补两次真实读数之间的空窗：
#     预估 = 上次真实读数 + 上次实测烧速 × 已过去的分钟数
#
# ⚠️ 外推的输入是**实测烧速**，不是并发数。最初提议按并发数估算，实测数据否掉了
#    那个做法：2026-08-20 三段样本里并发几乎相同（9-10 个），烧速却差 7 倍
#    （11.1%/分、2.69%/分、1.62%/分）。原因是「请求在飞」标记只说明有请求在飞，
#    而一个百万上下文的大请求与一个小问答烧的量不是一个量级；并发还是瞬时快照不是
#    区间平均。任何一个「烧速 = k × 并发」的 k 都会在一端错得离谱。
#    烧速是直接量出来的，不需要标定常数。
#
# ⚠️ 三条护栏：外推不得超过 QUOTA_ESTIMATE_MAX_LEAD（超了说明查询本身出了故障，那是
#    另一回事，不该靠外推硬撑）；切号后与窗口重置后立即清零（不能带着旧账号的速度跑）；
#    预估只在真实读数之间起作用，一拿到新读数就归位。
QUOTA_ESTIMATE="${QUOTA_ESTIMATE:-1}"
QUOTA_ESTIMATE_MAX_LEAD="${QUOTA_ESTIMATE_MAX_LEAD:-180}"   # extrapolate at most 3 minutes / 最多外推 3 分钟

# ── Forced refresh / 提前触发刷新 ───────────────────────────────────────
# An over-line estimate can promote this round to "due" and query `/usage` right
# away, instead of sitting out the remaining interval.
#
# ⚠️ What it triggers is "query now", **not** "switch now" — the authoritative
#    reading still decides. The worst case of a spurious trigger is one extra API
#    call.
# ⚠️ A cooldown is mandatory. Without one, a persistent over-line condition forces a
#    network call on every 10-second local tick, and `/usage` has been rate-limited
#    before.
# 预估越线可以把本轮直接判成「到期」，立刻查一次 `/usage`，而不是干等剩下的间隔。
#
# ⚠️ 触发的是「立刻**查**」，不是「立刻**切**」——切不切仍由权威读数决定。
#    误触发的最坏后果只是多打一次接口。
# ⚠️ 必须有冷却：没有冷却，持续越线会让每个 10 秒本地轮都强制触网一次，
#    而 `/usage` 被限流过。
QUOTA_FORCE_REFRESH="${QUOTA_FORCE_REFRESH:-1}"
QUOTA_FORCE_REFRESH_COOLDOWN="${QUOTA_FORCE_REFRESH_COOLDOWN:-60}"

# Usable window for the reading cached in `.claude.json`. The main path no longer
# uses it (the main path reads live values off the panel); it serves one
# cross-check on the fallback path. That file is written on Claude Code's own
# schedule (measured 5–9 minutes between writes), so this window must be generous
# — otherwise the fallback path never has a "usable" reading and weak evidence is
# never accepted.
# `.claude.json` 读数的可用窗口。主路已经不用它了（主路从面板取实时值），它只服务于
# 兜底路径的一处交叉验证。那份 JSON 是 客户端 自己的落盘节奏（实测两次写入间隔 5-9 分钟），
# 所以这个窗口必须给得宽，否则兜底路径永远拿不到"可用"的读数、弱证据一律不采信。
QUOTA_FETCH_MAX_AGE="${QUOTA_FETCH_MAX_AGE:-900}"

# ── Panel sampling / 面板采样参数 ───────────────────────────────────────
# (measured live 2026-08-11 / 08-13)
#   REFRESH_DELAY — kept for compatibility; a failed panel has already been resident
#                   far longer than 2s before the `r` retry, and a healthy panel
#                   re-issues the network request by reopening `/usage` (the clean
#                   panel in Claude Code 2.1.226 has no `r` action).
#   MIN_SEC — wait at least this long before collecting. Measured: at +1s the panel
#             still shows the **previous account's** cached value; only at +2s does
#             it refresh to the current account's live value. Trusting the first
#             frame after a switch inverts the switch decision completely.
#   STABLE_N — require N consecutive identical samples, to avoid reading a
#              half-rendered frame mid-refresh.
#   SAMPLE_SEC — sampling ceiling; past it, treat the round as "did not read" and retry.
# 面板采样参数（按 2026-08-11/13 活体实测定）：
#   REFRESH_DELAY —— 保留兼容；失败面板的 r 重试前至少已常驻远超 2s，正常面板则靠重开
#                    `/usage` 发起网络请求（Claude Code 2.1.226 的 clean 面板没有 r action）。
#   MIN_SEC —— 至少等这么久再收数。实测面板 +1s 显示的是**上一个账号**的缓存值，
#              +2s 才刷成当前账号的实时值。切号后若采信第一帧，切号判断会彻底反向。
#   STABLE_N —— 要求连续 N 次采样完全一致，防止读到刷新过程中的半截画面。
#   SAMPLE_SEC —— 采样上限，超了就当这次没读到、重试。
QUOTA_PANEL_REFRESH_DELAY="${QUOTA_PANEL_REFRESH_DELAY:-2}"
QUOTA_PANEL_MIN_SEC="${QUOTA_PANEL_MIN_SEC:-6}"
QUOTA_PANEL_STABLE_N="${QUOTA_PANEL_STABLE_N:-2}"
QUOTA_PANEL_SAMPLE_SEC="${QUOTA_PANEL_SAMPLE_SEC:-20}"
# The cached frame and the refreshed frame of `/usage` round the same reset time
# differently. Observed live: 3:59/4:00, 1:59/2:00; the user later confirmed a
# few minutes of difference within the same window also happens. Tolerance is set
# at 5 minutes; a genuine window change jumps by ~5h/7d, far larger. Inside the
# tolerance the percentage-monotonicity check still applies, so a lower cached value
# is not let through.
# `/usage` 的缓存帧与刷新帧会对同一个 reset 采用不同缓存/取整口径。最初活体看到
# 3:59/4:00、1:59/2:00；用户随后确认同窗相差几分钟也会发生。容差定为 5 分钟；
# 真正换窗会跳约 5h/7d，远大于该值。容差内仍须通过百分比单调性，低值缓存不会放行。
QUOTA_RESET_DISPLAY_SKEW="${QUOTA_RESET_DISPLAY_SKEW:-300}"

# ── Runtime globals / 运行时全局变量 ────────────────────────────────────
QUOTA_PANEL_LAST=""    # last successfully read panel values (session_pct\tweek_pct\tsession_resets\tweek_resets) / 最近一次成功读到的面板值
QUOTA_PANEL_FRAME_LAST=""       # last visible-screen text (observation log only) / 最近一次可见屏原文（只用于逐次观测日志）
QUOTA_PANEL_STATUS_LAST=""      # clean/refreshing/rate_limited/last_known/refresh_failed/...
QUOTA_REFRESH_SEQ=""            # this round's network refresh sequence number / 本轮网络刷新序号
QUOTA_GUARD_EMAIL=""   # attribution confirmed by the most recent quota_account_guard, from the **same snapshot** / 最近一次守卫**同一快照**确认过的归属
QUOTA_GUARD_UUID=""

# ── Account roster / 账号名册 ───────────────────────────────────────────
# Two lists with completely different handling:
#
# Retired = subscription expired / credentials revoked; **will not come back**. They
# should hold no position at all: not offered as switch candidates, not counted in
# the denominator of "do we know every account's reset time", not counted toward the
# minimum-accounts gate, not probed by default (saves a request that is certain to
# 401), and listed in their own section when displayed.
# Paused = manually stood down for now, will return. Also excluded from candidates
# and from the denominator, but semantically reversible.
#
# ⚠️ The account-switching tool still reports these accounts as "has usable
#    credentials | subscription=max" — that only means the file parses, and
#    `subscription` is a locally cached field. **That tool cannot tell that an
#    account is dead.** Retired status can only be recorded by us, from probe
#    evidence.
#
# ⚠️ Before 2026-08-21 there was one list only, and it applied **only at candidate
#    selection**. Consequence: accountA/accountB were correctly skipped as
#    candidates, yet still counted in the denominator of the all-exhausted check;
#    that logic requires "every account has a usable reset time", those two had not
#    updated in 28 hours, so the set never completed, and on a full exhaustion the
#    system would only log "reset ledger incomplete → will not guess a wait time"
#    and then sit. The 14:49–15:17 stall that day was exactly this, and it took a
#    manual switch to clear.
#
# ⚠️ This is a **hand-maintained** list, not an auto-probe result. When an account
#    recovers you must delete it from here by hand, or it stays excluded forever.
# ⚠️ It applies **only to picking candidates**, never to the current account: if the
#    account you are on is on the list (e.g. just revoked), the normal switch-away
#    flow must still run rather than jam.
#
# ⚠️ **Defaults are empty on purpose.** Upstream these defaulted to a real roster of
#    real account addresses. A roster is per-deployment data, not code; put yours in
#    the environment, not in this file. Format is space-separated addresses, e.g.
#    `QS_RETIRED_ACCOUNTS="accountA@example.com accountD@example.com"`.
#
# 分「退役」与「暂停」两类，处置完全不同：
#
# 退役 = 订阅到期 / 凭据被吊销，**不会恢复**。它们不该再占任何位置：
#   不进候选、不算进「是否每个账号都知道重置时刻」的分母、不算进最少账号数、
#   probe 默认不查（省一次必然 401 的请求）、展示时单列一节。
# 暂停 = 人工临时停用，之后还会回来。同样不进候选、不算分母，但语义上是可逆的。
#
# ⚠️ 切号工具对这两类账号仍显示「✅ 有可用凭据 | subscription=max」——那只表示文件
#    读得出、格式对，subscription 也是本地缓存。**那个工具分辨不出账号已经死了**，
#    所以退役状态只能由我们按 probe 的实测证据登记。
#
# ⚠️ 2026-08-21 之前只有一张名单，而且**只在候选筛选处生效**。后果是
#    accountA/accountB 被正确跳过了候选，却仍算在全耗尽判定的分母里；
#    那段逻辑要求「每个账号都有可用重置时刻」，这俩 28 小时没更新，于是永远凑不齐，
#    于是全撞限时只会打「ready_at 台账不完整 → 不猜等待时间」然后干等。
#    当天 14:49–15:17 的停摆就是这么来的，最后靠用户手动切号解开。
#
# ⚠️ 这是一份**人工维护**的名单，不是自动探测结果。账号恢复后必须手工删掉，
#    否则它会被永久排除。
# ⚠️ 只用于**挑候选**，不影响当前账号：万一当前账号在名单里（比如刚被吊销），
#    正常的切号流程仍然要把它切走，而不是卡住。
#
# ⚠️ **默认值刻意留空。** 上游这两个变量的默认值是一份真实账号地址名册。名册是
#    每个部署自己的数据，不是代码；请写进环境变量，不要写进本文件。
#    格式是空格分隔的地址，例如
#    `QS_RETIRED_ACCOUNTS="accountA@example.com accountD@example.com"`。
QUOTA_RETIRED_ACCOUNTS="${QUOTA_RETIRED_ACCOUNTS:-${QS_RETIRED_ACCOUNTS:-}}"
QUOTA_DISABLED_ACCOUNTS="${QUOTA_DISABLED_ACCOUNTS:-${QS_PAUSED_ACCOUNTS:-}}"

# ── Account identity guard / 账号身份守卫 ───────────────────────────────
# A non-cooperating writer of the shared config file cannot be locked out by the
# switching tool's own flock. The guard therefore keeps the last confirmed
# email+UUID as a persistent expectation and re-reads it at every decision
# boundary; while a drift persists it repeats the log line only this often.
# 共享配置文件的非协作 writer 无法靠切号工具自己的 flock 挡住。守卫把最近一次已确认
# 的 email+UUID 当持久期望值，每个决策边界都重读；漂移持续时只按此间隔重复打日志。
#
# 🔴 This line was **missing** between the extraction milestone and 2026-08-28, while
#    lib/state.sh already read it. Under `set -u` (which the CLI sets) an undefined
#    variable is not a warning — the shell exits. So the tool died outright on the
#    first external account drift it detected: the one path whose entire purpose is
#    to notice that somebody else changed the account. Nothing was green-and-wrong;
#    there was simply no test that reached that branch, because reaching it needs a
#    state file and a config file that disagree. The regression case that now covers
#    it is "account guard: an unset drift-log interval must not kill the process".
# 🔴 抽取里程碑之后到 2026-08-28 之间**缺了这一行**，而 lib/state.sh 已经在读它。
#    在 `set -u` 下（CLI 就设了）未定义变量不是警告，是**整个进程退出**。于是这工具
#    一旦检测到外部切号就当场死掉——而那条路径存在的全部意义正是「发现别人改了账号」。
#    没有任何判据变绿说谎，只是压根没有用例走到那个分支：走到它需要状态文件与配置文件
#    互相矛盾。现在覆盖它的用例是「账号守卫：漂移日志间隔未定义时不得杀死进程」。
QUOTA_ACCOUNT_DRIFT_LOG_INTERVAL="${QUOTA_ACCOUNT_DRIFT_LOG_INTERVAL:-300}"

# ── Cross-account quota snapshot / 账号额度快照 ─────────────────────────
# (produced by `account-probe --snapshot`; this script only reads it)
#
# The gap it closes: the quota of any *other* account is only knowable by switching
# to it. In the 2026-08-21 full-exhaustion event the ledger held a 2.9-hour-old
# reading for one account and 28-hour-old readings for two others, so it could
# neither rank a candidate nor compute a wait-until time. The snapshot queries each
# account read-only with that account's own token, without switching.
#
# ⚠️ Currently **shadow: accounted only, never used in any decision.** The reason:
#    all existing consistency evidence (≤2 points apart within ±60s, 98% success)
#    comes from shadow sampling of the **current** account. Querying **other**
#    accounts is a different code path (different token, different credentials
#    file) and only a handful of manual probes support it. Let it run for a while,
#    reconcile against "what the panel actually reads after switching there", and
#    only then consider promoting it. The release switch is QUOTA_SNAPSHOT_DECIDE,
#    default 0.
#
# 解决的是这个缺口：其他账号的额度**只有切过去才知道**。2026-08-21 全撞限那次，
# 台账里一个账号的读数是 2.9 小时前的、另两个是 28 小时前的，于是既排不出可靠候选，
# 也算不出该等到几点。快照用各账号自己的 token 只读查，不必切号。
#
# ⚠️ 现阶段 **shadow：只记账、不参与任何决策**。理由是已有的一致性证据（±60s 内
#    差 ≤2 点、98% 成功率）全部来自**当前账号**的影子采样；查**其他**账号是另一条
#    代码路径（不同 token、不同凭据文件），只有几次手动 probe 的证据。先跑一段、
#    与「真切过去之后面板读到的值」对账，确认一致再考虑放行。
#    放行开关是 QUOTA_SNAPSHOT_DECIDE，默认 0。
QUOTA_SNAPSHOT_FILE="${QUOTA_SNAPSHOT_FILE:-$QS_STATE_DIR/account-quota-snapshot.json}"
QUOTA_SNAPSHOT_MAX_AGE="${QUOTA_SNAPSHOT_MAX_AGE:-900}"   # older than 15 minutes counts as absent / 超过 15 分钟就当没有
QUOTA_SNAPSHOT_DECIDE="${QUOTA_SNAPSHOT_DECIDE:-0}"       # 0 = account only, 1 = participate in decisions / 0=只记账 1=参与决策
QUOTA_SNAPSHOT_TOOL="${QUOTA_SNAPSHOT_TOOL:-$QS_ROOT/account-probe}"

# Do not query when nothing is happening (nobody is using the other accounts, their
# quota does not move, and you would read the same number); tighten to 180s only
# when an account has just passed its reset time and no post-reset reading has
# arrived yet.
# 平时不查（非当前账号没人用，额度不会动，查了也是同一个数）；
# 只在「有账号刚过回血时刻、还没查到新数」时收紧到 180s。
QUOTA_SNAPSHOT_IDLE_INTERVAL="${QUOTA_SNAPSHOT_IDLE_INTERVAL:-3600}"
QUOTA_SNAPSHOT_WATCH_INTERVAL="${QUOTA_SNAPSHOT_WATCH_INTERVAL:-180}"   # API floor; faster than this gets rate-limited / 接口下限，比这更快会被限流
QUOTA_SNAPSHOT_REFRESH_INTERVAL="${QUOTA_SNAPSHOT_REFRESH_INTERVAL:-}"  # if set, used verbatim, overriding both tiers above / 设了就固定用它，覆盖上面两档

# ── Paths / 路径 ────────────────────────────────────────────────────────
QUOTA_STATE="${QUOTA_STATE:-$QS_STATE_DIR/quota-state.json}"
QUOTA_LOG="${QUOTA_LOG:-$QS_STATE_DIR/quota.log}"
QUOTA_LOCK_DIR="${QUOTA_LOCK_DIR:-$QS_STATE_DIR/lock}"
# Every 10s local sample leaves one structured record here: the parsed percentages, the
# account it belongs to, the cadence in force, and a sha256 of the visible screen.
# ⚠️ The visible screen ITSELF is not stored by default — see QUOTA_PANEL_TEXT_CAPTURE.
# 每次 10s 本地采样在这里留一条结构化记录：解析出的百分比、所属账号、当时的节奏，
# 以及可见屏的 sha256。⚠️ **可见屏原文默认不存**，见下面的 QUOTA_PANEL_TEXT_CAPTURE。
QUOTA_PANEL_OBSERVATIONS="${QUOTA_PANEL_OBSERVATIONS:-$QS_STATE_DIR/quota-panel-observations.jsonl}"
QUOTA_PANEL_OBSERVATIONS_LOCK="${QUOTA_PANEL_OBSERVATIONS_LOCK:-$QS_STATE_DIR/quota-panel-observations.lock}"

# 🔴 QUOTA_PANEL_TEXT_CAPTURE — off by default, and the default is the whole point.
#
# The sampler gets its numbers from `tmux capture-pane -p`, which returns **the entire
# visible pane**, not the four lines it is about to parse. Writing that verbatim to disk
# means the file contains whatever that session had on screen at the time. In the
# environment this was extracted from the monitored session only ever runs `/usage`, so
# the frames only ever held quota numbers — ⭐ but that is a property of **how we happen
# to run it**, not of this tool. Point it at a session that shows anything else and that
# is what gets recorded: every 10 seconds, kept for a week, in a file the person running
# it has no particular reason to know exists.
# ⇒ Default: the sha256 plus the parsed fields. The raw text is an explicit debugging
#   opt-in, set to 1 for the window you are investigating and back to 0 afterwards.
#
# What the default COSTS you, stated rather than quietly dropped: after the fact you can
# no longer answer "what did the screen actually look like at 03:14". You can still answer
# "were these two frames identical" (the sha256 — and that is the question a stuck/cached
# panel investigation actually turns on) and "which known-bad shape was it" (`status`).
# What you lose is the unclassified shape: a frame nobody has written a detector for yet
# is unrecoverable once the moment has passed.
#
# ⚠️ If you do turn it on, lower QUOTA_PANEL_RETENTION_SEC with it. Two measurements,
#    each with its own scope, because the ratio between them depends on YOUR pane:
#      · with capture ON, on the host this was extracted from, 2026-08-31, 10s sampling
#        and the 7-day retention below: 247 MB across 73,828 records ≈ 3.3 KB per record;
#      · with the default (capture OFF), from a synthetic 7-line frame here: ≈ 0.56 KB
#        per record.
#    ⇒ ≈ 6× at that host's frame size. ⭐ Not "an order of magnitude" — the multiple is
#      whatever your pane is, since only the panel_text part grows with it. And the first
#      number is one host, one configuration, one panel layout: sample your own file
#      before assuming either transfers.
#    ⚠️ Provenance of the first figure, stated so it is not mistaken for a local result:
#      it is **an observation from a different machine, relayed into this repo, not
#      measured in it**. Only the ≈ 0.56 KB beside it was measured here.
#    🔴 Why this number stays although other measurements from that host were removed —
#      written down so nobody re-litigates it in either direction. What was removed was a
#      **security posture** (is `hidepid` on, how many local accounts, are addresses
#      sitting in `argv`): publishing that describes one machine's weakness and helps no
#      reader. **This one is the reason the default exists.** Without a measured size,
#      "storing the whole screen adds up" is an assertion, and a default with no evidence
#      behind it is the first thing someone flips back. It is a capacity observation, it
#      exposes no weakness, and it already carries its scope.
#      ⇒ Do not delete it as "a number from their host", and do not take it as licence to
#        add new site measurements next to it.
#
# 🔴 QUOTA_PANEL_TEXT_CAPTURE —— 默认关，而**默认值本身就是这条的全部意义**。
#
# 采样靠 `tmux capture-pane -p` 取数，它返回的是**整个可见 pane**，不是它接下来要解析的
# 那四行。把它原样落盘，意味着磁盘上那份文件里装着当时那个会话屏幕上的任何东西。在本仓
# 被抽取出来的那套环境里，被监控会话只跑 `/usage`，所以帧里只有额度数字——⭐ 但那是
# **我们碰巧这么用**的性质，不是这个工具的性质。谁把它指向一个显示别的东西的会话，被记下
# 来的就是别的东西：每 10 秒一次、留一周，写在一个他没什么理由知道其存在的文件里。
# ⇒ 默认只存 sha256 与解析后的字段；原文改成显式的调试开关：排查期间置 1，查完置回 0。
#
# 默认关**的代价**（写出来，不是悄悄丢掉）：事后你回答不了「03:14 那一屏究竟长什么样」。
# 你仍然回答得了「这两帧是不是同一帧」（靠 sha256——而「面板卡住/缓存」这类排查真正依赖的
# 就是这一问）和「它是哪一种已知坏形态」（靠 `status`）。丢掉的是**尚未被分类的形态**：
# 还没人给它写过检测器的那种帧，时刻一过就找不回来了。
#
# ⚠️ 真要打开，请连同 QUOTA_PANEL_RETENTION_SEC 一起调小。两个数，各带各的口径——
#    因为两者的比例取决于**你的** pane：
#      · capture **开**：本仓被抽取出来的那台宿主，2026-08-31，10s 采样、下面这个 7 天
#        保留 —— 247 MB / 73,828 条 ≈ 每条 3.3 KB；
#      · **默认**（capture 关）：本仓用一帧 7 行的合成夹具实测 ≈ 每条 0.56 KB。
#    ⇒ 在那台宿主的帧尺寸下约 **6 倍**。⭐ 不是「一个数量级」——倍数就是你的 pane 有多大，
#      因为只有 panel_text 那部分随它增长。而且前一个数是一台宿主、一套配置、一种面板排版：
#      在假定其中任何一个对你也成立之前，先量一下你自己那份文件。
#    ⚠️ 前一个数的来源，写明以免被当成本地实测：它是**另一台机器上的观测、转述进本仓的，
#      不是在本仓量的**。旁边那个 ≈ 0.56 KB 才是本仓实测。
#    🔴 为什么同一台宿主的别的实测被拿掉了、这个数却留着——写下来，免得以后有人往两个方向
#      任意重判。拿掉的那些是**安全姿态**（有没有开 `hidepid`、有几个本地账号、`argv` 里有
#      没有地址）：公开它们等于描述某一台机器的弱点，而且对读者没有用。
#      **这一个是「这个默认值为什么存在」的实证支撑。** 没有一个量过的尺寸，
#      「存整屏会攒起来」就只是一句断言，而一个背后没有证据的默认值，是最先被人翻回去的
#      那一个。它是容量观测、不暴露弱点，而且口径已经标在旁边。
#      ⇒ 既不要把它当成「他们那台机器上的数」删掉，也不要拿它当作可以在旁边再加新现场数的
#        许可证。
QUOTA_PANEL_TEXT_CAPTURE="${QUOTA_PANEL_TEXT_CAPTURE:-0}"
# Observations are kept seven days; the structured source results and quota.log
# are unaffected. Pruning runs at most once a day, so the physical retention ceiling
# is about eight days — this stops the 10s sampling cadence from repeatedly scanning
# a file that reaches ~200MiB once mature **with QUOTA_PANEL_TEXT_CAPTURE on**
# (that is where the measured 247 MB / 73,828 records above comes from).
# ⚠️ The seven days were deliberately NOT shortened when the capture default was turned
# off, and the reason is worth writing down rather than re-deriving later: with the
# default, 10s sampling produces ≈ 8,640 records/day × ≈ 0.56 KB ≈ 4.8 MB/day, so seven
# days is ≈ 34 MB and the ~8-day physical ceiling is ≈ 41 MB. The structured record is
# also the half that has downstream value (multi-source time alignment spans days).
# ⇒ Shortening the window would give up the cheap, useful half to save nothing. Lower it
#   for the window you have capture ON, not as a new default.
# The stamp defaults to a path derived from the observations path, so that rebinding
# the main file in a test or from outside does not touch the production sidecar.
# 观测记录只保留最近七天；结构化 source 结果与 quota.log 不受影响。清理每天最多一次，
# 因此物理保留上界约八天，避免 10s 采样节奏反复扫描成熟后约 200MiB 的大文件——
# ⚠️ 那个 200MiB 是 **QUOTA_PANEL_TEXT_CAPTURE 打开时**的量级（即上面 247 MB / 73,828
# 条那次实测）。
# ⚠️ 把 capture 默认关掉时，这七天**刻意没有跟着调短**，理由写下来而不是留给以后重新推：
# 默认下 10s 采样 ≈ 每天 8,640 条 × ≈ 0.56 KB ≈ 4.8 MB/天 ⇒ 七天 ≈ 34 MB，约八天的物理
# 上界 ≈ 41 MB。而结构化记录恰好是**下游真正有用**的那一半（多来源按时间对齐要跨天）。
# ⇒ 调短窗口等于放弃便宜又有用的那一半、却什么也没省下。要调，就调**你开着 capture 的
#   那一段**，不要把它变成新的默认。
# stamp 默认跟随 observations 路径派生，测试/外部重绑主文件时不会误碰生产 sidecar。
QUOTA_PANEL_RETENTION_SEC="${QUOTA_PANEL_RETENTION_SEC:-604800}"
QUOTA_PANEL_PRUNE_INTERVAL="${QUOTA_PANEL_PRUNE_INTERVAL:-86400}"
QUOTA_PANEL_PRUNE_STAMP="${QUOTA_PANEL_PRUNE_STAMP:-}"

# ── Shadow quota sampling (observe only, never decides) / 影子额度采样 ──
# A four-stage experiment steps the interval every 10 minutes: 20s → 40s → 60s →
# 120s, then holds at 120s. The statusLine local callback wakes every 20s and is
# throttled by ingest according to the current stage; only OAuth issues a real
# network request. Separate files and a separate lock are a hard boundary: a shadow
# writer never concurrently modifies QUOTA_STATE.
# 四阶段实验每 10 分钟换档：20s → 40s → 60s → 120s，之后保持 120s。
# statusLine 的本地 callback 固定每 20s 唤醒，由 ingest 按当前阶段节流；OAuth 才会真实
# 发网络请求。独立文件与独立锁是硬边界：影子 writer 绝不并发改 QUOTA_STATE。
QUOTA_SHADOW_ENABLED="${QUOTA_SHADOW_ENABLED:-1}"
# ── OAuth direct query: re-enabled 2026-08-21 as a third, record-only source ──
# Disabled 2026-08-13 on measurement (25 of 28 rate_limited, 7% success; ⚠️ note it
# was already backed off to one query per 10 minutes and still got limited, so
# "interval too short" does not explain that failure).
# Re-evaluated 2026-08-21 with a controlled experiment: healthy token, 180s
# interval, 7 rounds, the two arms using tokens from **different accounts** (rate
# limiting is per access token, so running both arms on one token cross-contaminates
# them):
#     with User-Agent    7/7 success
#     without User-Agent 7/7 success
# ⇒ ① "180 seconds is safe" holds; ② "it works because of the User-Agent header"
#    does **not** hold — it passed without one too. The UA is still sent (it matches
#    the official client and is harmless), but it is not the cause.
#
# ⚠️ Those 25 failures on 08-13 remain **unexplained** (was the machine/IP limited at
#    the time? did a server-side policy change? was the implementation different
#    then?) — there is no evidence for any of those. Something you cannot explain can
#    recur, therefore:
#   · interval raised to 180 seconds (the measured-safe value), no longer 120
#   · the existing 429 backoff (penalty_interval/penalty_until) is left alone
#   · decision_eligible stays hard-coded false — **this source collects and logs
#     only; it never participates in switching.** Promoting it to a decision source
#     requires proving from these logs that it beats `/usage`, not "it worked today".
#
# 2026-08-13 因实测被停用（28 条里 25 次 rate_limited，成功率 7%；⚠️ 注意当时已退避到
# 10 分钟一次仍被限，所以「间隔太短」解释不了那次失败）。
# 2026-08-21 做了对照实验重新评估：正常 token、180 秒间隔、7 轮、两臂各用不同账号的
# token（限流按 access token 算，同一 token 跑两臂会互相污染）：
#     带 User-Agent   7/7 成功
#     不带 User-Agent 7/7 成功
# ⇒ ①「180 秒间隔安全」成立；②「靠 User-Agent 头」**不成立**，不带也全通。
#    UA 仍然带上（与官方客户端一致，无害），但它不是原因。
#
# ⚠️ 08-13 那 25 次至今**没有解释**——我没有证据支持任何一个猜测。解释不了的事不代表
#    不会再发生，所以：间隔提到 180 秒；原有 429 退避保持不动；decision_eligible 仍
#    硬编码 false —— **本轮只采集、只入 log，绝不参与切号**。
QUOTA_SHADOW_OAUTH_ENABLED="${QUOTA_SHADOW_OAUTH_ENABLED:-1}"
QUOTA_SHADOW_STAGE_SECONDS="${QUOTA_SHADOW_STAGE_SECONDS:-600}"
QUOTA_SHADOW_OAUTH_INTERVAL="${QUOTA_SHADOW_OAUTH_INTERVAL:-180}"
QUOTA_SHADOW_OAUTH_URL="${QUOTA_SHADOW_OAUTH_URL:-https://api.anthropic.com/api/oauth/usage}"
QUOTA_SHADOW_OAUTH_STATE="${QUOTA_SHADOW_OAUTH_STATE:-$QS_STATE_DIR/quota-oauth-shadow-state.json}"
QUOTA_SHADOW_OAUTH_EVENTS="${QUOTA_SHADOW_OAUTH_EVENTS:-$QS_STATE_DIR/quota-oauth-shadow-events.jsonl}"
QUOTA_SHADOW_OAUTH_LOCK="${QUOTA_SHADOW_OAUTH_LOCK:-$QS_STATE_DIR/quota-oauth-shadow.lock}"
QUOTA_SHADOW_PIDFILE="${QUOTA_SHADOW_PIDFILE:-$QS_STATE_DIR/quota-shadow-poller.pid}"
# The UA matches the official client. Per the controlled experiment above it is NOT
# what makes the request succeed — it is sent because matching the official client is
# harmless and consistent, not because it is load-bearing. Do not cite it as a fix.
# UA 与官方客户端一致。按上面那次对照实验，它**不是**请求成功的原因——带上它只是因为
# 与官方客户端一致且无害，不是因为它承重。别把它当成一条修复来引用。
QUOTA_SHADOW_OAUTH_UA="${QUOTA_SHADOW_OAUTH_UA:-claude-code/2.1.226}"
QUOTA_SHADOW_OAUTH_CONNECT_TIMEOUT="${QUOTA_SHADOW_OAUTH_CONNECT_TIMEOUT:-5}"
QUOTA_SHADOW_OAUTH_MAX_TIME="${QUOTA_SHADOW_OAUTH_MAX_TIME:-12}"
QUOTA_CREDENTIALS_FILE="${QUOTA_CREDENTIALS_FILE:-$HOME/.claude/.credentials.json}"
QUOTA_SHADOW_STATUSLINE_REFRESH="${QUOTA_SHADOW_STATUSLINE_REFRESH:-20}"
QUOTA_SHADOW_STATUSLINE_STATE="${QUOTA_SHADOW_STATUSLINE_STATE:-$QS_STATE_DIR/quota-statusline-shadow-state.json}"
QUOTA_SHADOW_STATUSLINE_EVENTS="${QUOTA_SHADOW_STATUSLINE_EVENTS:-$QS_STATE_DIR/quota-statusline-shadow-events.jsonl}"
# Where the statusLine collector is told WHICH account/generation it belongs to.
# It is a file rather than four command-line arguments for one reason: the arguments
# would sit in the `--settings` JSON on the monitor CLI process, and that process lives
# for the whole session -- so an account address would be readable in
# `/proc/<pid>/cmdline` continuously, not for the microseconds a `jq` call lasts.
# The launch id in the name is not sensitive; the file is written 0600.
# statusLine 采集器从哪里得知「自己属于哪个账号/哪一代」。用文件而不是四个命令行参数，
# 理由只有一个：那四个参数会待在 monitor CLI 进程的 `--settings` JSON 里，而那个进程
# **活整个会话** ⇒ 账号地址会持续可从 `/proc/<pid>/cmdline` 读到，不是一次 jq 调用的
# 那几微秒。文件名里的 launch id 不敏感；文件按 0600 写。
QUOTA_SHADOW_STATUSLINE_OWNER_DIR="${QUOTA_SHADOW_STATUSLINE_OWNER_DIR:-$QS_STATE_DIR/statusline-owner}"
QUOTA_SHADOW_STATUSLINE_LOCK="${QUOTA_SHADOW_STATUSLINE_LOCK:-$QS_STATE_DIR/quota-statusline-shadow.lock}"
QUOTA_SHADOW_SCHEDULE_STATE="${QUOTA_SHADOW_SCHEDULE_STATE:-$QS_STATE_DIR/quota-shadow-schedule.json}"
QUOTA_SHADOW_SCHEDULE_LOCK="${QUOTA_SHADOW_SCHEDULE_LOCK:-$QS_STATE_DIR/quota-shadow-schedule.lock}"
# One unified per-sample ledger for all three sources: `/usage` success frames,
# OAuth success/failure, and statusLine success/missing-field all land here.
# 三方统一逐次账：/usage 成功帧、OAuth 成功/失败、statusLine 成功/缺字段均进入这里。
QUOTA_SOURCE_EVENTS="${QUOTA_SOURCE_EVENTS:-$QS_STATE_DIR/quota-source-samples.jsonl}"
QUOTA_SOURCE_EVENTS_LOCK="${QUOTA_SOURCE_EVENTS_LOCK:-$QS_STATE_DIR/quota-source-samples.lock}"

# ── Regexes for the fallback UI detectors / 兜底 UI 判据用的正则 ────────
# Empty `❯` composer line. Claude Code actually renders `❯<NBSP> `, and POSIX
# [[:space:]] does not include NBSP → use [^[:alnum:]].
# 空 ❯ composer 行。客户端 实际渲染 `❯<NBSP> `，POSIX [[:space:]] 不含 NBSP → 用 [^[:alnum:]]。
QUOTA_IDLE_CURSOR_DEFAULT='^[^[:alnum:]]*❯[^[:alnum:]]*$'
# The menu detector anchors on **option 1 only**: it describes a behaviour (stop and
# wait for the reset), which is stable across versions. Options 2/3 describe products
# (Switch to usage credits / Upgrade your plan / Upgrade to Team plan) and change
# with the pricing packaging — the earlier implementation anchored the literal
# `2. Switch to usage credits`, and when the wording changed the whole branch went
# silent for 28 days.
# 选单只锚**选项 1**：它描述行为（停下来等重置），跨版本稳定。
# 选项 2/3 描述商品，随定价包装变——旧实现逐字锚 `2. Switch to usage credits`，
# 客户端 改文案后整条分支哑了 28 天。
QUOTA_MENU_OPT1_REGEX="${QUOTA_MENU_OPT1_REGEX:-Stop and wait for limit to reset}"
QUOTA_MENU_FOOTER_REGEX="${QUOTA_MENU_FOOTER_REGEX:-Enter to confirm.*Esc to cancel}"
QUOTA_MENU_NUMBERED_REGEX="${QUOTA_MENU_NUMBERED_REGEX:-^[[:space:]]*(›|❯|>)?[[:space:]]*[0-9]+\.[[:space:]]}"
# ⚠️ A regex containing a `{n,m}` interval quantifier **cannot** go in the default
# of `${VAR:-default}`: inside a default value bash ends parameter expansion at the
# first unescaped `}`, so `You.{0,3}ve …` gets cut into `You.{0,3ve …}`.
# This was a real bug, found on the first run of the upstream test suite — hence the
# explicit `if` assignment.
# ⚠️ 含 {n,m} 区间量词的正则**不能**写进 ${VAR:-默认} 的默认值里：bash 在默认值中
# 遇到第一个未转义的 `}` 就结束参数展开，`You.{0,3}ve …` 会被截成 `You.{0,3ve …}`。
# 这是上游测试第一轮跑出来的真实 bug，故改用显式 if 赋值。
if [[ -z "${QUOTA_BANNER_REGEX:-}" ]]; then
  QUOTA_BANNER_REGEX='You.{0,3}ve hit your [A-Za-z0-9 -]*limit'
fi
if [[ -z "${QUOTA_RESET_TIME_REGEX:-}" ]]; then
  QUOTA_RESET_TIME_REGEX='resets( at)? [0-9]{1,2}(:[0-9]{2})?[[:space:]]?(am|pm)'
fi

# The monitor "ready" detector must be **looser** than the one above: a freshly
# started composer carries a placeholder hint (`❯ Try "edit <filepath> to..."`)
# which contains alphanumerics, so the strict empty-cursor regex never matches and
# using it to detect readiness would time out forever. The two regexes cannot be
# merged — the limit detector's "must be an **empty** cursor" is load-bearing (it is
# the disproof invariant for "the CLI is idle with no dialog open"), and loosening it
# reopens that false-positive.
# 监控会话「就绪」判据必须比上面那条松：刚起的 客户端 composer 带占位提示
# （`❯ Try "edit <filepath> to..."`），含字母数字 → 严格的空 cursor 正则匹配不上，
# 用它判就绪会永远超时。两条正则不能共用——撞限判据那边的「必须是**空** cursor」
# 是承重的（它是"客户端 闲置无框"的反证不变量），松了会重新打开假阳性。
QUOTA_COMPOSER_REGEX="${QUOTA_COMPOSER_REGEX:-^[[:space:]]*❯}"
# Observable marker that the `/usage` panel is actually open. After pressing Enter
# you must confirm it really opened before waiting for the numbers to refresh —
# otherwise, when the panel did not open, you wait out the entire timeout and then
# falsely report "the monitor session is stuck".
# /usage 面板开着的可观测标志。回车之后必须先确认它真的开了，再去等数字刷新——
# 否则面板没开时就是白等满整个超时然后误报「监控会话卡住」。
QUOTA_PANEL_REGEX="${QUOTA_PANEL_REGEX:-Current session|Current week|% used|Resets }"

# ── Logging / 日志 ──────────────────────────────────────────────────────
# Upstream this function also soft-attached to a supervising daemon's `log_line`
# (`declare -F log_line` → dual-write). There is no such daemon here, so that
# branch is gone; everything else is unchanged.
# 上游这个函数还会软挂监督 daemon 的 `log_line`（存在就双写）。本仓没有那个 daemon，
# 该分支已删；其余不变。
quota_log() {
  mkdir -p "$(dirname "$QUOTA_LOG")" 2>/dev/null
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$QUOTA_LOG"
}

# ── OAuth stands in when the panel is blind / 面板失灵时用 OAuth 顶上 ───
# (current account only)
#
# The gap: `quota_monitor_refresh` returns 1 for the whole round if it cannot read
# the panel, updating nothing. If the panel keeps failing (session killed, CLI
# exited, `/usage` stuck), the script carries an ever-older number and **cannot tell
# that it is blind** — it knows "this round read nothing", not "it has read nothing
# for ten rounds".
# The OAuth line samples the current account independently every 180s and covers
# exactly that gap. It is allowed to stand in because the evidence for that one path
# is sufficient (≤2 points from the panel within ±60s, 55/56 success), and because
# **the alternative to a panel that cannot be read is not "another source" — it is
# "nothing at all".**
#
# ⚠️ Three gates, none of them optional:
#   ① Identity must match. If the sampled account is not the current account it must
#      not be used — that is somebody else's quota, and acting on it switches the
#      wrong account. Same rule as the panel path's account guard.
#   ② It must be fresh. Older than two sampling periods counts as absent: a stale
#      reading is more dangerous than none, because it makes the script believe it
#      can see.
#   ③ Record the source on write. Afterwards you must be able to tell which numbers
#      came from the panel and which from OAuth, or a failure cannot be attributed.
#
# 现状：面板读不到就整轮 return 1，一个数都不更新。面板要是持续失灵，脚本会拿着越来越
# 旧的数，而且**看不出自己在瞎**——它只知道「这轮没读到」，不知道「已经连着十轮没读到」。
# OAuth 那条线每 180s 独立采一次当前账号，恰好能顶这个缺口。放行它是因为：当前账号这条
# 路的证据是够的，而**面板读不到时的替代品不是「另一个来源」，是「什么都没有」**。
# ⚠️ 三道闸，一个都不能省：①身份必须对得上 ②必须够新 ③落盘时标明来源。
QUOTA_OAUTH_WRITES_LEDGER="${QUOTA_OAUTH_WRITES_LEDGER:-1}"
QUOTA_OAUTH_FALLBACK="${QUOTA_OAUTH_FALLBACK:-1}"
QUOTA_OAUTH_FALLBACK_MAX_AGE="${QUOTA_OAUTH_FALLBACK_MAX_AGE:-400}"   # about two 180s periods / 约两个 180s 周期

# ── Window horizons / 窗口视界 ──────────────────────────────────────────
# The maximum remaining life of each window. A five-hour window's reset is
# necessarily within five hours; past that horizon the panel line refers to a moment
# that has **already passed** — i.e. that frame belongs to an expired window.
# ⚠️ Without this clamp, midnight roll-over disguises a stale frame as a *newer*
# window: on 2026-08-11 19:50:31 a frame read `Resets 7:50pm`, 19:50 had just gone
# by, and naive parsing +86400 turned it into **tomorrow** 19:50 — later than the
# genuine frame's 00:50 today, so "compare freshness by reset" failed completely.
# In that incident this is the exact step that made the old poller accept a stale 97%.
# 每个窗口的最大剩余时长。五小时窗口的 reset 必然在 5 小时以内，超出视界就说明这行文案
# 指的是**已经过去**的那一刻——即这一帧属于已过期的旧窗口。
# ⚠️ 没有这条钳制，跨日回卷会把陈旧帧伪装成"更新的窗口"（2026-08-11 事故的关键一步）。
QUOTA_SESSION_WINDOW_HORIZON="${QUOTA_SESSION_WINDOW_HORIZON:-19800}"   # 5h + 30min margin / 5h + 30min 余量
QUOTA_WEEK_WINDOW_HORIZON="${QUOTA_WEEK_WINDOW_HORIZON:-700000}"        # 7d + ~2h30m margin / 7d + 约 2h30m 余量

# ── Capacity across all accounts / 全账号合计容量 ───────────────────────
# The two quantities differ by two orders of magnitude in time constant and must be
# read separately:
#   weekly total   — strategic. It has a hard horizon (the weekly reset); once spent
#                    it is really gone and you can only wait.
#   five-hour total— tactical. Hitting the floor means work stalls right now, but it
#                    heals itself in a few hours.
#
# ⚠️ The burn rate must be measured on the **sum across accounts**, not on the
#    current account: one switch and the current-account history is severed. Idle
#    accounts' weekly usage does not move while the active one climbs, so the summed
#    curve is naturally continuous across a switch.
#
# ⚠️ Only the current account has live data; the others were measured when they were
#    last switched to. Idle-account behaviour happens to help: weekly usage does not
#    move (nobody is spending it) → the old number is still accurate; the five-hour
#    window is healing → the old number is pessimistic. So this estimate **can only
#    understate available capacity, never overstate it**, which is the safe direction.
# 两个量的时间常数差两个数量级，必须分开看；烧速必须测「各账号已用之和」这条曲线的斜率，
# 不能测当前账号的（切一次号历史就断了）。这个估计**只会低估可用容量，不会高估**。
QUOTA_CAPACITY_SAMPLE_INTERVAL="${QUOTA_CAPACITY_SAMPLE_INTERVAL:-60}"
QUOTA_CAPACITY_SAMPLE_KEEP="${QUOTA_CAPACITY_SAMPLE_KEEP:-180}"   # ~3 hours / ~3 小时
QUOTA_CAPACITY_MIN_SPAN="${QUOTA_CAPACITY_MIN_SPAN:-1200}"        # spans under 20min do not yield a burn rate / 跨度不足 20min 不报烧速

# ── Weekly / five-hour conversion ratio / 换算比值 ──────────────────────
# Over a short span the two meters measure the same spend with different
# denominators:
#     dweek = spend / weekly budget × 100     dfive = spend / five-hour budget × 100
#     ⇒ ratio = five-hour budget / weekly budget, a **structural constant**,
#       independent of load intensity
# (Precondition: no older spend rolls out of the five-hour window during the
# measurement. A span of a few minutes satisfies this.)
#
# Measured 2026-08-11 from the quota log: 0.120 (independent spans 0.10–0.125, very
# stable)
#   ⇒ draining one five-hour window (0→100) ≈ 12 weekly points
#   ⇒ one account's weekly budget ≈ 8.3 full five-hour windows; three accounts ≈ 25
#   ⇒ a week holds 33.6 five-hour windows, three accounts cover 25 ⇒ at most about
#     74% of the week at full intensity
#
# ⚠️ The first measurement came out as **-0.434 (negative)** — because it mixed in a
# stretch where the monitor session was still attached to the old account, so the
# weekly figure bounced between two accounts' values. **Contaminated data does not
# raise an error; it hands you a confident wrong number.** Hence accumulation below
# only counts a sample when the account has not changed and neither percentage went
# backwards.
# 短时间内两块表测的是同一笔消耗，只是分母不同 ⇒ 比值是**结构常数**。
# 2026-08-11 实测 0.120。⚠️ 首次实测算出 -0.434（负数），因为混进了监控会话挂在旧账号上
# 那段读数——**污染过的数据不会报错，它会给你一个信心十足的错数**。
QUOTA_RATIO_SEED="${QUOTA_RATIO_SEED:-0.120}"
QUOTA_RATIO_MIN_FIVE="${QUOTA_RATIO_MIN_FIVE:-100}"   # accumulate this much dfive before trusting the measured value / 累计 Δfive 够这么多才改用实测值

# ── Where Claude Code keeps its config / 客户端 的配置文件 ──────────────────
# Upstream defaulted to a literal `/root/.claude.json` in places, which assumes the
# tool runs as root. It follows $HOME here.
# 上游有几处写死 `/root/.claude.json`（假定以 root 运行）。这里一律跟随 $HOME。
QUOTA_CLAUDE_JSON="${QUOTA_CLAUDE_JSON:-$HOME/.claude.json}"

# ── Time rendering / 时刻渲染 ───────────────────────────────────────────
#
# ⚠️ There are two renderers in this stack whose default time zones are **opposite**
#    while their output looks identical:
#      jq's strftime  → always UTC, ignores TZ
#      date -d @N     → the process's local zone
#    On 2026-08-21 a sampling log read with jq strftime showed 14:52 as 06:52, which
#    led to "the shadow sampler has been dead for eight hours" — it had been running
#    fine the whole time. Both timestamps look correct; they are eight hours apart.
#
# ⚠️ And you cannot fix it with `TZ=Asia/Shanghai`: in a container without tzdata
#    that **silently falls back to UTC** without an error.
#    So the offset is resolved **once**, from this machine, and everything after that
#    is arithmetic on top of a UTC render — no zoneinfo lookup at render time, and
#    therefore no way to silently degrade to UTC halfway through.
#
# ⚠️ Upstream hard-coded +0800 (`date -u -d @(ts+28800)`, `TZ=CST-8`) because it ran
#    on exactly one machine in one zone. That is a site fact, not a property of the
#    problem, so here the offset comes from the host. Override QUOTA_TZ_OFFSET_SEC to
#    pin it (e.g. 28800 for UTC+8) if you want reproducible output across machines.
#
# ⚠️ 这套东西里有两个渲染器，默认时区**相反**，输出却长得一模一样（jq strftime 恒 UTC；
#    date -d @N 看本地）。也不能用 `TZ=<区域名>`：缺 tzdata 的容器里它**静默回退 UTC**、
#    不报错。⇒ 偏移量只解析**一次**，此后全是在 UTC 渲染上做算术，渲染时不查时区库，
#    因此不可能中途静默退回 UTC。
# ⚠️ 上游把 +0800 写死了（它只跑在一台机器上）。那是站点事实不是问题本身的性质，
#    所以这里从宿主取。想要跨机器可复现的输出就显式设 QUOTA_TZ_OFFSET_SEC。
if [[ -z "${QUOTA_TZ_OFFSET_SEC:-}" ]]; then
  _qs_z=$(date '+%z' 2>/dev/null)
  if [[ "$_qs_z" =~ ^([+-])([0-9]{2})([0-9]{2})$ ]]; then
    QUOTA_TZ_OFFSET_SEC=$(( (10#${BASH_REMATCH[2]} * 3600 + 10#${BASH_REMATCH[3]} * 60) ))
    [[ "${BASH_REMATCH[1]}" == "-" ]] && QUOTA_TZ_OFFSET_SEC=$(( -QUOTA_TZ_OFFSET_SEC ))
  else
    # `date +%z` gave something unparseable. Fail loud rather than guess: a guessed
    # offset is exactly the silent-8-hour-error this whole section exists to prevent.
    # 取不到可解析的偏移量就**响亮失败**，不猜——猜出来的偏移正是本节要防的那种静默错。
    echo "quota-sentinel: cannot determine the local UTC offset (date '+%z' returned '${_qs_z}');" >&2
    echo "  set QUOTA_TZ_OFFSET_SEC explicitly (e.g. 28800 for UTC+8)." >&2
    return 1 2>/dev/null || exit 1
  fi
  unset _qs_z
fi
QUOTA_TZ_LABEL="${QUOTA_TZ_LABEL:-$(awk -v s="$QUOTA_TZ_OFFSET_SEC" 'BEGIN{
  sign = (s < 0) ? "-" : "+"; if (s < 0) s = -s;
  printf "%s%02d%02d", sign, int(s/3600), int((s%3600)/60) }')}"

# TZ spec used when the panel/banner text carries no IANA zone name in parentheses.
# **Empty means this machine's local zone**, which is the right default — Claude Code
# renders the reset time in the user's own zone.
# ⚠️ Never set this to a bare abbreviation such as `CST`: glibc reads a bare
#    abbreviation as UTC+0, so the result is silently off by the offset. The earlier
#    implementation did exactly that (`date +%Z` fed back into TZ) and every parsed
#    reset was eight hours wrong without a single error.
# 面板/横幅文本括号里没有 IANA 区域名时使用的 TZ。**留空 = 本机时区**，这是正确的默认值。
# ⚠️ 绝不要设成裸缩写（如 `CST`）：glibc 会把裸缩写当 UTC+0，结果静默偏掉一整个偏移量。
#    旧实现正是这么干的（把 `date +%Z` 的输出喂回 TZ），每一个解析出来的 reset 都差 8
#    小时，而且一条错都不报。
QUOTA_FALLBACK_TZ="${QUOTA_FALLBACK_TZ:-}"

# Run `date` under a TZ spec, or under the local zone when the spec is empty.
# ⚠️ `TZ= date` is NOT "local" — an empty TZ means UTC on glibc. The distinction has
#    to live in a branch, not in a variable expansion.
# 在给定 TZ 下跑 date；spec 为空就用本机时区。
# ⚠️ `TZ= date` **不是**「本地」——glibc 下空 TZ 等于 UTC。这个区别只能靠分支表达，
#    不能靠变量展开。
quota_tz_date() {
  local tz="$1"; shift
  if [[ -n "$tz" ]]; then TZ="$tz" date "$@"; else date "$@"; fi
}

# quota_tz_spec_usable — is this TZ spec one glibc actually understands?
#
# 🔴 Fixed 2026-08-31. The fallback paths in quota_parse_reset_epoch() and
#    quota_panel_reset_epoch() documented their contract as: *"self-check that %z parses
#    as an offset; a value that silently degraded to UTC must never be written to state."*
#    The implementation was `[[ $(… '+%z') =~ ^[+-][0-9]{4}$ ]]`, which **accepts
#    `+0000`** — and `+0000` is exactly what a bare abbreviation degrades to. Measured on
#    the host: `TZ=XYZ date +%z` → `+0000`, `TZ=CST date +%z` → `+0000`. So the check was
#    true for precisely the input it existed to reject, and deleting it outright left the
#    whole suite green.
#    ⭐ That is the same shape this repository keeps writing down: a guard that is
#    **always true** and a guard that is **correct** produce identical output.
# 🔴 2026-08-31 修。这两条兜底路径的契约白纸黑字写着「自检 %z 能解析成偏移量，绝不把静默
#    回退 UTC 的值写进状态」，而实现是 `=~ ^[+-][0-9]{4}$` ——它**接受 `+0000`**，
#    而裸缩写恰恰就退化成 `+0000`（本机实测 `TZ=CST date +%z` → `+0000`）。
#    ⇒ 那条判据对它本该拒绝的那个输入恒真；整条删掉，套件照样全绿。
#
# ⚠️ The criterion is the **form of the spec**, not the value of the offset. Requiring a
#    particular offset (e.g. "+0800") would re-introduce exactly the hard-coded site fact
#    this extraction removed (see docs/REDACTION.md, "What else was parameterised"), and
#    would break the tool on every host outside that one zone. `+0000` is legitimate on a
#    genuinely UTC host, and illegitimate as the *silent result of an unparsed
#    abbreviation* — form is what separates the two, the number never can.
# ⚠️ 判据是**规格的形态**，不是偏移量的数值。要求某个具体偏移（比如「必须 +0800」）等于
#    把本次抽取刚去掉的站点事实又写死回来，且会让工具在该时区以外的每一台机器上失灵。
#    `+0000` 在真正的 UTC 宿主上是合法的，在「裸缩写没被解析」时是非法的——
#    能分开这两者的只有形态，数值永远分不开。
quota_tz_spec_usable() {
  local spec="${1-}"
  # ① 连偏移量都取不到 → 失败（原判据保留，它仍拦得住 date 本身坏掉那一类）
  [[ "$(quota_tz_date "$spec" '+%z' 2>/dev/null)" =~ ^[+-][0-9]{4}$ ]] || return 1
  # ② 空 = 本机时区，按定义就是宿主自己解析出来的那个偏移
  [[ -z "$spec" ]] && return 0
  # ③ IANA 区域名（含 `/`）
  [[ "$spec" == */* ]] && return 0
  # ④ POSIX 形态，自带显式偏移，如 `CST-8`
  [[ "$spec" == *[0-9]* ]] && return 0
  # ⑤ 真正的 UTC 别名——这里的 +0000 是**它的意思**，不是降级的结果
  case "$spec" in UTC|GMT|UCT|Z|Zulu|Universal|Etc) return 0 ;; esac
  # ⑥ 剩下的是纯字母裸缩写（CST / EDT / …）：glibc 静默当 UTC+0 —— 事故 (a) 本身
  return 1
}

# QUOTA_TIME_NORMALIZE_JQ — rebuilds ._times_readable on every state write.
#
# Every timestamp in the ledger is stored as epoch seconds. Epoch itself is
# unambiguous; **the ambiguity is entirely in the moment you read it** (see the two
# renderers above). So the ledger also carries a human-readable string **with its
# offset attached**, and nobody has to convert anything by hand.
# It uses `(epoch + offset) | strftime` rather than `date`: jq's strftime only ever
# renders UTC, so adding a fixed offset yields exactly that offset — with no zoneinfo
# lookup, and therefore no silent fallback to UTC in a container without tzdata.
#
# Only numbers that **look like** timestamps are rendered: the key must look like a
# time field and the value must fall between 2001 and 2096. Otherwise a percentage
# such as five=97 would be rendered as a date.
# 台账里所有时刻都存 epoch 秒。epoch 本身没有歧义，**歧义全在读的那一刻**。
# ⇒ 直接在台账里落一份**带偏移量**的可读字符串，谁都不用再自己换算。
# 只认「看起来像 epoch」的数（键名像时刻、值落在 2001–2096），否则 five=97 这种百分比
# 也会被渲染成日期。
QUOTA_TIME_NORMALIZE_JQ='
del(._times_readable)
| . as $r
| ._times_readable = (
    [ paths(type=="number") as $p
      | select(($p[-1]|type) == "string")
      | select(($p[-1]|test("(_ts|_at|reset|_since|_until)$")))
      | select(($r|getpath($p)) >= 1000000000 and ($r|getpath($p)) <= 4000000000)
      | { key:   ($p|map(tostring)|join(".")),
          value: ((($r|getpath($p)) + $tzoff) | strftime("%Y-%m-%d %H:%M:%S") + " " + $tzlabel) }
    ] | from_entries
  )
| ._times_note = ("every *_ts/*_at/*reset field is epoch seconds (UTC epoch); _times_readable above "
    + "renders the same instants at " + $tzlabel + ", rebuilt on every state write. Reading the epoch "
    + "directly with jq strftime gives UTC instead. "
    + "所有 *_ts/*_at/*reset 字段是 epoch 秒；上面 _times_readable 是同一时刻按 " + $tzlabel
    + " 渲染的对照。用 jq strftime 直接读 epoch 会得到 UTC。")
'

# ── Idle-cursor regex accessor / 空 cursor 正则取值 ─────────────────────
quota_idle_cursor_regex() { printf '%s' "${IDLE_CURSOR_REGEX:-$QUOTA_IDLE_CURSOR_DEFAULT}"; }
