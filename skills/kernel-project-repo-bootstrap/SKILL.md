---
name: kernel-project-repo-bootstrap
description: 用于为小米 17（SM8850 / Linux 6.12）的自编译内核工程另建一个独立 GitHub 仓库、给内核工程仓定名、决定内核仓用什么许可证、挑选可搬用的上游补丁、写明补丁来源、或要把内核的 patch / 配置 / 构建脚本与 skill 仓分开存放时。当手机上需要 clone 内核工程、或手机 agent 要新建一个仓库来放内核改动时使用。
---

# 内核工程仓：另建、定名、上锁、写来源

## Overview

> **许可证边界就是仓库边界。** skills 仓是 MIT 且不含上游代码；内核工程必然含 GPL-2.0 派生的补丁、配置与脚本，两者不能同仓。

还有一条更要紧：**skills 是手机 agent 自己的安全护栏。** 让它能往同一个仓推东西，等于让它能改写自己的护栏。所以内核工程必须是另一个仓，且手机端在那个仓里的权限要明确限制。

**本 skill 全部内容来自一个已跑通的范本仓**（`xiaomi17-kernel`：patch stack、GPL-2.0-only、实测开机 `boot_index` 365 / 367 / 372）；下文凡标「实测」的都是该仓里的真实内容，不是推测。

**写作纪律：示例里不放个人账号名。** 需「构建者自带后缀」处一律写 `${YOUR_TAG}`（它进内核版本串 `6.12.69-android16-6-4k-${YOUR_TAG}`），这是**内核身份守卫**的判据：确认 `uname -r` 里那个内核是你编的，而非残留的上一版。**每个构建者取自己的值，不要照抄别人的。**

## 细节在 references/

补丁来源头四套体系与逐字段说明 → `references/patch-provenance.md`
`git apply` / `git am` / `git quiltimport` 的取舍与坑 → `references/applying-patches.md`
ruleset 字段与「锁的强度 = token 权限」 → `references/ruleset-limits.md`
范本仓 `xiaomi17-kernel` 的目录与许可证布局 → `references/repo-case-study.md`

## When to Use

- 要给内核工程建仓、定名（或犹豫「放 skills 仓里还是新仓」）、决定内核仓的 `LICENSE` 或按目录区分许可证。
- 要把 KernelSU / SUSFS 这类上游补丁收进 patch stack、写补丁来源头，或要给内核仓上锁（branch ruleset）并给手机端配 token 权限。
- 手机上要 clone 内核工程，但不知道该 clone 什么、也不知道该 pin 什么。

**何时不用**：只是要跑云端构建（去 `kernel-build-ci-actions`）；还没确定用哪棵源码树（先去 `android-kernel-build-on-device`）；要刷机（去 `safe-kernel-flash`）。

## 第零步：建仓不可逆，先过两道闸

**闸门一：token 有权删仓库吗？** `gh auth status` 的 `Token scopes` 就是答案。没有 `delete_repo` 就意味着**建错了删不掉**，只能 `gh repo rename`（GitHub 保留重定向）。仓名必须在建之前和用户确认。

**闸门二：名字被占用了吗？** `gh api repos/<owner>/<name> >/dev/null 2>&1 && echo TAKEN || echo free`（404 时退出码 1，所以这个写法可靠）。

**仓名规则**：从机型名推导，不要用未经实机确认的代号。✅ `xiaomi17-kernel`；❌ `pudding-kernel`（代号可能还是 UNKNOWN）。冲突时不要加 `2`、`test` 尾巴——那会让「哪个才是真的」永久含混。

## 第一步：`versions.lock` 是唯一真相来源

**只写分支名不写 SHA 等于没有 pin。** 上游一推新 commit，构建就不再可复现，失败现场无法复原。范本仓的 lock 是**分段**的，段名本身就是模板：

