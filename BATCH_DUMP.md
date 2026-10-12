# Batch dumping fighter data

`MMDK_BatchDump.lua` loads each requested fighter as P2 in Training Mode and exports the fighter-specific JSON files provided by MMDK. The ID list comes from `MMDK/tables.lua`; the current default is `1-22,25-33` (31 entries).

## Install and run

1. Install MMDK and a compatible REFramework build for SF6.
2. Copy the patched `MMDK.lua` and `MMDK_BatchDump.lua` into `reframework/autorun/`. The core patch allows empty VFX arrays, which are present in Yasmine's resources.
3. Enter Training Mode and close the game's training menu. Open **REFramework → Script Generated UI → MMDK Batch Dump**.
4. Leave the default ID list for all known fighters, or enter a subset such as `1,2` or `1-22,25-33`.
5. Press **Start new batch**. Version `2026-10-12.13` switches P2 automatically, verifies that the requested fighter's resources and MMDK data are loaded, and then exports them.

Output is written to `reframework/data/MMDK/PlayerData/<fighter>/`. Existing files are replaced. Each export writes HIT_DT, triggers, Atemi, tgroups, rects, commands, charge, char_info, assist_combo and moves_dict. MMDK also writes the fighter's Names file while building its move dictionary. Shared common_moves, common_atemi and common_rects are outside this batch.

The batch disables moveset scripts for the selected fighters and All Characters, restoring their prior enabled settings on completion, Stop or error. Disable other mods that change fighter data before starting. If the current session already has modified fighter resources, restart SF6 before creating reference dumps.

**Stop** cancels pending exports. A fighter load already requested from SF6 may finish. **Resume** retries the current failed/stopped fighter without repeating completed entries. Do not open the game training menu or change characters during an active batch. The UI reports the phase, loading reason and switch request; failures are also recorded in `re2_framework_log.txt`.

## Character loading

The script runs switching on `UpdateBehavior`, retrieves the `app.training.tf_SelectMenu` controller from `TrainingManager._tfFuncs[1]`, and invokes `FuncList.ChangeFighter` for zero-based player index 1 (P2). This method updates the selection and marks the controller's character-change flags. `tf_SelectMenu.Apply()` then lets the game reload the battle resources. Only the selection controller is applied: applying every training controller during a character change can access incompatible unique-gauge arrays belonging to the outgoing fighter. P2 controls are preserved; costume/color use defaults. P1 selection is not edited.

Versions .9–.11 changed descriptors or saved selection fields without correctly requesting a resource reload. A saved target ID therefore could differ from the live fighter. Version .13 uses the game's character-change method and has no menu-close hooks.

After switching, the script checks both the live `gBattle` P2 ID and fresh MMDK data. It requires all export resources and a non-empty move dictionary, then waits 20 update frames for stability. If necessary, it requests a direct MMDK rebuild after 120 updates with the correct live ID. It waits 120 updates between fighters and stops after 3600 updates of unsuccessful loading rather than exporting stale fighter data.

Each fighter must be accessible in the installed game. Add a fighter's verified ID and name to MMDK/tables.lua before including it in a batch. Some DLC fighters may need access to their content.

## Verification

From the MMDK directory, run `luajit tools/test_batch_dump.lua`. Simulated cases cover sequential exports after delayed loading, unchanged live fighter timeout, a missing reload request, Stop while loading, failed JSON writes and settings restoration. These test the Lua state machine; live SF6 is required to verify native loading.

Live results and the deployed script hashes are recorded in `BATCH_DUMP_VALIDATION.md`. Native loading was tested on the connected Windows installation with REFramework `v1.5.9.1+507-d1461375`.

A completed run can be checked with `python tools/verify_batch_dump.py --root <MMDK/PlayerData> --tables <autorun/MMDK/tables.lua> --since <YYYY-MM-DDTHH:MM:SS> --report <report.json>`. The checker requires all 11 files per fighter to be fresh and valid JSON, validates the main dictionaries, and detects identical move dictionaries across fighters.
