# Batch dumping fighter data

`MMDK_BatchDump.lua` loads each requested fighter as P2 in Training Mode and exports fighter-specific and shared JSON data. The ID list comes from `MMDK/tables.lua`; the current default is `1-22,25-34` (32 entries).

These are game resource IDs, not consecutive character-selection positions. IDs 23 and 24 are not assigned in this roster: Sagat is 25, M Bison 26, Terry 27, Mai 28, Elena 29, C Viper 30, Alex 31, Ingrid 32, Yasmine 33 and Arjun 34. Numbering M Bison as 23 caused the game to request an invalid fighter/resource and the batch to stop after Akuma.

## Install and run

1. Install MMDK and a compatible REFramework build for SF6.
2. Deploy the patched `MMDK.lua`, `MMDK_BatchDump.lua`, `MMDK/tables.lua` and `MMDK/functions.lua` together. The core permits empty VFX arrays; the serializer checks getter return types before using managed-object operations. Updating only the batch file does not fix an incorrect ID map or the shared serializer.
3. Enter Training Mode and close the game's training menu. Open **REFramework → Script Generated UI → MMDK Batch Dump**.
4. Leave the default ID list for all known fighters, or enter a subset such as `1,2` or `1-22,25-33`.
5. Press **Start new batch**. Version `2026-10-14.2` switches P2 automatically, verifies the requested fighter's live ID and fresh data, requires common-action collection, and exports them. Use **Reset scripts** after deploying changes.

Fighter output is written to `reframework/data/MMDK/PlayerData/<fighter>/`. Existing files are replaced. Each export writes HIT_DT, triggers, atemi, tgroups, rects, commands, charge, char_info, assist_combo and moves_dict. MMDK also writes Names while building its move dictionary. Common actions are included in fighter dictionaries where no character override exists.

The batch enables **Collect common moves** and intentionally leaves it enabled afterward. The MMDK default is also enabled. A previously built dictionary without shared actions is rebuilt before export. An existing saved setting can still affect normal startup; the batch explicitly enables it when started.

Shared files are exported once per new batch to the same `MMDK/PlayerData/` root:

- `common_moves.json`: all common FAB actions, collected independently of character overrides.
- `common_names.json`: zero-padded action ID to common action name.
- `common_rects.json` and `common_atemi.json`: shared collision and Atemi resources.
- `common_act_id.json`: the game's `nBattle.ACT_ID` enum.
- `common_manifest.json`: source, style/action counts and shared filenames.

The complete common dictionary is collected directly from `gBattle.Resource.Data[6].FAB`. The old `common_move_dict` cache omits IDs overridden by the current fighter and therefore is not used as the standalone export source. Common merges create fresh per-fighter Lua objects with enum-derived names; reusing another fighter's cached objects previously caused Names/moves_dict disagreements. Character-specific animation/projectile metadata is not read when collecting shared actions. This manifest identifies the common resource source; it does not claim a verified game-version match or complete replay state.

The batch disables moveset scripts for the selected fighters and All Characters, restoring their prior enabled settings on completion, Stop or error. Disable other mods that change fighter data before starting. If the current session already has modified fighter resources, restart SF6 before creating reference dumps.

**Stop** cancels pending exports. A fighter load already requested from SF6 may finish. **Resume** retries the current failed/stopped fighter without repeating completed entries. Do not open the game training menu or change characters during an active batch. The UI reports the phase, loading reason and switch request; failures are also recorded in `re2_framework_log.txt`.

## Character loading

The script runs switching on `UpdateBehavior`, retrieves the `app.training.tf_SelectMenu` controller from `TrainingManager._tfFuncs[1]`, and invokes `FuncList.ChangeFighter` for zero-based player index 1 (P2). This method updates the selection and marks the controller's character-change flags. `tf_SelectMenu.Apply()` then lets the game reload the battle resources. Only the selection controller is applied: applying every training controller during a character change can access incompatible unique-gauge arrays belonging to the outgoing fighter. P2 controls are preserved; costume/color use defaults. P1 selection is not edited.

Versions .9–.11 changed descriptors or saved selection fields without correctly requesting a resource reload. A saved target ID therefore could differ from the live fighter. Version .13 uses the game's character-change method and has no menu-close hooks.

After switching, the script checks both the live `gBattle` P2 ID and fresh MMDK data. It requires all export resources and a non-empty move dictionary, then waits 20 update frames for stability. If necessary, it requests a direct MMDK rebuild after 120 updates with the correct live ID. It waits 120 updates between fighters and stops after 3600 updates of unsuccessful loading rather than exporting stale fighter data.

Each fighter must be accessible in the installed game. Add a fighter's verified ID and name to MMDK/tables.lua before including it in a batch. Some DLC fighters may need access to their content.

## Verification

From the MMDK directory, run `luajit tools/test_batch_dump.lua`, `luajit tools/test_common_dump.lua`, `luajit tools/test_common_merge.lua` and `luajit tools/test_json_conversion.lua`. Cases cover delayed native loading, existing dictionaries missing common actions, unchanged live fighter timeout, missing reload flags, Stop, fighter/shared-file write failures and settings restoration. The common exporter tests index zero, all styles and character overrides; merge regression checks fresh objects, canonical names and name collisions. The serializer regression ensures numbers, zero and false cannot be passed to `add_ref`. Live SF6 remains necessary to verify native resources.

Current fixes, live results and deployment hashes are recorded in `BATCH_DUMP_VALIDATION_20261014.md` and `tools/validation-20261014/`. The earlier .13 run remains documented in `BATCH_DUMP_VALIDATION.md`. Native loading was tested on the connected Windows installation with REFramework `v1.5.9.1+507-d1461375`.

A completed run can be checked with `python tools/verify_batch_dump.py --root <MMDK/PlayerData> --tables <autorun/MMDK/tables.lua> --since <YYYY-MM-DDTHH:MM:SS> --require-common --report <report.json>`. Add `--ids 26` to verify only M Bison, or another requested subset. The checker requires fresh valid files, detects identical fighter dictionaries, checks Names/move agreement, checks predominant motion-resource IDs against the roster, verifies the six shared files and records SHA-256 values. Null charge/Atemi resources are reported separately rather than treated as automatic export failure. This is structural/resource-identity verification, not exhaustive validation of every parameter's meaning.