| 段 | 放什么 |
| --- | --- |
| `[upstream]` | `name` / `url` / `branch` / `commit` / `commit_msg` / `commit_date` / `license` |
| `[verification]` | **`verified_on` + `verify_cmd`**（见第二步） |
| `[tree]` | `sublevel`（与设备原厂对齐的那一位）、路径数 |
| `[toolchain]` | `clang_version` / `clang_string` / `rust_version`，须与上游 `build.config.constants` 一致 |
| `[artifacts]` | `kernel_version_string` / `image_md5` / `package_md5` / `boot_index`，外加历史构建的注释条目 |
| `[device]` | KMI 世代与其来源命令（**不写序列号 / IMEI**） |
| `[abi_baseline]` | 四项 ABI 判据的基线值（细节属 skill `gki-abi-verification`） |

文件头部必须自带这三条规则，**逐字照抄**：

```
#   - 只写分支名不写 SHA 等于没有 pin（上游一动，构建不可复现）
#   - 改动任何一行 = 一次新的构建，必须重跑 ABI 校验并单独记录
#   - Release 正文必须内嵌本文件全文（GPL-2.0 对应源码指认）  ← 不是可选项
```

用一个小 `awk`（`/^\[/` 换段、匹配 `^key =`）按 `[段] key = value` 取值，别把它解析成 shell 变量。

## 第二步：pin 的粒度——四元组 + 验证记录

`[upstream]` 里 pin 的**不是一个 SHA，是四元组**，再加 `[verification]` 记录**验证日期与验证命令**：

```ini
branch      = android16-6.12-2026-03
commit      = 58ee67741556c83c523f48518284c4a6b1ef31d6   # 40 位
commit_msg  = Add Re-Kernel & Re-Kernel netlink support   # git log -1 --format=%s
commit_date = 2026-03-16T20:30:12Z                        # git log -1 --format=%cI

[verification]
verified_on = 2026-10-08
verify_cmd  = git ls-remote <url> refs/heads/<branch>
```

`commit_msg` / `commit_date` 让你在**离线**（手机端）也能判断 lock 里那个 SHA 是不是你以为的那个；**只有 `commit` 是内容寻址、真正可复现的**。**分支是会动的指针**，脚本必须断言，不符就按 SHA 精确检出：

```bash
ACTUAL=$(git -C src rev-parse HEAD)
if [ "$ACTUAL" != "$UP_COMMIT" ]; then
  git -C src fetch --depth=1 origin "$UP_COMMIT" && git -C src checkout --detach FETCH_HEAD
  [ "$(git -C src rev-parse HEAD)" = "$UP_COMMIT" ] || { echo "SHA 不匹配，停"; exit 1; }
fi
```

反直觉的实测点：`git ls-remote` 发现**远端已移动不是错误**——pin 的是历史 commit，仍可复现，脚本只打 `WARN` 继续；真正的失败条件是 `rev-parse HEAD` != lock。

## 第三步：许可证——按目录划分的三件套

| 路径 | 许可证 | 为什么 |
| --- | --- | --- |
| 仓库根 `LICENSE` | **GPL-2.0-only** | 整树默认 |
| `scripts/` / `config/` / `versions.lock` | **MIT** | 独立原创的构建脚本、配置增量片段、数据文件 |
| `docs/` | **CC-BY-4.0** | 文档 |
| 其余（含将来的补丁） | **GPL-2.0-only** | 演绎作品，跑不掉 |

三件一起做才成立：① 根 `LICENSE` = GPL-2.0-only；② 一份 `LICENSE-NOTICE.md`（**目录 → 许可证对照表**），README 里放同一张表；③ 能写注释的文件加一行 SPDX —— `# SPDX-License-Identifier: MIT`（shell / Python）、`<!-- SPDX-License-Identifier: CC-BY-4.0 -->`（Markdown）。

