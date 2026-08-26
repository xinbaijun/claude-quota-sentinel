# claude-quota-sentinel

> 🚧 **Skeleton / 骨架阶段** — this file is an outline only. Every section below is a
> placeholder to be filled in a later milestone; nothing here is documentation yet.
> 本文件目前只有大纲，各节均为占位，正文留待后续里程碑补齐。

Watch Claude account quota, switch accounts when a threshold is hit, and keep an audit
trail of every switch.
监控 Claude 账号额度，到阈值自动切号，并为每次切换留下可追溯的账目。

## What it solves / 解决什么

*(placeholder / 占位)*

## What it does NOT solve / 不解决什么

*(placeholder / 占位)*

## Known failure modes / 已知会怎么坏

*(placeholder / 占位)* — every guard in this project exists because something actually
broke once; the incident notes travel with the code.
本项目的每一条守卫背后都有一次真实事故，事故记录随代码一起保留。

## Requirements / 运行前提

*(placeholder / 占位)* — Linux only for now; macOS and Windows are **unverified**.
暂时只保证 Linux；macOS 与 Windows 标为**未验证**。

## Install / 安装

*(placeholder / 占位)*

## Usage / 使用

*(placeholder / 占位)*

## Testing / 测试

*(placeholder / 占位)* — the regression suite ships with **positive controls**: every
guard must be able to prove that it goes red.
回归套件随附**正控**：每条守卫都要能证明它会红。

## Prior art / 相关项目

*(placeholder / 占位)*

## Provenance / 抽取来源

Extracted from a private in-house fleet-automation codebase at commit `e2f32279`.
Upstream changes after that commit are **not** tracked and **not** synced back.
抽取自内部私有编队自动化代码库的 `e2f32279`；该 commit 之后的上游改动**不追平、不双向同步**。

### Note for maintainers — how to copy source files / 维护者须知：源文件怎么复制

**Always extract with `git show e2f32279:<path>`. Never `cp` from a working tree.**
**一律用 `git show e2f32279:<path>` 取文件，绝不从工作树 `cp`。**

The upstream repo stays under active development, so its working tree drifts away from
the baseline continuously — during the survey milestone alone the baseline moved three
separate times within half an hour. A file copied from a working tree therefore does
**not** match the `e2f32279` this section claims, and nothing will report the mismatch:
the copy succeeds, the tests still pass, and the only symptom is that the provenance
sentence above has quietly become false.

上游仓仍在持续开发，工作树与基线时刻在漂移——仅盘点里程碑期间，半小时内基线就真实变了
三次。从工作树 `cp` 出来的文件因而与本节声称的 `e2f32279` 对不上，而且**这种错不会报错**：
复制成功、测试照绿，唯一的表现是上面那句 provenance 在很久以后变成了假话。

This rule has no expiry: it applies to every later extraction, not just the first batch.
本规则长期有效，适用于此后每一次抽取，不限于第一批。

## License / 许可证

MIT — see [LICENSE](LICENSE).
