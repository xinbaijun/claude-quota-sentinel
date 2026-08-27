# Provenance / 抽取来源映射

Everything in this repository was extracted from a private in-house
fleet-automation codebase at commit `e2f32279`. This file records, function by
function, exactly where each piece came from, so that any line here can be checked
against the original.
本仓的一切都抽取自一个非公开的内部编队自动化代码库，基线 commit 是 `e2f32279`。
本文件逐函数记录每一块的来源，使这里的任何一行都能与原文核对。

## How to verify a mapping / 怎么核一条映射

On a machine with access to the source repository / 在能访问源仓的机器上：

```sh
git show e2f32279:scripts/<source-file> | sed -n '<from>,<to>p'
```

⚠️ **Always `git show` the baseline commit; never `cp` from a working tree.**
The source repository is under active development and its working tree drifts away
from `e2f32279` continuously — during the survey milestone alone it moved three
separate times within half an hour. A file copied from a working tree does not match
the commit this file claims, **and nothing reports the mismatch**: the copy succeeds,
everything still runs, and the only symptom is that this document has quietly become
false. See README.md "Provenance" for the standing rule.
⚠️ **一律 `git show` 基线 commit，绝不从工作树 `cp`。**源仓仍在持续开发，工作树与
`e2f32279` 时刻在漂移——仅盘点里程碑期间，半小时内就真实变了三次。从工作树复制出来的
文件与本文件声称的 commit 对不上，**而且这种错不会报错**：复制成功、照样能跑，
唯一的表现是本文件在很久以后变成了假话。

## Baseline fingerprints / 基线指纹

Recorded so that "which version was this taken from" stays answerable even if the
commit id alone is ever in doubt.
记下来，是为了即便日后单凭 commit id 说不清，「抽的到底是哪一版」仍然答得出。

| source file / 源文件 | lines / 行数 | sha256 (first 12) |
|---|---:|---|
| `scripts/sentinel-quota` | 5124 | `99416ec69fbc` |
| `scripts/claude-account-probe` | 512 | `b5f5bc291af1` |
| `scripts/fleet-env.sh` | 977 | `5678d65ed325` |
| `scripts/claude-account-switch` | 1245 | `e2d758bcf19f` |
| `scripts/test/sentinel-quota.test.sh` | 4407 | `0a06209ffe1e` |

## Per-function mapping / 逐函数映射

Ranges are line numbers **in the baseline file**, and they include each function's
attached comment block — those comments are the incident record, and they were
extracted together with the code on purpose.
行号是**基线文件里**的行号，且包含每个函数紧挨着的注释块——那些注释就是事故记录，
是**有意**与代码一起抽出来的。

### `lib/reading.sh`  ←  `scripts/sentinel-quota`

