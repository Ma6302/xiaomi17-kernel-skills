---
name: kernel-project-repo-bootstrap
description: 用于为小米 17（SM8850 / Linux 6.12）的自编译内核工程另建一个独立 GitHub 仓库、给内核工程仓定名、决定内核仓用什么许可证、挑选可搬用的上游补丁、写明补丁来源、或要把内核的 patch / 配置 / 构建脚本与 skill 仓分开存放时。当手机上需要 clone 内核工程、或手机 agent 要新建一个仓库来放内核改动时使用。
---

# 内核工程仓：另建、定名、写来源、上锁

## Overview

一条判据决定所有事：

> **许可证边界就是仓库边界。**

`xiaomi17-kernel-skills` 是 MIT，且明文不含任何上游代码。内核工程必然含 KernelSU / SUSFS、`zram-ir`、以及对 `kernel_common` 的改动——全是 GPL-2.0 派生。两者不能同仓。

还有一条比许可证更要紧的：**skills 是手机 agent 自己的安全护栏。** 让它能往同一个仓库推东西，等于让它能改写自己的护栏。所以内核工程必须是另一个仓库，且手机端在那个仓库里的权限要被明确限制。

## When to Use

- 要给内核工程建仓、或要决定仓名。
- 犹豫「内核工程放 skills 仓里还是新仓」。
- 要把 KernelSU / SUSFS / `zram-ir` 这类上游补丁收进自己的 patch stack。
- 内核仓已存在，要给它加锁（branch ruleset）或给手机端配权限。
- 手机上要 clone 内核工程，但不知道该 clone 什么。

**何时不用**：只是要跑云端构建（去 `kernel-build-ci-actions`）；还没确定用哪棵源码树（先去 `android-kernel-build-on-device`）；要刷机（去 `safe-kernel-flash`）。

## 第零步：建仓是不可逆动作，先过两道闸

**闸门一：这个 token 有权删仓库吗？**

```bash
gh auth status
```

输出里的 `Token scopes` 就是答案。没有 `delete_repo` 就意味着**建错了删不掉**，只能 `gh repo rename`（GitHub 会保留重定向）。所以仓名必须在建之前和用户确认，不能建完再改。

**闸门二：名字被占用了吗？**

```bash
gh api repos/<owner>/<name> >/dev/null 2>&1 && echo TAKEN || echo free
```

404 时 `gh api` 退出码是 1，所以这个写法是可靠的。

**仓名规则**：从 `device-profile.md` 里的**机型名**推导，不要用未经实机确认的代号。

- ✅ `xiaomi17-kernel`（机型名，实机可查）
- ❌ `pudding-kernel`（代号来自网上，`device-profile.md` 里可能还是 UNKNOWN）

仓名冲突时不要加 `2`、`test` 之类的尾巴——那会让「哪个才是真的」永久含混。改用更有区分度的后缀（如平台名）。

## 第一步：许可证——三件事，其中一件是地雷

### 1. 仓级 `LICENSE` = `GPL-2.0-only`

- 补丁是对 GPL-2.0 内核源码的**演绎作品**：diff 里的上下文行与被删行本身就是 GPL-2.0 代码，所以补丁跑不掉。
- 用 **`GPL-2.0-only`** 而不是 `GPL-2.0-or-later`：内核本身是 only，上游从未授予 "or later"。
- `gh repo create --license gpl-2.0` 是有效关键字（`gh repo license list` 可查），但**不要**和 `--source=.` 一起用——你要提交自己的 `LICENSE`，两个来源会打架。

### 2. 地雷：不是所有「内核补丁」都能以 GPL-2.0 分发

| 来源 | 许可证事实 |
| --- | --- |
| `tiann/KernelSU` | GitHub 识别为 **GPL-3.0**。README 原文：`kernel/` 目录下是 **GPL-2.0-only**，除该目录外其余是 **GPL-3.0-or-later** → **只有 `kernel/` 可以搬** |
| `simonpunk/susfs4ksu` | 托管在 GitLab（GitHub 上 404）。`LICENSE` 是 **GPLv3 全文**，没有 "only" / "or later" 限定词 → 声明的意图 **UNVERIFIED**，必须先查清再搬 |