- **补丁跑不掉 GPL**：补丁是 GPL-2.0 内核源码的**演绎作品**——diff 里的上下文行与被删行本身就是 GPL-2.0 代码；**脚本与 config 可以另用许可证**，它们是**独立原创作品**，不是内核的演绎。先例：Yocto recipe style guide 要求「recipes、配置文件与脚本的许可证也应被清楚标明」；OE-Core 同时收录 GPL-2.0-only 与 MIT 两份文本，并用 LICENSE 文件解释归属。

用 `GPL-2.0-only` 而不是 `-or-later`：上游 `COPYING` 逐字写着 `SPDX-License-Identifier: GPL-2.0 WITH Linux-syscall-note` 与 **"version 2 only"**，从未授予 "or later"。`gh repo create --license gpl-2.0` 有效，但**不要**和 `--source=.` 一起用（两个 LICENSE 来源会打架）。**mailbox 格式的补丁放不下干净的 SPDX 注释行**，其许可证靠文件内的来源头（见第四步）+ 仓库 LICENSE 承载。若只想「简单、不自找麻烦」，就整仓统一 GPL-2.0-only，在 README 里说明脚本也可按 MIT 使用——双许可证是给自己挖坑，除非你确实需要。

### 地雷：不是所有「内核补丁」都能以 GPL-2.0 分发

`tiann/KernelSU` 被 GitHub 识别为 **GPL-3.0**：README 原文说 `kernel/` 目录下是 **GPL-2.0-only**，其余是 **GPL-3.0-or-later** → **只有 `kernel/` 可以搬**。`simonpunk/susfs4ksu` 托管在 GitLab（GitHub 上 404），其 `LICENSE` 是 **GPLv3 全文**、没有 "only" / "or later" 限定词 → 意图 **UNVERIFIED**，先查清再搬。

kernel.org 的 `license-rules`：内核整体是 GPL-2.0 **only**，许可证不同的文件「必须与 GPL-2.0 兼容」，兼容集是 **GPL-1.0+、GPL-2.0+、LGPL-2.0、LGPL-2.0+、LGPL-2.1、LGPL-2.1+**——**GPL-3.0 不在其中**；而 GPLv3 §5 要求以该许可证授权 "the entire work, as a whole"。**所以把 GPLv3-only 的补丁贴进 GPL-2.0-only 的内核源码，是真实的、非外观性的冲突。动手前逐个查补丁文件自己的头部注释和所在子目录，不要相信仓库首页那个总的 license 徽章。**

`Signed-off-by` 是 **DCO 认证，不是再分发许可证**。AOSP Common Kernel 要求所有补丁带 `Change-Id:`，且 author 与 submitter 都要 `Signed-off-by:`。收别人的补丁进你的 stack 时：**原样保留原作者的全部 `Signed-off-by` 与 `Change-Id`**，自己经手再加一条。改掉原来的 sign-off 等于伪造认证。

## 第四步：做成 patch stack，不要 fork

实测路径数：上游 `aosp-mirror/kernel_common` **72,991** 条路径（纯 AOSP，编出来开不了机）；可用的厂商适配树**约 87,186** 条、本地检出 **1.9 GB**。fork 出来是 GB 级，手机上 clone 不动，而且 GitHub 会**永久**打上 fork 关系。正确形态是只 pin SHA + 存补丁/配置/脚本：

```
versions.lock                   # ★ 唯一真相来源
patches/<topic>/NNNN-slug.patch # 逐个补丁，文件内自带来源头
patches/<topic>/series          # 应用顺序，一行一个文件名
config/<name>.fragment          # 只写增量
scripts/{fetch-sources,apply-patches,build}.sh   # 取源码+断言 / 按 series 应用 / 编译
CONTRIBUTING.md                 # 证据规则（见第七步）
.github/workflows/build.yml     # workflow_dispatch 触发
```

### 补丁头：没有标准，四套公认做法可以叠加