| function / 函数 | baseline lines / 基线行号 |
|---|---|
| `quota_snapshot_read` | `e2f32279:scripts/sentinel-quota:329-340` |
| `quota_reading_apply` | `e2f32279:scripts/sentinel-quota:349-396` |
| `quota_oauth_fallback_apply` | `e2f32279:scripts/sentinel-quota:421-456` |
| `quota_reset_watch_pending` | `e2f32279:scripts/sentinel-quota:458-479` |
| `quota_reset_watch_list` | `e2f32279:scripts/sentinel-quota:481-492` |
| `quota_snapshot_refresh_due` | `e2f32279:scripts/sentinel-quota:495-524` |
| `quota_snapshot_shadow_compare` | `e2f32279:scripts/sentinel-quota:526-561` |
| `quota_account_retired` | `e2f32279:scripts/sentinel-quota:563-563` |
| `quota_account_paused` | `e2f32279:scripts/sentinel-quota:564-564` |
| `quota_account_out_of_service` | `e2f32279:scripts/sentinel-quota:565-566` |
| `quota_out_of_service_json` | `e2f32279:scripts/sentinel-quota:567-571` |
| `quota_claude_json` | `e2f32279:scripts/sentinel-quota:688-688` |
| `quota_identity_read` | `e2f32279:scripts/sentinel-quota:690-700` |
| `quota_iso_epoch` | `e2f32279:scripts/sentinel-quota:702-711` |
| `quota_shadow_json_read` | `e2f32279:scripts/sentinel-quota:713-719` |
| `quota_shadow_atomic_write` | `e2f32279:scripts/sentinel-quota:721-732` |
| `quota_shadow_append_event` | `e2f32279:scripts/sentinel-quota:734-740` |
| `quota_shadow_credential_marker` | `e2f32279:scripts/sentinel-quota:742-746` |
| `quota_shadow_now` | `e2f32279:scripts/sentinel-quota:748-748` |
| `quota_shadow_schedule` | `e2f32279:scripts/sentinel-quota:750-802` |
| `quota_shadow_schedule_penalize` | `e2f32279:scripts/sentinel-quota:804-828` |
| `quota_shadow_source_interval` | `e2f32279:scripts/sentinel-quota:830-844` |
| `quota_source_append` | `e2f32279:scripts/sentinel-quota:846-853` |
| `quota_source_log_usage` | `e2f32279:scripts/sentinel-quota:855-873` |
| `quota_source_log_usage_failure` | `e2f32279:scripts/sentinel-quota:875-888` |
| `quota_shadow_statusline_ingest` | `e2f32279:scripts/sentinel-quota:890-989` |
| `quota_monitor_launch_command` | `e2f32279:scripts/sentinel-quota:991-1011` |
| `quota_shadow_oauth_http_fetch` | `e2f32279:scripts/sentinel-quota:1013-1034` |
| `quota_shadow_retry_after` | `e2f32279:scripts/sentinel-quota:1036-1048` |
| `quota_shadow_oauth_due` | `e2f32279:scripts/sentinel-quota:1050-1064` |
| `quota_shadow_oauth_sample` | `e2f32279:scripts/sentinel-quota:1066-1275` |
| `quota_shadow_poller_loop` | `e2f32279:scripts/sentinel-quota:1277-1309` |
| `quota_shadow_poller_ensure` | `e2f32279:scripts/sentinel-quota:1311-1322` |
| `quota_snapshot` | `e2f32279:scripts/sentinel-quota:1324-1346` |
| `quota_snapshot_fresh` | `e2f32279:scripts/sentinel-quota:1348-1358` |

### `lib/monitor.sh`  ←  `scripts/sentinel-quota`

