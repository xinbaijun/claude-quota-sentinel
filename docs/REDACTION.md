# Redaction / 脱敏说明

The code in this repository was extracted from a private codebase that ran against
real Claude accounts. This file records what was removed, how, and how you can check
that it stayed removed.
本仓的代码抽取自一个跑在真实 Claude 账号上的私有代码库。本文件记录删掉了什么、怎么删的、
以及你怎么核实它一直没回来。

## The rule / 规则

No real account address, no credential, no internal path, and no internal hostname may
appear anywhere in this repository — **including in comments, in test fixtures, and in
git history**.
任何真实账号地址、凭据、内网路径、内部主机名都不得出现在本仓的任何地方——**包括注释、
测试夹具与 git 历史**。

## Why the comments could not simply be deleted / 为什么不能靠删注释脱敏

Almost every real account name in the source appeared inside an **incident note** — a
comment recording something that actually broke, and why a given guard exists because
of it. Those notes are the most valuable thing in this codebase; a guard whose reason
has been deleted is a guard the next person will remove as pointless.
源码里几乎每一处真实账号名都出现在**事故注释**里——记录真实坏过一次、以及某条守卫因此
存在的注释。那些注释是这份代码里最值钱的东西；一条理由被删掉的守卫，下一个人会当作
无用把它删掉。

So the names were **rewritten, not stripped**. Each real account became a stable
placeholder, and the same account maps to the same placeholder everywhere — otherwise
a sequence like "account X went 97% → 0% → 97%" stops being readable as one story.
所以人名是被**改写**的，不是被剥掉的。每个真实账号对应一个稳定占位符，且同一账号在全仓
映射一致——否则「某账号 97% → 0% → 97%」这种事故序列会读不成一条线。

| placeholder / 占位符 | what it stands for / 代表什么 |
|---|---|
| `accountA` … `accountE` | distinct real accounts in the source environment / 源环境里几个不同的真实账号 |
| `example.com` addresses | RFC 2606 reserved documentation domain; never a real host / RFC 2606 保留的文档域名，永远不是真实主机 |

The real-name → placeholder table is **deliberately not in this repository**. Publishing
the table would publish exactly the strings the redaction removed. It lives in
`tools/alias-map.local.txt`, which is gitignored, and it can be rebuilt from the
baseline by anyone with access to the source repository.
真名 → 占位符的对照表**刻意不在本仓**：把表发出来等于把脱敏删掉的那些串再发一遍。
它在已被 gitignore 的 `tools/alias-map.local.txt` 里，任何能访问源仓的人都能从基线重建。

## What else was parameterised / 还参数化了什么

These were not secrets, but they were **true on exactly one machine** and false
everywhere else — which is its own kind of defect in a tool other people run.
这些不是凭据，但它们**只在一台机器上为真**，在别处一律为假——对一个别人也要跑的工具来说，
那本身就是一类缺陷。

| was / 原来 | now / 现在 |
|---|---|
| a machine-local HTTP proxy baked into the launch command | `QUOTA_MONITOR_PROXY`, empty by default |
| a machine-local proxy in the probe | `PROBE_PROXY`, empty by default |
| `/root/.claude.json` (assumes running as root) | follows `$HOME` |
| a big-disk path as the temp-file fallback | `${TMPDIR:-/tmp}` |
| a hard-coded UTC+8 offset in every rendered timestamp | resolved once from the host; see `lib/config.sh` |
| the account roster as a **default value** | empty by default; supply it in the environment |
| a specific Docker container and its mount path | not extracted in this milestone |
| the private environment's root, marker file, shim names and env prefix, hard-coded in the cleanroom checks | six declared inputs, each fail-closed when unset |

## How to check it stayed removed / 怎么核实它没回来

```sh
tools/dod4-scan.sh            # five ranges: worktree, every blob, messages, identity, paths
tools/dod4-scan.posctrl.sh    # prove each of those five ranges actually goes red
```

⚠️ **A working-tree `grep` is not this check.** It covers one range out of five and is
structurally blind to the other four. The classic pre-publication leak — committed,
noticed, deleted in the next commit — is gone from the working tree and still sitting
in the pack, where no amount of grepping the checkout will ever find it.
⚠️ **grep 工作树不等于这项检查。**它只覆盖五个范围里的一个，对另外四个结构性全盲。
开源前最经典的那种泄漏（提交了、发现了、下个 commit 删掉）已经从工作树消失，却仍躺在
对象库里，再怎么 grep 检出目录都永远看不见它。

⚠️ Site-specific patterns — the real names, your internal hostnames, your private repo
name — go in `tools/dod4-*.local.txt`, which is gitignored. They must never go in the
published `*.example.txt` files, for two reasons: it would put the hunted strings into
the repo, and the scanner would then match its own pattern file and be **permanently
red**. A check that is always red teaches people to click past red.
⚠️ 站点专有模式（真实人名、你的内部主机名、你的私有仓名）写进已 gitignore 的
`tools/dod4-*.local.txt`，绝不要写进会被公开的 `*.example.txt`。两个理由：那等于把被搜的
串放进仓里；而且扫描器会匹配到自己的模式文件从而**恒红**——一条永远红的检查会训练出
「看到红也照过」。

## What this does not cover / 它没覆盖什么

- It scans **this** repository. The source repository's own history is a separate
  question and is not addressed here.
  它扫的是**本仓**。源仓自己的历史是另一个问题，本文件不处理。
- The clean-machine sandbox (`tools/cleanroom-assert.sh`) does **not** answer this
  question. It does not isolate the network, so a hard-coded internal address would
  still connect from inside it and not a single assertion would go red. The two checks
  answer different questions; a green sandbox is never evidence of redaction.
  干净机器沙箱（`tools/cleanroom-assert.sh`）**回答不了**这个问题。它不隔离网络，
  一个写死的内网地址在箱内照样连得通，而且一条判据都不会红。两项检查答的是不同的问题；
  **沙箱全绿永远不构成脱敏已验**。