**不存在 `patches.json` 这类标准。** 在用的是四套：**DEP-3**（Debian 提案，ACCEPTED，兼容 `git format-patch`；`Description`/`Subject` 与 `Origin` 必填，如 `backport, https://github.com/<up>/commit/<sha>`；解析到第一个空行或 `---` 为止）、**Yocto / OE** 的 `Upstream-Status:`（`Pending`/`Submitted`/`Accepted`/`Backport`/`Denied`/`Inactive-Upstream`）、**AOSP kernel/common** 的 `Change-Id:` + 双 `Signed-off-by:`、**quilt `series`**（一行一个补丁，顺序即契约）。

**推荐组合**（每个补丁都带这四行）：

```
Origin: backport, https://github.com/<owner>/<repo>/commit/<sha>
Upstream-Status: Backport
Signed-off-by: <原作者>
Change-Id: <原 Change-Id>
```

CI 断言：`series` 里每个文件都存在且能应用；每个补丁都有 `Origin` 与 `Upstream-Status`；`Origin` 里的 SHA 真是上游的（`git merge-base --is-ancestor <sha> HEAD`）；许可证属于内核的兼容集。可以另生成 `provenance.json` 当**审计产物**，但**不要让 JSON 成为唯一真相来源**——补丁文件本身才是。

## 第五步：fetch 上游 + 断言清单

实测于 2026-10-07，对象 73k 路径的上游树：`clone --depth 1` 38.4 s / 完整 blob 一个 pack；`clone --filter=blob:none --no-checkout --depth 1` 10.4 s / 2.9 MB（只有 commit 和 tree）。**一条被实测推翻的流传说法**：「`--depth 1` 检出不了任意 SHA」——检出不行，但**取**可以：**`git fetch --depth 1 origin <sha>` 对 tip、同分支非 tip（3.2 s）、跨分支的 SHA 都能成功取到**，不必为 pin 一个 SHA 上 blobless。**`git clone --revision` 需要 git ≥ 2.49**（Ubuntu 24.04 是 2.43，手机多半没有）。**也别做**：`--filter=blob:none` 之后再检出整个工作区——73k 文件会退化成逐个 blob 懒加载，实测在子目录上报 `error: unable to read sha1 file of scripts/atomic/atomic-tbl.sh`。

### 取完源码要跑的断言——识别「这棵树能不能用」的廉价探针

范本仓的 `scripts/fetch-sources.sh` 每次取完都跑这套，**值得整份抽成模板**：

| 断言 | 命令 / 写法 | 抓什么 |
| --- | --- | --- |
| **SHA** | `git rev-parse HEAD` == lock 的 `commit` | 分支漂移 |
| **SUBLEVEL** | `awk '/^SUBLEVEL/{print $3}' src/Makefile` == lock 的 `tree.sublevel` | 版本号与设备原厂对不上 |
| **关键文件存在性** | 逐个 `[ -e ]`：`arch/arm64/configs/gki_defconfig`、`_setup_env.sh`、`gki/aarch64/abi.stg`、`build.config.gki`、`build.config.constants` … | 树不完整 / 稀疏检出 |
| **血统标志 grep** | `grep -m1 GKI_HACKS_TO_FIX`、`GKI_TASK_STRUCT_VENDOR_SIZE_MAX`、`GCMA`、`RT_SOFTIRQ_AWARE_SCHED` 于 `gki_defconfig` | **这棵树有没有厂商适配层** |
| **路径数** | `find src -path src/.git -prune -o -type f -print \| wc -l` | 与 lock 记录的量级对照 |

> **核心洞见：「关键文件存在性 + 血统标志 grep」是判断一棵源码树能不能用的廉价探针。**
> 全量编译 6 分钟起、刷机冒变砖风险，而这两条断言只要几秒。缺 `_setup_env.sh` / `abi.stg`，或 `gki_defconfig` 里 grep 不到厂商标志——这棵树**根本不该进入编译阶段**。把检查放进 `fetch-sources.sh`，别等编译或上机之后才发现。