| function / 函数 | baseline lines / 基线行号 |
|---|---|
| `quota_monitor_alive` | `e2f32279:scripts/sentinel-quota:1364-1364` |
| `quota_monitor_single_pane_id` | `e2f32279:scripts/sentinel-quota:1366-1374` |
| `quota_monitor_live_launch_id` | `e2f32279:scripts/sentinel-quota:1376-1385` |
| `quota_monitor_new_launch_id` | `e2f32279:scripts/sentinel-quota:1387-1391` |
| `quota_monitor_pane_identity` | `e2f32279:scripts/sentinel-quota:1393-1401` |
| `quota_monitor_shell_ready` | `e2f32279:scripts/sentinel-quota:1403-1411` |
| `quota_monitor_ready` | `e2f32279:scripts/sentinel-quota:1413-1421` |
| `quota_monitor_wait_ready` | `e2f32279:scripts/sentinel-quota:1423-1441` |
| `quota_monitor_launch_in_pane` | `e2f32279:scripts/sentinel-quota:1443-1489` |
| `quota_monitor_ensure` | `e2f32279:scripts/sentinel-quota:1491-1510` |
| `quota_monitor_exit_to_shell` | `e2f32279:scripts/sentinel-quota:1512-1555` |
| `quota_reset_same_window` | `e2f32279:scripts/sentinel-quota:1557-1566` |
| `quota_reset_later_window` | `e2f32279:scripts/sentinel-quota:1568-1573` |
| `quota_window_sample_relation` | `e2f32279:scripts/sentinel-quota:1575-1600` |
| `quota_panel_sample_better` | `e2f32279:scripts/sentinel-quota:1602-1637` |
| `quota_frame_stale` | `e2f32279:scripts/sentinel-quota:1639-1703` |
| `quota_monitor_dismiss` | `e2f32279:scripts/sentinel-quota:1705-1725` |
| `quota_panel_parse` | `e2f32279:scripts/sentinel-quota:1757-1776` |
| `quota_panel_field` | `e2f32279:scripts/sentinel-quota:1778-1785` |
| `quota_panel_frame_status` | `e2f32279:scripts/sentinel-quota:1787-1832` |
| `quota_usage_interval_for_values` | `e2f32279:scripts/sentinel-quota:1834-1850` |
| `quota_usage_backoff_interval` | `e2f32279:scripts/sentinel-quota:1938-1946` |
| `quota_panel_reset_epoch` | `e2f32279:scripts/sentinel-quota:1958-1982` |
| `quota_reset_validate_for_write` | `e2f32279:scripts/sentinel-quota:1984-1992` |
| `quota_window_reset_for_write` | `e2f32279:scripts/sentinel-quota:1994-2007` |
| `quota_monitor_panel_open` | `e2f32279:scripts/sentinel-quota:2009-2016` |
| `quota_monitor_prepare_owner` | `e2f32279:scripts/sentinel-quota:2018-2060` |
| `quota_monitor_open_usage` | `e2f32279:scripts/sentinel-quota:2062-2090` |
| `quota_monitor_observe` | `e2f32279:scripts/sentinel-quota:2092-2120` |
| `quota_monitor_stale_recovery_claim` | `e2f32279:scripts/sentinel-quota:2122-2140` |
| `quota_monitor_recover_stale_frame` | `e2f32279:scripts/sentinel-quota:2142-2160` |
| `quota_monitor_refresh` | `e2f32279:scripts/sentinel-quota:2162-2294` |
| `quota_monitor_restart` | `e2f32279:scripts/sentinel-quota:2296-2331` |

### `lib/detect.sh`  ←  `scripts/sentinel-quota`

| function / 函数 | baseline lines / 基线行号 |
|---|---|
| `quota_menu_present` | `e2f32279:scripts/sentinel-quota:2337-2351` |
| `quota_banner_present` | `e2f32279:scripts/sentinel-quota:2353-2387` |
| `quota_banner_confirmed` | `e2f32279:scripts/sentinel-quota:2389-2399` |
| `quota_parse_reset_epoch` | `e2f32279:scripts/sentinel-quota:2401-2424` |

### `lib/state.sh`  ←  `scripts/sentinel-quota`

| function / 函数 | baseline lines / 基线行号 |
|---|---|
| `quota_state_read` | `e2f32279:scripts/sentinel-quota:2437-2437` |
| `quota_state_get` | `e2f32279:scripts/sentinel-quota:2439-2444` |
| `quota_fmt_ts` | `e2f32279:scripts/sentinel-quota:2491-2506` |
| `quota_fmt_delta` | `e2f32279:scripts/sentinel-quota:2508-2518` |
| `quota_iso_to_epoch` | `e2f32279:scripts/sentinel-quota:2520-2525` |
| `quota_state_merge` | `e2f32279:scripts/sentinel-quota:2547-2564` |
| `quota_usage_interval_current` | `e2f32279:scripts/sentinel-quota:2568-2579` |
| `quota_estimate_values` | `e2f32279:scripts/sentinel-quota:2714-2735` |
| `quota_estimate_exceeds` | `e2f32279:scripts/sentinel-quota:2737-2744` |
| `quota_usage_refresh_due` | `e2f32279:scripts/sentinel-quota:2777-2791` |
| `quota_usage_refresh_begin` | `e2f32279:scripts/sentinel-quota:2793-2822` |
| `quota_usage_refresh_failure` | `e2f32279:scripts/sentinel-quota:2824-2851` |
| `quota_panel_observations_prune_if_due` | `e2f32279:scripts/sentinel-quota:2853-2902` |
| `quota_panel_log_observation` | `e2f32279:scripts/sentinel-quota:2904-2940` |
| `quota_account_guard` | `e2f32279:scripts/sentinel-quota:2942-3049` |
| `quota_monitor_owner_guard` | `e2f32279:scripts/sentinel-quota:3051-3088` |
| `quota_monitor_bind_owner` | `e2f32279:scripts/sentinel-quota:3090-3129` |
| `quota_session_created` | `e2f32279:scripts/sentinel-quota:3241-3246` |
| `quota_session_generation_matches` | `e2f32279:scripts/sentinel-quota:3248-3254` |
| `quota_capture_pane_tail` | `e2f32279:scripts/sentinel-quota:3371-3387` |
| `quota_ratio_update` | `e2f32279:scripts/sentinel-quota:3678-3698` |
| `quota_ratio_value` | `e2f32279:scripts/sentinel-quota:3700-3712` |
| `quota_capacity_update` | `e2f32279:scripts/sentinel-quota:3714-3785` |
| `quota_monitor_op_run` | `e2f32279:scripts/sentinel-quota:4715-4742` |

