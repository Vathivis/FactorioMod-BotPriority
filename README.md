# Bot Priority

Bot Priority is a Factorio 2.0+ mod that lets you prioritize selected work by temporarily pausing matching work outside the selected area.

Supported work types:
- Entity ghosts
- Entity deconstruction orders
- Entity upgrade orders

## What It Does

Select an area with the Bot Priority tool and the mod will:
- prioritize ghosts inside the selected area
- reissue deconstruction and upgrade orders inside the selected area
- pause matching work outside the selected area
- automatically restore paused work when the prioritized work is finished

Unrelated work continues normally.

## Example

If you select part of a reactor blueprint, the boilers, heat exchangers, turbines, and reactors in that area are prioritized first. Matching work elsewhere is paused until the prioritized area is finished or the priority is cleared.

## How To Use

1. Enable the mod in Factorio 2.0+.
2. Use the Bot Priority shortcut to get the selection tool.
3. Drag over the area you want to prioritize.
4. Reverse-select with the same tool to clear the active priority manually.

## Safe Uninstall

Before removing the mod:

1. Open mod settings.
2. Enable the safe uninstall setting.
3. Wait for the completion message in-game.
4. Save the game.
5. Disable or remove the mod.

This restores paused work and cleans up the temporary forces created by the mod.

## Current Limitations

- Hover highlighting is ghost-only.
  Factorio's selection-tool API can filter by static entity type, but it cannot visually highlight only entities currently marked for deconstruction or upgrade.
- Entity-only support.
  Tile ghosts, tile deconstruction proxies, and similar tile-based orders are not handled yet.
- Priority is strict.
  If prioritized work is unreachable by robots, matching work elsewhere can remain paused until coverage exists or priority is cleared.
- The mod influences bot behavior indirectly.
  Factorio does not expose direct script control over the construction queue or per-robot task assignment.

## Notes

- Factorio version: 2.0+
- Author: Vathivis
