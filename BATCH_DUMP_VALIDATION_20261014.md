# 2026-10-14 M Bison 与公共动作导出修复

修复后的批处理版本：`2026-10-14.2`。修改已部署到当前 Windows 的 SF6 REFramework，并通过训练场实测。部署 SHA-256 索引保存在 `tools/validation-20261014/deployment/deployment.json`；同目录的原安装脚本备份 `.original` 仅本机保留，不提交到仓库。

## 原因与修改

1. 角色 ID 表被改成连续的选角顺序。日志显示 Akuma 导出后请求 `target=23`，并把它称作 M Bison；23 实际不是本安装的 M Bison 资源 ID。已修正为非连续的 `1-22,25-34`：M Bison=26、Terry=27、Elena=29、Arjun=34。该映射与现有录制、历史验收和 `esfXXX` 动画资源一致。
2. MMDK 默认启用公共动作；批处理开始时也明确启用，并检查当前角色字典是否已收集公共动作。旧字典缺公共动作时先重建。
3. 新增 `PlayerData.dump_common_json()`，直接读取公共 FAB 的全部 style/action，独立于角色覆盖，导出完整公共动作、名称、rects、Atemi、ACT_ID 与 manifest。统一输出到 `reframework/data/MMDK/PlayerData/common_*.json`。
4. 完整批次初次验证在 Luke 暴露 `functions.lua:517 attempt to index a number value (local 'mdata')`。`sdk.is_managed_object()` 也接受数字地址，旧代码把数字 getter 结果误当托管对象并调用 `add_ref()`。现增加 userdata 类型及 add_ref 可用性检查，数字、0、false 保持原始类型。
5. 校验器增加 `--ids`、`--require-common`、Names/动作一致性、主动画资源 ID 检查、公共文件检查和逐文件 SHA-256。合法 null 资源单列报告。
6. 文件验收发现启用公共动作后，原公共缓存复用前一个角色的 move 对象：By_Name 键来自公共枚举，move.name 却可能来自前一个角色动画，造成名称不一致。现为每个角色重新建立公共 move 对象，使用公共枚举名称，处理名称冲突，保留同 ID 角色动作的优先级；公共动作不读取当前角色的动画/投射物元数据。

部署文件：`MMDK.lua`、`MMDK_BatchDump.lua`、`MMDK/tables.lua`、`MMDK/functions.lua`。这四个文件需一起更新，再执行 REFramework 的 **Reset scripts**。

## 已完成的针对性实测

在 SF6 训练场使用 ID `26` 自动将 P2 切换为 M Bison，并完成10项显式 dump及 Names 生成。游戏画面显示维加；日志于北京时间 10:31:09 记录 `Exported M Bison (1/1)`、`Finished 1 characters.`。全部11个角色文件和6个公共文件通过校验，报告为 `tools/validation-20261014/M_Bison.json`。

公共资源实测：369个公共动作、369个名字、623个 ACT_ID 枚举项、14组 rects、5个 Atemi 条目。此前录制中未匹配的 ID（包括145、230–239、244–245、251–253、274、280、282、330、331、336）均可在公共名字表中找到。

## 本地验证

使用临时目录中的 Python Lupa/LuaJIT 2.1 执行，四个部署文件均通过 LuaJIT 语法检查。

- `test_batch_dump.lua`：7个场景，覆盖延迟加载、缺公共动作的已有字典、切换失败超时、缺 reload 标记、Stop、角色写失败、公共文件写失败；检查设置恢复及公共包只写一次。
- `test_common_dump.lua`：检查零索引动作、全部 style、角色覆盖不会移除独立公共动作、六文件输出、空资源失败；检查非连续角色 ID。
- `test_common_merge.lua`：检查两个角色得到独立公共 move 对象、缓存不被复用/修改、By_Name 与 move.name 一致、名称碰撞处理和同 ID 角色覆盖。
- `test_json_conversion.lua`：重现 SDK 将数字视为地址的风险，验证数字/0/false 不被当作 add_ref 对象。
- 校验器夹具：合法角色/公共数据通过；主动画资源 ID 不符和空公共 manifest 均拒绝；合法 null charge 单列报告。

运行修复后的完整批次时，仍可见 MMDK 原有反射查询的原生 `HIT_DT_TBL.get_Item` / `BCM.COMMAND.GetCommandTimer` 越界日志。它们与批处理停止错误分开记录；本验收不声明整个 REFramework 日志零异常，也不证明所有反射字段均完整或每项参数语义已验证。

## 最终完整批次验收

版本 `2026-10-14.2` 在训练场完整执行 `1-22,25-34`，Ryu → Luke → … → M Bison → … → Arjun。

- 开始：2026-10-14 10:49:55.367（北京时间）
- 完成：2026-10-14 10:55:57.102
- 用时：6分1.735秒
- UI：`Finished 32 characters.`，`Phase: done`，ScriptRunner 显示 `No Script Errors... yet!`
- 本轮日志：32条 `Exported`；没有批处理 `Export failed / Cannot load / Timed out / Cannot collect`。原生反射查询日志的限制仍如上文所述。
- 校验退出码0：32个角色 × 11文件 = 352个角色文件，加6个公共文件，共358个。本轮文件全部新鲜、JSON可解析；Names/动作名称、主动画资源ID、公共名字/动作和公共数量检查均通过；各角色字典hash不同。
- 全部四个部署脚本与仓库源码逐字节一致；修改前版本均已备份。

机器报告：`tools/validation-20261014/full_batch.json`（`ok=true, errors=[]`）；部署/备份索引：`tools/validation-20261014/deployment/deployment.json`。本轮批处理日志 `tools/validation-20261014/full_batch.log`、中间诊断及失败批次记录仅本机保留，不提交。

角色的新完整输出保留在游戏的 `reframework/data/MMDK/PlayerData/<character>/`。六个公共文件已从本轮输出同步到主仓库的 `data/MMDK/PlayerData/`，并逐字节核对一致；主仓库原有的角色文件保留为此前 dump 的快照，没有全部替换成新一轮数据。

公共库包含369个动作/名字、623个 ACT_ID 枚举项、14组 rects 和5个 Atemi 条目。后续分析应先匹配角色/style动作，再查公共库，保留来源与版本未验证标记；旧录制中坏掉的动作帧和缺失输入不会因补静态公共数据自动恢复。

复用最终验收命令（在主仓库根目录）：

```powershell
python MMDK\tools\verify_batch_dump.py --root "C:\Program Files (x86)\Steam\steamapps\common\Street Fighter 6\reframework\data\MMDK\PlayerData" --tables MMDK\MMDK\reframework\autorun\MMDK\tables.lua --since 2026-10-14T10:49:54 --require-common --report MMDK\tools\validation-20261014\full_batch.json
```