## 第六步：应用补丁——`quiltimport` 优先，别指望 fuzz

| 命令 | 保留作者与 commit message | 需要邮件头 | 上下文不匹配时 |
| --- | --- | --- | --- |
| `git apply` | ❌ 不建 commit | ❌ 不需要 | **直接失败。git 没有 fuzz 因子**（只有 `-C1`/`-C0` 可放松，默认一行都不忽略） |
| `git am` | ✅ 保留 author / date / message | ✅ 需要 | 失败；可用 `-3` 三方合并 |
| `git quiltimport` | ✅ | quilt `series` | 它就是为「把 quilt 补丁集打成一个分支」设计的 |

**首选 `git quiltimport`**（git 自带命令）：`git -C src quiltimport --dry-run --patches "$PWD/patches" --series "$PWD/patches/series"`，去掉 `--dry-run` 即正式应用。它保留补丁边界、顺序与描述。手写循环则必须 fail-loud：`apply --check` 先于 `am --3way`，任一不干净立即退出。

**`--3way` 与浅克隆 / 部分克隆不兼容**：`git apply -3` / `git am -3` 需要**本地存在补丁所记录的 blob**，否则报

> `error: repository lacks the necessary blob to perform 3-way merge.`

所以：**要么 `--3way` 配完整 clone，要么 blobless clone 配纯 `git apply`（不带 -3）**。另外：`git apply --whitespace` 默认 **`warn`**（有警告仍会应用），要「有问题就停」就写 `--whitespace=error`；`git am --reject` 与三方合并**互斥**。

## 第七步：`CONTRIBUTING.md` 的约定可以直接当范本

核心原则：**证据优先于解读**——**提交消息里的数字必须是命令输出，不是记忆**。✗「应该能开机了」→ ✓ `uname -r` = `6.12.69-android16-6-4k-${YOUR_TAG}`、`boot_index` 365、模块数 670；✗「ABI 已经对齐」→ ✓ `Module.symvers` vs `abi.stg`：MATCH 10235 / DIFF 0 / MISSING 0；社区传言要引用来源并标注 `UNVERIFIED`。

- **严格区分 `UNVERIFIED` 与 `UNKNOWN`**：前者是**有假设但没测过**（例：SPL 对齐的影响），后者是**完全没拿到数据**（例：`fastboot getvar anti` 的值）。不允许用「应该差不多」填空。
- **一次只改一个变量**：加配置要**一项一个 fragment**（`zram.fragment` / `scheduler.fragment` / `f2fs.fragment`），单独编译、单独验证、单独记录，否则出问题无法定位是哪一项导致的。

```
[build] 升级上游到 <branch> @ <sha>     — 编译未验证
[flash] 实测开机成功 boot_index <N>     — 已上机验证，必须带实测证据
[cfg]   加 zram.fragment（zstd 默认）   — 单项配置改动
[docs]  ... / [fix] 修正 <xxx>

main    ← 只放已验证可开机的版本，受 ruleset 保护；dev/* ← 试验性改动
```

流程：从 `main` 切 `dev/<主题>` → 跑 `bash scripts/verify-abi.sh`（**四项必须全过**）→ 开 PR，描述里贴**命令输出** → 合并前 ABI 四项全过 +（涉及内核改动时）已上机验证。**不要直接推 `main`。** 设备实测事实是**快照**，一次 OTA 就失效：属于运行时产物，不要写成 skill 正文常量。

## 第八步：上锁，并知道这把锁的极限

**前提**：仓库至少有一个 commit，ruleset 才有意义。

```bash
gh api -X POST repos/<owner>/<repo>/rulesets --input /tmp/protect-main.json
gh api repos/<owner>/<repo>/rules/branches/main   # 查生效的规则（`gh ruleset check` 也可，只读）
```

