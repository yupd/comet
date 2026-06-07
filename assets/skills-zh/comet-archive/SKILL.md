---
name: comet-archive
description: "Comet 阶段 5：归档。用 /comet-archive 调用。同步 delta spec 到主 spec，归档 change。"
---

# Comet 阶段 5：归档（Archive）

## 前置条件

- 验证已通过（阶段 4 完成）
- 分支已处理
- `openspec/changes/<name>/.comet.yaml` 中 `verify_result: pass`

## 步骤

### 0. 入口状态验证（Entry Check）

执行入口验证：

```bash
COMET_ENV="${COMET_ENV:-$(find . "$HOME"/.*/skills "$HOME/.config" "$HOME/.gemini" -path '*/comet/scripts/comet-env.sh' -type f -print -quit 2>/dev/null)}"
if [ -z "$COMET_ENV" ]; then
  echo "ERROR: comet-env.sh not found. Ensure the comet skill is installed." >&2
  exit 1
fi
. "$COMET_ENV"
"$COMET_BASH" "$COMET_STATE" check <change-name> archive
```

验证通过后继续 Step 1。验证失败时脚本会输出具体失败原因。

### 1. 执行归档

运行归档脚本，自动完成以下全部步骤：

```bash
COMET_ENV="${COMET_ENV:-$(find . "$HOME"/.*/skills "$HOME/.config" "$HOME/.gemini" -path '*/comet/scripts/comet-env.sh' -type f -print -quit 2>/dev/null)}"
if [ -z "$COMET_ENV" ]; then
  echo "ERROR: comet-env.sh not found. Ensure the comet skill is installed." >&2
  exit 1
fi
. "$COMET_ENV"
"$COMET_BASH" "$COMET_ARCHIVE" "<change-name>"
```

脚本自动执行：
1. 入口状态验证（phase=archive, verify_result=pass, archived=false）
2. Delta spec 语义合并到主 spec（按 ADDED/MODIFIED/REMOVED/RENAMED 语义）
3. Post-merge 全局守卫：扫描所有主 spec 是否存在 delta-only section 标题
4. Design doc 前置元数据标注（archived-with, status）
5. Plan 前置元数据标注（archived-with）
6. 移动 change 到归档目录
7. 通过 `comet-state transition <archive-name> archived` 更新 `archived: true`

如脚本返回非零退出码，报告错误并停止。
如脚本返回零退出码，归档完成。
脚本摘要中的 `X/Y steps succeeded` 以真实执行步骤计数，不会因 delta spec 合并或文档标注重复累计。

Delta spec 合并为**智能合并（intelligent merge）而非文件复制**：
- 新增 capability：从 delta spec 创建主 spec，自动移除 `REMOVED` / `RENAMED` section，将 `ADDED` / `MODIFIED` 头转换为标准 `## Requirements`
- 已有 capability：解析 delta spec 的四个语义 section，分别执行追加（ADDED）、替换（MODIFIED）、移除（REMOVED）、重命名（RENAMED），保留主 spec 中未被 delta 提及的所有内容

当待合并的 delta spec 与已有主 spec 不一致时，脚本会在合并前打印 unified diff 预览，帮助确认归档合并内容。

如需预览而不实际执行，使用 `--dry-run` 参数。

### 2. 生命周期闭环

Spec 生命周期在此完成：
```
brainstorming → delta spec → 实施 → 验证 → 主 spec 语义合并 → design doc 标注 → 归档
```

## 上下文压缩恢复

归档阶段可能触发上下文压缩。恢复时先运行：

```bash
"$COMET_BASH" "$COMET_STATE" check <change-name> archive --recover
```

脚本输出结构化恢复上下文（phase、verify_result、archived 状态、恢复动作），根据输出的 Recovery action 决定下一步。

若归档尚未执行（archived 不是 true），继续执行 Step 1 归档脚本；若归档已完成（archived: true），直接确认退出条件并结束。

## 退出条件

- 归档脚本执行成功（退出码 0）
- 归档目录 `openspec/changes/archive/YYYY-MM-DD-<change-name>/` 存在
- 归档后的 `.comet.yaml` 中 `archived: true`

归档脚本会把 `openspec/changes/<change-name>/` 移动到 `openspec/changes/archive/YYYY-MM-DD-<change-name>/`。归档成功后通过以下命令验证完整性：

```bash
test -d "openspec/changes/archive/YYYY-MM-DD-<change-name>"
"$COMET_BASH" "$COMET_STATE" get YYYY-MM-DD-<change-name> archived
```

归档成功后**不要再对原 change 名运行** `"$COMET_BASH" "$COMET_GUARD" <change-name> archive`，因为原活跃目录已经不存在。归档完整性以脚本退出码和归档目录状态为准。

## 完成

Comet 流程全部完成。如需开始新工作，调用 `/comet` 或 `/comet-open`。
