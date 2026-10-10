# 补丁来源头：四套体系、字段清单与推荐组合

本文件是 skill `kernel-project-repo-bootstrap` 第四步的细节参考。正文只留骨架，逐字查表看这里。

## 1. 没有标准

**不存在 `patches.json` 这类标准。** 上游补丁的来源标注没有 RFC，实际在用的是下面四套公认做法，**可以叠加**。

## 2. DEP-3（Debian 提案）

- 状态 **ACCEPTED**，与 `git format-patch` 兼容。
- 字段清单：`Description` / `Subject` / `Origin` / `Bug` / `Forwarded` / `Author` / `Reviewed-by` / `Last-Update` / `Applied-Upstream`。
- **必填**：`Description`（或 `Subject`）与 `Origin`。
- `Origin` 写法示例：`Origin: backport, https://github.com/<owner>/<repo>/commit/<sha>`。
- 解析规则：读到**第一个空行或 `---` 为止**——之后是补丁正文，不是头部。

## 3. Yocto / OE 的 `Upstream-Status:`

合法值只有这六个，写别的值解析器不认：

```
Pending | Submitted | Accepted | Backport | Denied | Inactive-Upstream
```

## 4. AOSP kernel/common

- 所有补丁**必须带 `Change-Id:`**。
- author 与 submitter **都要** `Signed-off-by:`（双 sign-off）。
- subject 前缀：`ANDROID:` / `FROMGIT:` / `FROMLIST:` / `BACKPORT:`。

## 5. quilt `series`

一行一个补丁文件名，**顺序即契约**。它自己不带来源头，来源标注在补丁文件里。

## 6. 推荐组合：每个补丁都带这四行

```
Origin: backport, https://github.com/<owner>/<repo>/commit/<sha>
Upstream-Status: Backport
Signed-off-by: <原作者>
Change-Id: <原 Change-Id>
```

四套一起用不冲突：`Origin` 来自 DEP-3，`Upstream-Status` 来自 Yocto，后两行来自 AOSP 的惯例；`series` 负责顺序。

## 7. CI 断言（把它写进 workflow / 本地脚本）

- `series` 里每个文件都存在，且能干净应用。
- 每个补丁都有 `Origin` 与 `Upstream-Status`。
- `Origin` 里的 SHA 真是上游的：`git merge-base --is-ancestor <sha> HEAD`。
- 每个补丁的许可证属于内核的兼容集（见正文第三步的 GPL-3.0 地雷）。

可以另生成 `provenance.json` 当**审计产物**（便于 CI 汇总），但**不要让 JSON 成为唯一真相来源**——补丁文件本身才是。

## 8. `Signed-off-by` 的法律含义

`Signed-off-by` 是 **DCO 认证，不是再分发许可证**。AOSP Common Kernel 要求所有补丁带 `Change-Id:`，且 author 与 submitter 都要 `Signed-off-by:`。

收别人的补丁进你的 stack 时：

- **原样保留原作者的全部 `Signed-off-by` 与 `Change-Id`**；
- 自己经手再加一条 `Signed-off-by`。

改掉原来的 sign-off 等于伪造认证——那是「我证明这段代码有权被提交」的声明，不是可替换的署名。

## 9. mailbox 补丁与 SPDX 的冲突

**mailbox 格式（`git format-patch` 产物）放不下干净的 SPDX 注释行**——文件开头是 `From <sha>` / `Subject:` 那套邮件头，塞一个 `# SPDX-License-Identifier:` 进去不是合法注释位置。

所以 mailbox 补丁的许可证靠两样东西共同承载：**文件内的来源头**（本文件第 6 节那四行）+ **仓库根 `LICENSE`**。这也是为什么第四步的推荐组合必须逐补丁写全，而不是靠仓库层面的声明兜底。
