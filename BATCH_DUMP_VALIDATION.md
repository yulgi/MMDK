# 自动切换与批量导出验收记录

最终版本 `2026-10-12.13` 已在远程 Windows 的 SF6 训练场完成一次无人干预的完整运行：31 个角色全部自动切换并导出。REFramework 界面显示 `Finished 31 characters.`，游戏保持响应。

- 开始：2026-10-12 23:56:36.138（北京时间）
- 完成：2026-10-13 00:02:19.534
- 用时：5 分 43 秒
- 队列：`1-22,25-33`，Ryu → Luke → … → Yasmine
- 日志：31 条完成导出记录，0 条本轮批处理失败记录。
- REFramework：`v1.5.9.1+507-d1461375`

## 问题与修复

旧脚本只修改选角描述或保存字段，并等待菜单关闭，没有正确触发角色资源重载。新版在 `UpdateBehavior` 调用训练场选角控制器的 `FuncList.ChangeFighter(1, ...)`，再调用 `tf_SelectMenu.Apply()`，等待 P2 实际角色 ID 与重新构建的 MMDK 数据一致后导出。

仅应用选角控制器。调试中发现全局 `TrainingManager.Apply` 会在 Zangief → JP 时访问旧角色的特殊量表数组并崩溃。最终版本已避开该调用。

最后一个角色 Yasmine 的特效列表包含空数组，原 MMDK 在遍历时收到 nil。`MMDK.lua` 的两处特效数组转换现允许返回空表，完整运行已覆盖这一修复。

## 文件校验

`tools/verify_batch_dump.py` 在 Windows 上检查了本轮输出，退出码为 0：

```json
{"ok": true, "fighter_count": 31, "file_count": 341, "errors": []}
```

每个角色的 11 个文件均存在，更新时间不早于本轮开始，内容均为可解析 JSON。HIT_DT、triggers、rects、moves_dict 与 Names 字典均非空；各角色招式字典的文件摘要互不重复。总大小 908,473,735 字节。完整文件时间、大小和招式数量见 [BatchDumpValidation.json](BatchDumpValidation.json)。

Windows 输出目录：

```text
C:\Program Files (x86)\Steam\steamapps\common\Street Fighter 6\reframework\data\MMDK\PlayerData\<character>\
```

Windows 校验报告：`reframework/data/MMDK/BatchDumpValidation.json`。校验确认文件完整性、格式和不同角色数据的差异，未逐项核对每个游戏数据字段的语义。MMDK 原有数据查询仍可能记录被处理的原生异常；本记录不声明整个 REFramework 日志完全没有异常。

## 部署一致性

以下两个文件已同步到 Windows 的 `reframework/autorun/`。按 UTF-8 文本统一换行后的 SHA-256，本地和远程完全一致：

| 文件 | SHA-256 |
| --- | --- |
| MMDK_BatchDump.lua | `5a9b8e298d1b424ff6df7e4bf23ed4342eb425519f1b5b99888521425309c35f` |
| MMDK.lua | `5b566ca7382461a5c450b2a3ec90f9923ba2e8aa7015a385c01a9ab10ac82f86` |

临时 BatchDebug 与 BatchFlowProbe 脚本已改为 `.lua.disabled`，并在最终运行前重新加载脚本，使诊断回调不再运行。原文件备份保留在远程目录。

本地 Lua 语法检查和 5 个状态机测试均通过，覆盖正常顺序导出、不发生切换、缺失重载标记、中途停止、写文件失败及配置恢复。
