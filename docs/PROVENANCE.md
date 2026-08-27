# Provenance / 抽取来源映射

Almost everything in this repository was extracted from a private in-house
fleet-automation codebase at commit `e2f32279`. This file records, function by
function, where each extracted piece came from, so that it can be checked against the
original. **The exception is the CLI shell written for this repository** — four
functions that have no upstream counterpart; they are listed in their own section
below rather than left to look like an omission.
本仓**几乎**一切都抽取自一个非公开的内部编队自动化代码库，基线 commit 是 `e2f32279`。
本文件逐函数记录每一块**抽来的**来源，使它能与原文核对。**例外是为本仓新写的 CLI 外壳**
——四个上游没有对应物的函数；它们单列一节，而不是任其看起来像漏项。

> ⚠️ **这句话曾经写成「本仓的一切……任何一行都能核对」，而那是假的**：仓里 113 个函数
> 定义里当时有 10 个没有来源行（6 个来自基线、4 个是新写的）。
> ⭐ **一份自称「任何一行都能核对」而实际有函数无从核起的映射表，比没有这句话更糟**
> ——它会让读者停止自己去核。补全见下；口径已按事实收窄。

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

### Checking the mapping is *complete*, not just correct / 核的是覆盖面，不是条目对不对

🔴 Spot-checking rows tells you whether the rows that are here are right. It cannot tell
you whether a function is **missing** a row — and that is the failure this document has
already had once. So the `account-switch` mapping below is written as a rule plus
exceptions, which makes the completeness question answerable by running something:

```sh
# every name in account-switch that is NOT in the baseline must appear in the
# "new in this milestone" list below; output should contain nothing else.
python3 - <<'EOF'
import ast
names = lambda p: {n.name for n in ast.walk(ast.parse(open(p).read()))
                   if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef))}
new  = names("account-switch")
base = names("/tmp/baseline.py")   # git show e2f32279:scripts/claude-account-switch > /tmp/baseline.py
print("unmapped (must match the NEW list):", sorted(new - base))
print("dropped  (must match the DROPPED list):", sorted(base - new))
EOF
```

⚠️ Use the AST, not a line scan. A `def name(` … `) -> None:` signature spread over
several lines puts its closing paren in column 0, so "a block ends at the next
unindented line" truncates the function to its signature and reports a rewritten body as
untouched. That was measured here, on `switch_profile`, and it produced a clean-looking
"everything accounted for" that was wrong.
⚠️ 用 AST，不要按行扫。多行签名的 `) -> None:` 落在第 0 列，「块到下一个不缩进的行为止」
会把函数截断到签名，于是**被改写的函数体会被报成没动过**——本仓在 `switch_profile` 上
实测到过，而且它给出的是一份看起来很干净的「全部对上了」。

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

### `quota-sentinel` (CLI shell) / `lib/config.sh`  ←  `scripts/sentinel-quota`

These six were extracted but were missing from the tables above until the m2 review
caught it. Ranges follow the same convention as everywhere else in this file —
**the function plus its attached comment block**.
这六个是抽取来的，但直到 m2 review 才被发现漏在上面各表之外。行范围口径与本文件其余
各处一致：**函数本体加紧挨其上的注释块**。

| function / 函数 | baseline lines / 基线行号 | note / 说明 |
|---|---|---|
| `quota_cmd_status` | `e2f32279:scripts/sentinel-quota:4853-4936` | 🔻 **rewritten** — see the note at its definition / **重写**，见定义处 |
| `quota_cmd_capacity` | `e2f32279:scripts/sentinel-quota:4938-5017` | output translated; the display layer's null-tolerance and its reasons are unchanged / 输出英文化；展示层的 null 容忍与其理由未变 |
| `quota_cmd_detect` | `e2f32279:scripts/sentinel-quota:5019-5030` | output translated; `reset` now renders through `quota_fmt_ts` / 输出英文化；`reset` 改走 `quota_fmt_ts` |
| `quota_idle_cursor_regex` | `e2f32279:scripts/sentinel-quota:666-666` | copied verbatim / 逐字复制 |
| `quota_log` | `e2f32279:scripts/sentinel-quota:676-682` | copied, minus the soft hook into a supervising daemon that does not exist here / 复制，去掉软挂那个本仓不存在的监督 daemon 的分支 |
| `die` | `e2f32279:scripts/claude-account-probe:123-123` | copied verbatim / 逐字复制 |

### Written for this repository / 本仓新写

Four functions have **no upstream counterpart**. Listed rather than omitted, for the
same reason the "not extracted" table exists: a reader who finds no mapping row should
be able to see immediately that it is a fact, not a gap in this document.
四个函数**上游没有对应物**。列出来而不是略去，理由与「未抽取」那张表相同：
读者找不到映射行时，应当能立刻看出那是事实，不是本文件的缺口。

