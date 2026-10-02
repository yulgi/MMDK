# Batch dumping fighter data

`MMDK_BatchDump.lua` exports the current game's fighter data for multiple characters in one run. It uses Training Mode to load each requested fighter as P2, waits for MMDK to rebuild `player_data[2]`, and then writes the **fighter-specific** JSON files available through MMDK's `Dump All` controls. Shared `common_moves.json`, `common_atemi.json`, and `common_rects.json` are not part of this batch. MMDK also writes each fighter's `Names.json` when it builds the moves dictionary.

The default selection contains the fighters released through Yasmine (October 2026): IDs `1-22,25-33`. IDs 23 and 24 are intentionally absent. The ID list in `MMDK/tables.lua` is based on game fighter IDs; a character announcement alone is not enough to add a future fighter to the export queue.

## Install and run

1. Install MMDK and a compatible REFramework build for SF6.
2. Copy `MMDK_BatchDump.lua` beside `MMDK.lua` in the game's `reframework/autorun/` folder.
3. Start SF6, enter Training Mode, and open REFramework's **Script Generated UI → MMDK Batch Dump**.
4. Leave the default ID list to export every fighter known to `MMDK/tables.lua`, or enter a subset such as `1,10,33` or `1-22,25-33`.
5. Press **Start new batch**. Wait until the status says **Finished**. The script changes P2 automatically. It does not require you to open the character-select screen for each fighter.

The output is written under `reframework/data/MMDK/PlayerData/<fighter>/`. Existing JSON files with the same names are replaced. The batch temporarily disables MMDK moveset scripts for the selected fighters and `All Characters`, then restores their settings on completion, stop, or error. When P2 already has the requested fighter, it uses complete MMDK data already in memory or rebuilds that data directly. After a character switch, it attempts a direct rebuild if MMDK has not produced fresh data within 120 UI frames. Disable other REFramework mods that can change fighter data before starting. If a fighter was already modified in the current game session, restart the game before making a reference dump.

If a character fails to load or export, the run stops with an error in the UI and REFramework log. **Resume** retries that character without repeating completed characters. The script restores the previous MMDK fighter-enable settings when it finishes, stops, or encounters an error. **Stop** leaves you in the current training match.

## Limits

- The list comes from `MMDK/reframework/autorun/MMDK/tables.lua`. Add a new fighter's correct numeric ID and name there before including it. This is also required for MMDK itself to recognize the fighter.
- Each fighter still needs to be loaded by SF6. This script automates that sequence; it does not extract all fighters from game archives at once. Some DLC fighters may require access to their content in the installed game.
- The training character-switch call follows SF6's `TrainingManager:SetFighter` and `RequestTrainingFlow` interfaces. Game updates may change these interfaces. This repository cannot verify the live game behavior without SF6 and REFramework running.
- After a character switch, the batch verifies that MMDK produced a new `player_data[2]` instance before exporting. The UI displays what it is waiting for; a timeout message includes the last reason. Press **Resume** after correcting the issue.