`/tmp/protect-main.json` 的关键字段：

```json
{ "name": "protect-main", "target": "branch", "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "bypass_actors": [],
  "rules": [ { "type": "deletion" }, { "type": "non_fast_forward" }, { "type": "required_linear_history" },
             { "type": "pull_request", "parameters": { "required_approving_review_count": 0,
                 "dismiss_stale_reviews_on_push": true, "require_last_push_approval": true,
                 "required_review_thread_resolution": true } } ] }
```

- `deletion` 禁删分支；`non_fast_forward` 禁 force push；`required_linear_history` 禁 merge commit。
- `required_approving_review_count: 0` **仍然要求走 PR**，只是不要求谁来批准——桌面 + 手机两个写入者的场景正合适。
- **`require_last_push_approval: true` 是最要紧的一条**：没有它，同一个身份可以自己开 PR、自己批准、自己合。
- `bypass_actors: []` 必须显式写空数组。返回值里出现 `"bypass_actors":[]` 与 `"current_user_can_bypass":"never"` 才说明连 owner 的 git push 也被拦。`~DEFAULT_BRANCH` 比写死 `refs/heads/main` 更稳（`*` 不跨 `/`）。**`gh ruleset` 只能读**，创建与修改必须走 `gh api`。

### 极限：锁的强度 = token 的权限，不是 ruleset 本身

ruleset **拦得住 git push，拦不住 API**：同一个 admin token 直接 `gh api -X DELETE repos/<owner>/<repo>/rulesets/<id>` **会成功**，锁当场消失。创建 / 更新 ruleset 需要 **Administration: write**——手里有这个权限的人，就能把规则删掉或改成 `"enforcement": "disabled"`。对策：

| 做法 | 为什么 |
| --- | --- |
| 规则放**组织**层（`POST /orgs/<org>/rulesets`，需 org 的 Administration write） | 组织规则覆盖仓库规则并取最严；只给单仓权限的 token 管不到 |
| 手机端换 **fine-grained PAT**：`Contents` + `Pull requests` + `Actions` 写权限，只在必须改 workflow 时加 `Workflows` | **绝不给 `Administration`**；更好的选择是 **GitHub App installation**——它的 token 不自带 Administration，Actions 里的 `GITHUB_TOKEN` 默认也没有 |
| **绝不**把 agent 的 deploy key 或 App 加进 bypass 列表 | `bypass_actors` 接受 `DeployKey`、`Integration` 等类型 |

三个容易搞错的点：**推 `.github/workflows/` 下的文件是另一项授权**——fine-grained 下 `Contents: write` **不够**，还要 `Workflows: write`（`workflow_dispatch` 另需 `Actions: write`）；旧的分支保护 API 里 **`enforce_admins` 默认 false**（管理员被豁免），必须显式设 `true`；ruleset 公开仓库免费，私有仓库需 Pro / Team / Enterprise Cloud，每仓最多 75 条。

## 第九步：仓库里永远不该有的东西

上游内核源码树（手机 clone 不动，也是「不要 fork」的理由）；`out/`、`*.img`、`*.ko`（二进制走 Release）；AVB 签名私钥 `*.pem` / `*.pk8`（泄露即设备签名密钥泄露）；**厂商专有二进制模块**（如 `msm_drm.ko` / `qcom_va_minidump.ko`，Qualcomm 专有、**不可再分发**，只能留在设备上做 ABI 校验基准）；从厂商 OTA 镜像提取的文件（如 `*.img.config.txt`，直接再分发有风险，改为在 `analysis/` 里以**对比结论**记录）；设备标识（序列号、IMEI、账号、个人路径、`device-profile.md` / `build.env`——进了 git 历史就删不干净）；预编译工具链与大体积取证中间产物（分区 dump、`strings` 输出：GB 级，结论进 `docs/` 后即删——范本仓一次清理释放 865 MB）。