| function / 函数 | where / 位置 | why it exists / 为什么有它 |
|---|---|---|
| `quota_tz_date` | `lib/config.sh` | runs `date` under a TZ spec, or under the local zone when the spec is empty. `TZ= date` is **not** "local" — an empty TZ means UTC on glibc — so the distinction has to live in a branch, not in a variable expansion / 空 TZ 在 glibc 下等于 UTC，这个区别只能靠分支表达 |
| `quota_require_deps` | `quota-sentinel` | up-front dependency check. A missing `jq` otherwise surfaces as a reading that is quietly always empty, which is indistinguishable from "this account has no quota data" / 少了 `jq` 的表现是读数恒空，与「这个账号没有额度数据」长得一模一样 |
| `quota_cmd_env` | `quota-sentinel` | prints the resolved configuration; every "it does not work on my machine" so far came down to a path or an offset resolving somewhere unexpected / 打印解析后的配置 |
| `quota_usage_text` | `quota-sentinel` | the usage text, which also states what this milestone does **not** include / 用法文本，同时写明本里程碑**不**含什么 |

### `account-switch`  ←  `scripts/claude-account-switch` (whole file)

Extracted with `git show e2f32279:scripts/claude-account-switch`, never copied from a
working tree. Verified: the retrieved bytes are 1245 lines, sha256 `e2d758bcf19f…`,
matching the fingerprint recorded above.