kernel.org 的 `license-rules` 规定：内核整体是 GPL-2.0 **only**，许可证与它不同的文件「必须与 GPL-2.0 兼容」，而它列出的兼容集是 **GPL-1.0+、GPL-2.0+、LGPL-2.0、LGPL-2.0+、LGPL-2.1、LGPL-2.1+** —— **GPL-3.0 不在其中**。而 GPLv3 §5 要求以该许可证授权 "the entire work, as a whole"。

> 后果：把一个 GPLv3-only 的补丁文件贴进 GPL-2.0-only 的内核源码，是真实的、非外观性的冲突。
> **动手前逐个查补丁文件自己的头部注释和所在子目录**，不要相信仓库首页那个总的 license 徽章。

### 3. 脚本和配置片段可以不跟 GPL——但要写成「读得出来的」

补丁是演绎作品；**shell / CI 脚本与 config fragment 是独立原创作品**，不是内核的演绎，可以另用许可证。先例：Yocto recipe style guide 明确要求「recipes、配置文件与脚本的许可证也应被清楚标明，例如通过注释或层内的许可证文件」；OE-Core 同时收录 GPL-2.0-only 与 MIT 两份文本，并用 LICENSE 文件解释归属。

惯例做法是**三件一起做**才成立：

1. 仓库根 `LICENSE` = GPL-2.0-only，作为整棵树的默认；
2. `README` 里放一张**目录 → 许可证**对照表；
3. 能写注释的文件加一行 SPDX，例如 `# SPDX-License-Identifier: MIT`。

**mailbox 格式的补丁文件放不下干净的 SPDX 注释行**，所以它们的许可证靠**文件内头部**（见第二步）+ 仓库 LICENSE 一起承载。

> 忠告：如果目标是「简单、不自找麻烦」，就让**整仓统一 GPL-2.0-only**，只在 README 里说明脚本也可按 MIT 使用。双许可证是给自己挖坑，除非你确实需要。

**DCO / `Signed-off-by` 是认证，不是再分发许可证。** 内核要求提交的补丁带 `Signed-off-by`；AOSP Common Kernel 更严：**所有补丁必须带 `Change-Id:`**，且 **author 与 submitter 都要 `Signed-off-by:`**。把别人的补丁收进你的 stack 时：**原样保留原作者的所有 `Signed-off-by` 与 `Change-Id`**，你自己经手时再加一条自己的 sign-off。

## 第二步：做成 patch stack，不要 fork

**不要 fork `kernel_common`。** 它有 72,991 条路径，fork 出来是 GB 级，手机上 clone 不动，而且 GitHub 会永久打上 fork 关系。

patch stack 的形状：

```
patches/<topic>/NNNN-slug.patch   # 逐个补丁，文件内自带来源头
patches/<topic>/series            # 应用顺序，一行一个文件名
versions.lock                     # 唯一真相来源：upstream URL + ref + commit SHA
config/<device>.fragment          # 只写增量，用 merge_config.sh 合并
scripts/fetch-sources.sh          # clone 上游 + 检出 pin 死的 SHA
scripts/apply-patches.sh          # 按 series 顺序应用，任何一个不干净就失败
scripts/build.sh
.github/workflows/build.yml       # workflow_dispatch 触发
```

**`versions.lock` 是唯一真相来源。** 只写分支名（`android16-6.12`）不写 SHA 等于没有 pin——上游推一个新 commit，你的构建就不再可复现，而失败现场无法复原。

**GPL 对应源码**：Release 正文必须内嵌 `versions.lock`。pin 死的 SHA 就是对「对应的源码在哪」的指认，这不是可选项。

### 补丁头：没有标准，但有四套公认做法可以叠加

**不存在 `patches.json` 这类标准。** 野生世界里实际在用的是这四套：

