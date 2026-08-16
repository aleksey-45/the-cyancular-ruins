# Structure Editor of CyR — Design

Date: 2026-08-14

## Purpose

A developer tool for **The Cyancular Ruins** that lets a designer hand-craft
"structures" (small hand-authored tile patterns) on a grid and export them into
the game config, so a future rewrite of the random map generator can embed them.
Pure random generation cannot reliably produce ideal maps; curated structures
fill that gap.

This deliverable is **the editor only**. No game-side code changes are made —
the map-generation rewrite is explicitly out of scope.

## Constraints

- Pure **HTML + CSS + JS**, no build step, no server, no external dependencies.
- Runs by double-clicking a single self-contained `.html` file in a browser.
- Tile types are numbers `0`–`9`. Functionally today: `0` = air/empty,
  `1`–`9` = wall. Later each digit will map to a texture (images come later;
  the editor shows distinct placeholder colors per digit now).

## Data model

A **structure** is a 2D array of tile numbers, indexed `grid[y][x]`, elements in
`0`–`9`. Width = length of any row; height = number of rows. Both are derivable
from the array — no separate metadata is required.

The editor holds a **library**: an ordered list of named structures.

## Export format (the contract)

Plain text, UTF-8. One structure = one run of digit rows; each digit is one tile.

```
# tower_01
000111000
001000100
001111000
000000000
```

Rules:

- One line per row, characters are the tile digits `0`–`9`.
- `# name` starts a structure only at the start of a block (file start or after
  a blank line). Any other `#` line — including mid-block `# text` — is a
  comment and never breaks the current structure.
- Blank lines are ignored; they also separate consecutive structures (a new
  structure must follow a blank line or the file start).
- All rows of a structure must be the same length.
- Export produces a single file containing the whole library (multiple `# name`
  blocks), downloaded via the browser.

GDScript parse is trivial: `FileAccess.get_as_text()` → split lines → per-line
split chars → `int()`. No JSON parser required.

## Editor UI

Layout:

- **Left sidebar**
  - Structure library list: add / rename / duplicate / delete / select.
  - Tile palette `0`–`9`: `0` shown transparent ("air"), `1`–`9` as nine
    distinct placeholder colors. Click a swatch to set the paint tile.
  - Canvas size controls (width / height in tiles; resizing trims or pads with
    `0`). Changing size applies to the selected structure.
- **Center canvas**
  - Grid of cells colored by their tile value (placeholder palette).
  - Wheel zoom, drag to pan, toggle grid lines, fit-to-view.
  - Left-drag paints the current tile; right-drag / alt erases (paints `0`).
- **Tools**: paint, rectangle, flood fill, erase, undo / redo (Ctrl+Z / Ctrl+Y).
- **Top bar**
  - Export: downloads the whole library as one file.
  - Import: reads a previously exported library file back in for editing
    (name collisions resolve by making the imported name unique).

## Validation

- Structure names: non-empty, unique within the library, safe characters
  (letters, digits, CJK, `_`, `-`; no spaces, no leading `-`; max 32 chars;
  empty input falls back to `structure`).
- Grids: digits only (`0`–`9`), at least 1 row / 1 column, all rows equal width.
- Import: malformed rows (bad char / ragged width) are rejected with a clear
  message; nothing is written on failure.
- A structure must contain at least one non-zero cell to be considered
  non-trivial (advisory warning, not a block).

## File organization

- Single self-contained file: `the-cyancular-ruins/editor/structure-editor.html`
  (CSS and JS inlined; no network requests, works via `file://`).
- The exported library file is dropped by the user into the game config; that
  consumption path is not part of this task.

## Testing

- Core serialization / parsing / validation live in small pure functions, so a
  quick manual round-trip (export → import) plus a short `node` smoke script can
  verify them without the browser.
- Manual browser checks: paint, rectangle, fill, undo/redo, resize (trim/pad),
  zoom/pan, export → import round-trip, malformed-import rejection.