`.gitignore` 必须显式包含 `out/`、`*.img`、`*.ko`、`*.pem`、`*.pk8`。若要留一份**删除记录**，写成 `docs/CLEANUP-LOG.md`。

## Common Mistakes

| 做法 | 后果 |
| --- | --- |
| 把内核工程塞进 skills 仓 | 要么整仓改 GPL-2.0，要么做没人维护的按目录许可；更糟的是手机 agent 能改自己的护栏 |
| 改掉原作者补丁里的 `Signed-off-by` / `Change-Id` | `Signed-off-by` 是 DCO 认证，不是可替换的署名 |
| 只 pin 分支名不写 SHA / 只写 `commit` 不写 `commit_msg`+`commit_date` / 缺 `[verification]` | 上游一动构建不可复现；离线时无法核对 SHA；没人知道 pin 是哪天用什么命令验的 |
| `--filter=blob:none` 之后检出工作区；在 blobless / shallow 仓上 `--3way` | 逐 blob 懒加载报 `unable to read sha1 file`；`--3way` 报 lacks the necessary blob |
| 建仓前不查仓名；用 admin token 却指望 ruleset 兜底 | token 无 `delete_repo` 就删不掉；同一个 admin token 能 `DELETE` 掉 ruleset |
| 只给 `Contents: write` 却要让 agent 推 workflow 文件；开了 ruleset 但没开 `require_last_push_approval` | 推 `.github/workflows/` 还需 `Workflows: write`；否则同一身份能自己开 PR、自己批准、自己合 |
## 先确认再动手（不可逆动作清单）

必须**先拿到用户的明确确认**：① `gh repo create`（建错删不掉）；② 改仓库可见性（public 转 private 会让已有 clone 与镜像失效）；③ 推送第一个 commit（之后 `LICENSE` 与 `versions.lock` 的内容都进了历史）。可以本地无限重来的是：写文件、`git init`、`git commit`。所以顺序永远是**先在本地做完，最后一次性 `gh repo create --source=. --push`**。

## Real-World Impact

**这件事真的发生了。** 手机侧 agent 按本 skill 的指导建出了 `xiaomi17-kernel`，它成为这类仓库的**可用范本**：patch stack 形态、GPL-2.0-only 根许可证 + 按目录划分、分段式 `versions.lock`、带断言清单的 `fetch-sources.sh`、`CONTRIBUTING.md` 的证据规则，以及实测开机三连（`boot_index` 365 / 367 / 372）。

RED 基线（一个没有这个 skill 的 agent，被要求「建内核工程仓」）表现**相当好**：它选对了 GPL-2.0、patch stack、pin SHA、排除清单。所以本 skill 的价值集中在它说错、以及它**不知道自己不知道**的地方：

1. 它推荐 `--filter=blob:none --no-checkout` + `git checkout <sha>`，并断言「普通 `--depth 1` 检不出任意 SHA」——**后半句被实测推翻**；前半句是性能陷阱。
2. 它在 ruleset 里**主动放弃**了 required PR，理由是「会锁住单人开发」——而这个仓恰恰有**两个写入者**（桌面 + 手机），护栏要防的就是第二个。
3. 它（和基线一样）把「内核补丁都是 GPL-2.0」当前提：KernelSU 只有 `kernel/` 是 GPL-2.0-only，`susfs4ksu` 的 LICENSE 是 GPLv3 全文，而 GPL-3.0 **不在** kernel.org 的 GPL-2.0 兼容集里。
4. 它只把 `versions.lock` 当成「写个 SHA 的地方」：没有段结构、没有 `[verification]`、没有三条自带规则，也没把「关键文件 + 血统标志」当成取源码后的廉价探针。

完整的四条记录见本 skill 目录下的 `references/repo-case-study.md`。一条忠实的基线结论：**当基线已经做对了大部分事，skill 就应该只写它做错的部分，而不是把它的正确做法抄一遍充数。**