| 体系 | 关键字段 | 它解决什么 |
| --- | --- | --- |
| **DEP-3**（Debian 提案，状态 ACCEPTED，且**明确兼容 `git format-patch`**） | `Description` / `Subject`（必填）、`Origin`（必填，形如 `backport, https://github.com/<up>/commit/<sha>` 或 `commit:<id>`；前缀可取 `upstream,` / `backport,` / `vendor,` / `other,`）、`Forwarded`、`Last-Update` | **机器可校验**的来源指认 |
| **Yocto / OE** | `Upstream-Status:` ∈ `Pending` / `Submitted` / `Accepted` / `Backport` / `Denied` / `Inactive-Upstream` | 让「这个补丁以后怎么办」有答案 |
| **AOSP kernel/common** | `Change-Id:` + `Signed-off-by:`（author 与 submitter）、前缀 `ANDROID:` / `FROMGIT:` / `FROMLIST:` / `BACKPORT:` | 上游事实 |
| **quilt `series`** | 一行一个补丁名，决定应用顺序 | 顺序本身就是契约 |

DEP-3 的解析规则与 `git format-patch` 一致：RFC-2822 风格头部，解析到**第一个空行**为止，`---` 之后不再解析。所以 DEP-3 头可以直接写进 `git format-patch` 产出的邮件里，两者不冲突。

**推荐组合**（每个补丁都带这四行）：

```
Origin: backport, https://github.com/tiann/KernelSU/commit/<sha>
Upstream-Status: Backport
Signed-off-by: <原作者>
Change-Id: <原 Change-Id>
```

CI 应当断言：`series` 里每个文件都存在且能应用；每个补丁都有 `Origin` 与 `Upstream-Status`；`Origin` 里的 SHA 真的是上游的（`git merge-base --is-ancestor <sha> HEAD`）；许可证属于内核的兼容集。

可以另生成一个 `provenance.json` 当**审计产物**，但**不要让 `provenance.json` 成为唯一真相来源**——补丁文件本身才是。

## 第三步：fetch 上游的正确写法（这里有一个实测会翻车的组合）

以下数据实测于 2026-10-07，对象 `aosp-mirror/kernel_common@android16-6.12`（73k 路径）：

| 命令 | 实测结果 |
| --- | --- |
| `git clone --filter=blob:none --no-checkout --depth 1 --branch X` | 10.4 s，2.9 MB——**只有 commit 和 tree，没有工作区** |
| `git clone --depth 1 --branch X` | 38.4 s，完整 blob 一个 pack |
| `git fetch --depth 1 origin <sha>` | 成功。**tip、同分支非 tip（3.2 s）、跨分支的 SHA 都能取** |

> **别做**：`--filter=blob:none` 之后再检出整个工作区。73k 个文件会退化成逐个 blob 的懒加载——实测在子目录上就报
> `error: unable to read sha1 file of scripts/atomic/atomic-tbl.sh`。

**推荐写法**（快、只有一个 pack、SHA 可校验）：

```bash
git clone --depth 1 --branch <branch> <upstream-url> src
git -C src fetch --depth 1 origin <pinned-sha>
git -C src checkout --detach FETCH_HEAD
[ "$(git -C src rev-parse HEAD^{commit})" = "<pinned-sha>" ] || { echo "SHA 不匹配，停"; exit 1; }
```

**一条被实测推翻的流传说法**：「`--depth 1` 检出不了任意 SHA」。检出确实不行，但**取**可以——`git fetch --depth 1 origin <sha>` 对 tip、非 tip、跨分支 SHA 全部成功。所以不需要为了 pin 一个 SHA 去用 blobless 那套。

**关于 `git clone --revision <sha>`**：这个选项确实存在（本机 git 2.52 的 `clone -h` 里有 `--[no-]revision <rev>  clone single revision <rev> and check out`），但**需要 git ≥ 2.49**。Ubuntu 24.04 自带 git 2.43，手机上大概率也没有 → **不要把方案建立在它上面**，用上面的 `clone --branch` + `fetch --depth 1 origin <sha>`。