### `account-probe`  ←  `scripts/claude-account-probe`

| piece / 部分 | baseline lines / 基线行号 | note / 说明 |
|---|---|---|
| header, "why this exists" | `e2f32279:scripts/claude-account-probe:1–33` | condensed; the three measured counter-examples kept verbatim / 压缩过，三个实测反例原样保留 |
| OAuth query config + its "rejected once, reversed once" record | `:55–93` | reproduced in full — it is the evidence, not commentary / 全文保留，它是证据不是评注 |
| `probe_oauth_gate` | `:157–173` | copied / 复制 |
| `probe_oauth_record` | `:174–181` | copied / 复制 |
| `probe_quota` | `:182–228` | copied / 复制 |
| `_iso_to_local` | `:456–470` | copied; the hard-coded offset became the resolved one / 复制；写死的偏移量换成解析出来的 |
| source guard | `:286–292` | copied / 复制 |
| `--snapshot` output shape | `:380–437` | copied; roster env vars and offset renamed / 复制；名册变量与偏移量改名 |
| `--json` output shape | `:438–455` | copied / 复制 |
| main flow / 主流程 | `:294–379` | **rewritten** — see "rewritten" below / **重写**，见下 |

### `lib/config.sh`  ←  `scripts/sentinel-quota:45–684` (+ 5 symbols from `scripts/fleet-env.sh`)

This is the one file that was **rewritten rather than copied**, because it is where
all of the private environment lived. The constants and the incident notes attached to
them were carried across; the plumbing around them was replaced.
这是整次抽取中唯一**被重写而非复制**的文件——那套内部环境全都住在这里。常量与挂在它们
身上的事故注释都搬了过来，围绕它们的接线换掉了。

| baseline block / 基线块 | what happened / 处置 |
|---|---|
| `:45–63` root location, sourcing the environment's own env file and a transport library | replaced by locating this repo's own root / 换成定位本仓自己的根 |
| `:64` shared runtime dir | → `QS_STATE_DIR`, defaulting under `$XDG_STATE_HOME` |
| `:65–66` session prefix, services session | dropped (the first serves a feature that is not extracted; the second was dead code) / 删（前者服务未抽取的功能，后者是死配置） |
| `:68–83` monitor session | kept; the session name lost its prefix, and the hard-coded machine-local proxy became `QUOTA_MONITOR_PROXY`, empty by default / 保留；会话名去掉前缀，写死的本机代理改为默认留空的 `QUOTA_MONITOR_PROXY` |
| `:85–126` thresholds, cadence, rate adaptation | kept verbatim, incident notes and all / 原样保留，含全部事故注释 |
| `:170–185, 207–216` estimation | kept / 保留 |
| `:223–248` fetch window, panel sampling, runtime globals | kept / 保留 |
| `:274–312` account roster | kept, **defaults emptied** (upstream defaulted to a real roster) and every real name replaced — see REDACTION.md / 保留，**默认值清空**（上游默认值是一份真实名册），真实人名全部替换 |
| `:314–347` cross-account snapshot | kept; paths re-rooted / 保留，路径改根 |
| `:398–419` OAuth fallback gates | kept / 保留 |
| `:493, 573` tool paths | → repo-relative / 改成仓内相对路径 |
| `:588–600` paths | kept; re-rooted / 保留，改根 |
| `:602–645` shadow sampling | kept, incident record and all / 保留，含事故记录 |
| `:647–674` fallback UI regexes | kept verbatim / 原样保留 |
| `:678–684` logging | kept, minus a soft hook into a supervising daemon that does not exist here / 保留，去掉软挂那个本仓不存在的监督 daemon 的分支 |
| `:1952–1957` window horizons | kept / 保留 |
| `:2447–2477` readable-time normalisation | kept; the fixed +8h offset became the resolved local offset / 保留；固定 +8 小时偏移换成解析出来的本机偏移 |
| `:3645–3676` capacity and ratio constants | kept, including the -0.434 contamination story / 保留，含 -0.434 那次污染的记录 |