**The mapping is stated as a rule plus its exceptions, not as a 72-row table** — a table
that long is not read, and the reverse check that actually matters ("is any function
unmapped?") is one someone should be able to *run*, not eyeball.

> **Rule.** Every function, class and method in `account-switch` maps 1:1, by name, to
> the same-named one in the baseline, **unless it appears in a list below.**

Counted by AST over both files, so multi-line signatures and nested methods are included
(a line-based count silently truncates `def switch_profile(\n …\n) -> None:` at the
closing paren and reports the body as unchanged — measured, and wrong, before switching
to the AST):

| bucket / 分类 | count | meaning |
|---|---|---|
| byte-identical to baseline | 28 | carried across untouched |
| English runtime output only | 21 | no behaviour change; includes `print_candidates`, whose implicit string concatenation re-wrapped across a different number of lines (verified: 0 of its 29 changed lines lack a string literal) |
| mechanical rename only | 3 | `expires_text`, `parse_usage`, `timestamp_now` — `SHANGHAI` → `_display_zone()`, `parse_iso_to_shanghai` → `parse_iso_to_local`, `CLAUDE_ACCOUNT_SWITCH_*` → `ACCOUNT_SWITCH_*` |
| **logic changed** | 11 | listed below — these are what a reviewer has to actually read |
| **new in this milestone** | 9 | listed below |
| **dropped from baseline** | 5 | listed below |
| accounted for | **72 of 72** | |

**Logic changed / 逻辑改动**

| function | baseline | here | why |
|---|---|---|---|
| `parse_profile` | 302 | 376 | reads identity at fixed paths instead of searching the document — see "two readers, one question" below |
| `backup_current` | 820 | 958 | credential mode + manifest v2 + prune |
| `load_backup_manifest` | 929 | 1087 | accepts v1 (pre-retention) and v2 |
| `restore_backup` | 940 | 1104 | refuses a restore that would leave config and token disagreeing |
| `switch_profile` | 989 | 1229 | recoverability guard; in-memory undo instead of restoring from the backup |
| `rollback` | 1075 | 1368 | same in-memory undo |
| `backup_candidates` | 1041 | 1313 | 🔴 **inherited bug fixed** — scanned only the old flat layout, so `--rollback` could not see any backup written after they moved into `claude-backups/` |
| `resolve_backup` | 1053 | 1339 | accepts the nested location too (same bug) |
| `backup_sources` | 472 | 544 | a fingerprint-mode backup is not a candidate and not damaged; it must not be reported as unreadable |
| `docker_homes` | 397 | 473 | dropped a site-specific path prefix |
| `build_parser` | 1106 | 1422 | `--backup-credentials`, `--keep`; `--root-home` un-hidden |

**New / 本里程碑新写**

`_display_zone` (41) · `anchored_string` (300) · `anchored_number` (310) ·
`anchored_nonempty` (320) · `parse_iso_to_local` (331) · `credential_fingerprint` (906) ·
`prune_backups` (925) · `assert_outgoing_recoverable` (1190) · `backup_roots` (1308)

**Dropped, and why / 删掉了什么，为什么 — two readers, one question**

`walk_values`, `first_string`, `first_number`, `token_nonempty`, `parse_iso_to_shanghai`.

The first four are one mechanism: *search the whole JSON document and take the first key
of a matching name.* Upstream used it to answer "which account is this?", while the
quota reader answered the same question by anchoring on `oauthAccount`. Two answers to
one question is not redundancy, it is a disagreement waiting to happen — and the account
guard downstream consumes whichever label it is handed.

They are **deleted, not deprecated**: `.claude.json` carries arbitrary nested
per-project state, so a first-match walk returns whatever the structure happens to yield
first. Demonstrated with a synthetic fixture — a same-named key under `projects` makes
the old reader report **a different account than the one actually logged in**, while the
anchored reader is unaffected. A reader that unrelated data in the same file can steer
is not made safe by putting a better reader beside it.

⚠️ Which field is *not* identity: `cachedUsageUtilization.accountUuid` is a cache-ownership
marker that only refreshes after a usage query, so it legitimately lags a switch.

**Incident comments carried across / 事故注释的去向**

| | count |
|---|---|
| incident comment blocks in the baseline | **1** (lines 45–50) |
| carried across, rewritten | **1** |
| dropped | **0** |
| account aliases inside them | 3 occurrences, all in that one block, all rewritten |

⚠️ The baseline of this particular file has **7 comment lines in total** — it is not the
comment-dense source that `sentinel-quota` is, so "1 of 1" is the whole population here,
not a sample. The alias figures quoted elsewhere in this repo's history (≈50) describe
`sentinel-quota` and `fleet-env.sh`, not this file. The one block was rewritten rather
than deleted, because deleting it would have removed the finding along with the names:
it records that two accounts' credentials existed **only** in the older backup location,
so narrowing the scan dropped the roster from five accounts to three — and one of the
two that vanished was still in use.

### `lib/switch.sh`  ←  written for this repository, plus one restored call site

No upstream file corresponds to `lib/switch.sh`. Upstream's switching logic lived inline
inside `quota_poll_once`; this milestone implements the decision half against the seam
`lib/state.sh` already exposes (`if declare -F quota_decide_once`).

⚠️ One thing here is not new: `quota_account_switch_record` was already **called** from
`lib/state.sh` by the previous milestone, with no definition anywhere in the repo. The
call sat on the external-drift path, so it would have fired the first time somebody
switched accounts by hand. Defining it closes that.

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
inputs do not exist outside the environment they were written in; one more was
rewritten because it hard-coded a single machine's time zone. Each carries a
`🔻 REWRITTEN` note at its definition explaining what was removed and **what that
costs** — the cost is stated rather than quietly dropped.
三个函数和一段主流程无法原样过来，因为它们的输入在那套环境之外根本不存在；另有一个
因为写死了某一台机器的时区而被重写。每一个的定义处都带着 `🔻 REWRITTEN` 注释，
说明删掉了什么、**代价是什么**——代价是写出来的，不是悄悄丢掉的。

> ⚠️ **`quota_cmd_status` 那一条是 m2 review 补上的**：它事实上被改写过（写死的 UTC+8 →
> 解析出的偏移量、输出英文化），却既没有映射行、也没有 `🔻` 标注，而上面这句话当时就写着
> 「每一个的定义处都带着 🔻」。⭐ **一处漏标同时把三句声称变成假的**——本节这句、
> 开篇「任何一行都能核对」那句、以及交付报告里「全部 96 个函数都有映射」那句。
> ⇒ 增删重写函数时，**这张表、映射表、定义处的 `🔻` 三者必须同时改**。

| here / 本仓 | baseline / 基线 | removed / 删掉的 |
|---|---|---|
| `quota_usage_interval_adaptive` (`lib/monitor.sh`) | `sentinel-quota:1872–1936` | 3 of 4 speed-up sources: screen-banner pressure, concurrency count, pending deliveries |
| `quota_refresh_force_due` (`lib/state.sh`) | `sentinel-quota:2746–2775` | 2 of 3 triggers: banner self-report, concurrency jump |
| `quota_read_once` (`lib/state.sh`) | `quota_poll_once`, `sentinel-quota:4069–4275` | dead-session reaping, banner sampling, and the whole switching half |
| `account-probe` main flow | `claude-account-probe:294–379` | multi-account discovery (needs the switching tool) and the container liveness probe (needs Docker, and writes credential copies to disk) |
| `quota_cmd_status` (`quota-sentinel`) | `sentinel-quota:4853–4936` | the fixed UTC+8 in the header line; plus the recent-switches list and the banner-sample line, which went with the features they belong to |

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