**pin 什么**：分支名（`android16-6.12`）是会动的指针，不可复现；tag 比分支好，但只是「约定上不可变」，force push 一样能移动它；**只有 commit SHA 是内容寻址、真正可复现的**。所以 `versions.lock` 写 SHA，并在 CI 里断言。需要一个稳定的 tag 时，AOSP 发的是 `android16-6.12.<minor>_r00` 这种形式（实测存在，例如 `android16-6.12.52_r00`）。

## 第四步：应用补丁——`quiltimport` 优先，别指望 fuzz

三条路，差别是真实的：

| 命令 | 保留作者与 commit message | 需要邮件头 | 上下文不匹配时 |
| --- | --- | --- | --- |
| `git apply` | ❌ 不建 commit | ❌ 不需要 | **直接失败。git 没有 fuzz 因子**（只有 `-C1` / `-C0` 可放松，默认一行都不忽略）|
| `git am` | ✅ 保留 author / date / message | ✅ 需要 | 失败；可用 `-3` 三方合并 |
| `git quiltimport` | ✅ | quilt `series` | 它就是为「把 quilt 补丁集打成一个分支」设计的 |

**首选 `git quiltimport`**——这是 git 自带命令（`git-quiltimport`），正是为这个场景存在的：

```bash
git -C src quiltimport --dry-run \
  --patches "$PWD/patches" --series "$PWD/patches/series"
git -C src quiltimport \
  --patches "$PWD/patches" --series "$PWD/patches/series"
```

它保留补丁边界、顺序与描述；`--dry-run` 会走一遍 series 并在无法提交时警告（目前只在缺作者信息时）。

**如果你坚持手写循环，必须 fail-loud**：

```bash
set -euo pipefail
while IFS= read -r p; do
  case "$p" in ''|'#'*) continue ;; esac
  git -C src apply --check --whitespace=error "$PWD/patches/$p"
  git -C src am --3way --empty=drop --keep-cr "$PWD/patches/$p"
done < "$PWD/patches/series"
```

**`--3way` 与浅克隆 / 部分克隆不兼容**——这条必须记住：

> `git apply -3` / `git am -3` 需要**本地存在补丁所记录的 blob**。在 `--depth 1 --filter=blob:none` 的仓里，它给出的就是
> `error: repository lacks the necessary blob to perform 3-way merge.`
> 所以：**要么 `--3way` 配完整 clone，要么 blobless clone 配纯 `git apply`（不带 -3）**。两者不能混。

另外两条：
- `--whitespace` 在 `git apply` 里默认是 **`warn`**——有空白警告**仍然会应用**。想要「有空白问题就停」必须显式写 `--whitespace=error`。
- `git am --reject` 与三方合并**互斥**，别同时给。

## 第五步：上锁，并且知道这把锁的极限

**依赖前提**：仓库至少要有一个 commit，ruleset 才有意义。

### 用 ruleset（当前推荐机制）

GitHub 2026-08-11 的 changelog 已上线 Settings → Branches 的「Convert to ruleset」，并写明 "As we continue investing in rulesets as the foundation for repository governance on GitHub"。旧的分支保护 API 仍可用、未标废弃，但 ruleset 是官方在投的方向。

```bash
cat > /tmp/protect-main.json <<'JSON'
{
  "name": "protect-main",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "bypass_actors": [],
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "required_linear_history" },
    { "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": true,
        "require_last_push_approval": true,
        "required_review_thread_resolution": true
      } }
  ]
}
JSON

gh api -X POST repos/<owner>/<repo>/rulesets --input /tmp/protect-main.json
gh api repos/<owner>/<repo>/rules/branches/main      # 查生效的规则
gh ruleset check main --repo <owner>/<repo>          # gh 自带的规则评估器（只读）
```

逐条解释：