## Rewritten, and why / 重写了什么，为什么

Three functions and one main flow could not come across unchanged, because their
inputs do not exist outside the environment they were written in. Each carries a
`🔻 REWRITTEN` note at its definition explaining what was removed and **what that
costs** — the cost is stated rather than quietly dropped.
三个函数和一段主流程无法原样过来，因为它们的输入在那套环境之外根本不存在。每一个的定义
处都带着 `🔻 REWRITTEN` 注释，说明删掉了什么、**代价是什么**——代价是写出来的，不是
悄悄丢掉的。

| here / 本仓 | baseline / 基线 | removed / 删掉的 |
|---|---|---|
| `quota_usage_interval_adaptive` (`lib/monitor.sh`) | `sentinel-quota:1872–1936` | 3 of 4 speed-up sources: screen-banner pressure, concurrency count, pending deliveries |
| `quota_refresh_force_due` (`lib/state.sh`) | `sentinel-quota:2746–2775` | 2 of 3 triggers: banner self-report, concurrency jump |
| `quota_read_once` (`lib/state.sh`) | `quota_poll_once`, `sentinel-quota:4069–4275` | dead-session reaping, banner sampling, and the whole switching half |
| `account-probe` main flow | `claude-account-probe:294–379` | multi-account discovery (needs the switching tool) and the container liveness probe (needs Docker, and writes credential copies to disk) |

## Not extracted / 未抽取

Listed rather than omitted: a reader who finds a dangling reference should be able to
see immediately that it was a decision, not an oversight.
列出来而不是略去：读者碰到一处悬空引用时，应当能立刻看出那是决定，不是疏漏。

| what / 什么 | why / 为什么 |
|---|---|
| session enumeration, dead-session reaping, blocked-session ledger, resume delivery, the transport library (`sentinel-quota` sections 五/六 and most of 七) | all of it is built on that environment's session-naming convention and its own delivery tooling; none of it means anything outside / 整套建立在那套环境的会话命名约定与它自己的投递工具上，在外面毫无意义 |
| on-screen banner as a data source (`quota_banner_pressure`, `quota_banner_reading`, `quota_banner_sample_apply`) | reads a screen-recording archive of every session in that environment / 读的是那套环境里全部会话的屏幕留档 |
| the supervising daemon interface (`quota_state_cache_refresh`, `quota_session_blocked`) and its lookup cache | there is no such daemon here / 本仓没有那个 daemon |
| account switching: candidate ranking, the switch ledger, exhaustion handling, manual switch (`quota_try_switch`, `quota_switch_to`, `quota_accounts`, `quota_all_exhausted`, `quota_account_switch_record`, `quota_cmd_switches`, …) | **a later milestone**, not a rejection. The seam where it attaches is written out explicitly at the end of `quota_read_once`. / **后续里程碑**，不是否决。它接回来的接缝在 `quota_read_once` 末尾显式写出来了。 |
| the regression suite (`scripts/test/sentinel-quota.test.sh`) | a later milestone / 后续里程碑 |
| `scripts/fleet-env.sh` as a file | only 5 of its 977 lines are consumed by this chain, and the rest contains unrelated real addresses. **Never copy that file whole.** / 这条链只消费它 977 行里的 5 个符号，其余部分含无关的真实地址。**绝不要整份复制它。** |
