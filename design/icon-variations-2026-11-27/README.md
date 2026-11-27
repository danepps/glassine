# Icon variations, 2026-11-27

Explorations on the shipping icon (fanned glassine leaves, four rules, the
Spectrum palette: red #E8300E, orange #E8A400, violet #9A64A0, blue #2148A0).
Nothing here has been adopted; the shipping icon is still `scripts/make-icon.swift`.

All renders come from `scripts/make-icon-spectrum-concepts.swift` at 1024 px on
the legacy macOS grid. The small previews on the boards are downscales, not the
per-size redraws the shipping pipeline makes.

| Folder / board | What it shows | Regenerate with |
|---|---|---|
| `00-board.png` + `01`–`09` | Round one: Shipping, Wide Fan, Hand of Cards, Cascade, Tinted Sheets, Rules Only, Rims Only, Bold Rules, Paper Tile | `swift scripts/make-icon-spectrum-concepts.swift <dir>` |
| `outline-weight/` | Shipping fan with the leaf outlines at 1×, 1.5×, 2×, 2.5×, 3×, 4× | `… <dir> --rims` |
| `wide-fan-2x/` | Wide Fan with a 2× outline (sheets 0.84) | `… <dir> --only wide-fan --rim-scale 2` |
| `wide-fan-2x-bigger/` | Wide Fan, 2× outline, sheets at 0.84, 0.90, 0.95 | `… <dir> --only wide-fan --rim-scale 2 --leaf-scale 0.84,0.90,0.95` |

Where it was left: Wide Fan with a 2× outline was the favourite; the open
question is the sheet size, 0.90 (a small step up) or 0.95 (close to the
shipping icon's size).