- `deletion` = 禁删分支；`non_fast_forward` = 禁 force push；`required_linear_history` = 禁 merge commit。
- `required_approving_review_count: 0` **仍然要求走 PR**，只是不要求谁来批准。桌面 + 手机两个写入者的场景正合适：两边都必须开 PR，谁都不能直接推 `main`。
- **`require_last_push_approval: true` 是这里最要紧的一条**：没有它，同一个身份可以自己开 PR、自己批准、自己合。加上它，最后一次 push 之后必须由别人批准。
- `bypass_actors: []` 必须显式写空数组。返回值里出现 `"bypass_actors":[]` 与 `"current_user_can_bypass":"never"` 才说明连 owner 的 git push 也被拦。
- `~DEFAULT_BRANCH` 比写死 `refs/heads/main` 更稳（默认分支改名后不用改规则）。注意 `*` 不跨 `/`。

**`gh ruleset` 只能读**（`check` / `list` / `view`），创建与修改必须走 `gh api`。

### 这把锁的极限（必须知道）

ruleset **拦得住 git push，拦不住 API**。实测量过：同一个 admin token 直接

```bash
gh api -X DELETE repos/<owner>/<repo>/rulesets/<id>
```

**成功**，锁当场消失。而 `gh auth status` 的经典 `repo` scope 对自己所有仓库都是 **admin**（`gh api repos/<owner>/<repo> --jq .permissions` 会显示 `"admin":true`）。创建 / 更新 ruleset 需要的是 **Administration: write**——手里有这个权限的人，就能把规则删掉或改成 `enforcement: "disabled"`。

> 结论：**锁的强度 = token 的权限，不是 ruleset 本身。**

把锁变成真的，要同时做到：

| 做法 | 为什么 |
| --- | --- |
| 规则放在**组织**层（`POST /orgs/<org>/rulesets`，需 org 的 Administration write） | 只给单仓权限的 token 管不到组织级规则；组织规则覆盖在仓库规则之上，取最严 |
| 手机端身份换成 **fine-grained PAT**：`Contents: RW` + `Pull requests: RW` + `Actions: RW`，**只在必须改 workflow 文件时才加 `Workflows: RW`** | **绝不给 `Administration`**，也不要给「编辑仓库规则」的自定义角色 |
| 更好的选择：**GitHub App installation / machine user** | installation token 不会自带 Administration；Actions 里的 `GITHUB_TOKEN` 默认也没有 |
| **绝不**把 agent 的 deploy key 或 App 加进 bypass 列表 | `bypass_actors` 接受 `DeployKey`、`Integration` 等 actor 类型 |
| 需要自动合并时，在 workflow 里用显式最小 `permissions:` 做 | 好过把一把宽 PAT 交给手机 |

**三个容易搞错的小点**：

- `workflow_dispatch` 需要 **`Actions: write`**；但**推 `.github/workflows/` 下的文件是另一项授权**——fine-grained 下 `Contents: write` **不够**，还要 `Workflows: write`（经典 PAT 则是 `workflow` scope）。
- 如果退回用旧的分支保护 API：`allow_force_pushes` 与 `allow_deletions` 默认就是 false（不必特意设），但 **`enforce_admins` 默认 false 意味着管理员被豁免**——必须显式设 `true`。
- 公开仓库上 ruleset 免费；私有仓库需要 Pro / Team / Enterprise Cloud。每个仓库最多 75 条 ruleset。

## 第六步：仓库里永远不该有的东西

| 不该有 | 为什么 |
| --- | --- |
| 上游内核源码树 | 仓变大到手机 clone 不动；也正是「不要 fork」的理由 |
| `out/`、`*.img`、`*.ko` | 二进制产物走 Release，不进历史 |
| AVB 签名私钥（`*.pem` / `*.pk8`） | 泄露即等于设备签名密钥泄露 |
| 厂商私有 blob | 不可再分发 |
| 设备标识（序列号、IMEI、账号、个人路径） | 一旦进了 git 历史，删不干净 |
| 预编译工具链 | GB 级；CI 里按 `build.config.constants` 现取 |

