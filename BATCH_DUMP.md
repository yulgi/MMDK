# Batch dumping fighter data

`MMDK_BatchDump.lua` exports the current game's fighter data for multiple characters in one run. It uses Training Mode to load each requested fighter as P2, waits for MMDK to rebuild `player_data[2]`, and then writes the same **fighter-specific** JSON files as MMDK's `Dump All` button. Shared `common_moves.json`, `common_atemi.json`, and `common_rects.json` are not part of this batch.

## Install and run

1. Install MMDK and a compatible REFramework build for SF6.
2. Copy `MMDK_BatchDump.lua` beside `MMDK.lua` in the game's `reframework/autorun/` folder.
3. Start SF6, enter Training Mode, and open REFramework's **Script Generated UI → MMDK Batch Dump**.
4. Leave the default ID list to export every fighter known to `MMDK/tables.lua`, or enter a subset such as `1,10,26` or `1-22,26,27`.
5. Press **Start new batch**. Wait until the status says **Finished**. The script changes P2 automatically. It does not require you to open the character-select screen for each fighter.

The output is written under `reframework/data/MMDK/PlayerData/<fighter>/`. Existing JSON files with the same names are replaced. Keep other moveset mods disabled if you need the game's unmodified data.

If a character fails to load or export, the run stops with an error in the UI and REFramework log. **Resume** retries that character without repeating completed characters. The script restores the previous MMDK fighter-enable settings when it finishes, stops, or encounters an error. **Stop** leaves you in the current training match.

## Limits

- The list comes from `MMDK/reframework/autorun/MMDK/tables.lua`. Add a new fighter's correct numeric ID and name there before including it. This is also required for MMDK itself to recognize the fighter.
- Each fighter still needs to be loaded by SF6. This script automates that sequence; it does not extract all fighters from game archives at once.
- The training character-switch call follows SF6's `TrainingManager:SetFighter` and `RequestTrainingFlow` interfaces. Game updates may change these interfaces. This repository cannot verify the live game behavior without SF6 and REFramework running.