`.gitignore` 必须显式包含 `out/`、`*.img`、`*.ko`、`*.pem`、`*.pk8`。

## Common Mistakes

| 做法 | 后果 |
| --- | --- |
| 把内核工程塞进 skills 仓 | 要么整仓改 GPL-2.0，要么做没人维护的按目录许可；更糟的是手机 agent 能改自己的护栏 |
| 看仓库首页的 license 徽章就决定搬哪些补丁 | KernelSU 只有 `kernel/` 是 GPL-2.0-only，其余是 GPL-3.0-or-later；照搬会把 GPLv3 混进 GPL-2.0-only 源码 |
| fork `kernel_common` | GB 级、手机 clone 不动、永久带上 fork 关系 |
| `--filter=blob:none` 之后检出工作区 | 逐 blob 懒加载，慢且会报 `unable to read sha1 file` |
| 在 blobless / shallow 仓上用 `--3way` | `error: repository lacks the necessary blob to perform 3-way merge.` |
| 靠 `git clone --revision` 做 pin | 需要 git ≥ 2.49；Ubuntu 24.04 是 2.43，手机上多半没有 |
| 建仓前不查仓名 | token 无 `delete_repo`，建错删不掉 |
| 用 admin token，却指望 ruleset 兜底 | 同一个 token 能 `DELETE` 掉 ruleset |
| 只给 `Contents: write`，却要让 agent 推 workflow 文件 | 推 `.github/workflows/` 需要额外的 `Workflows: write` |
| 开了 ruleset 但没开 `require_last_push_approval` | 同一身份能自己开 PR、自己批准、自己合 |
| 只 pin 分支名不 pin SHA | 上游一动，构建不可复现，失败无法复现 |
| Release 里不带 `versions.lock` | GPL 对应源码指认缺失 |
| 用代号当仓名 | 代号本身还没在实机上确认过，等于把不确定写进 URL |

## 先确认再动手（不可逆动作清单）

以下动作一旦执行就有外部副作用，必须**先拿到用户的明确确认**：

1. `gh repo create` ——建错了删不掉。
2. 改仓库可见性 ——public 转 private 会让已有 clone 与镜像失效。
3. 推送第一个 commit ——之后 `LICENSE` 和 `versions.lock` 的内容都进了历史。

可以在本地无限重来的是：写文件、`git init`、`git commit`。所以顺序永远是**先在本地做完，最后一次性 `gh repo create --source=. --push`**。

## Real-World Impact

RED 基线（一个没有这个 skill 的 agent，被要求「建内核工程仓」）表现**相当好**：它选对了 GPL-2.0、patch stack、pin SHA、排除清单，甚至想到了 PRoot 的 ext4 与 `/sdcard` 的 exec 位差异。所以这个 skill 的价值集中在它真正说错、以及它**不知道自己不知道**的地方：

1. 它推荐 `--filter=blob:none --no-checkout` + `git checkout <sha>`，并断言「普通 `--depth 1` 检不出任意 SHA」。**后半句被实测推翻**：`git fetch --depth 1 origin <sha>` 对 tip、非 tip、跨分支 SHA 全部成功。前半句在 73k 文件的工作区检出上是性能陷阱，而且在 blobless 仓上再叠 `--3way` 会直接报 `repository lacks the necessary blob`。
2. 它在 ruleset 里**主动放弃**了 required PR，理由是「会锁住单人开发」——而这个仓库恰恰有**两个写入者**（桌面 + 手机），护栏要防的就是第二个。
3. 它（和基线一样）把「内核补丁都是 GPL-2.0」当成前提。实际上 KernelSU 只有 `kernel/` 是 GPL-2.0-only，`susfs4ksu` 的 LICENSE 是 GPLv3 全文，而 GPL-3.0 **不在** kernel.org 的 GPL-2.0 兼容集里。这一条不做，仓库的许可证从第一天起就是错的。

一个忠实的基线结论：**当基线已经做对了大部分事，skill 就应该只写它做错的部分，而不是把它的正确做法抄一遍充数。**
