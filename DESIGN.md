# Design

## World: Sumi & shu

A quiet native tool with one signature colour. Sumi (ink) and washi (paper)
neutrals come from the system materials; shu (vermilion, 朱) is reserved for
the barrier itself: blocks, the active filter, decisions. It works like a
hanko seal on a page: small, rare, unmistakable.

## Colour

| Token | Light | Dark | Use |
|---|---|---|---|
| `shu` (AccentColor) | `#D9412B` | `#F0563E` | Accent: filter on, primary actions, selection |
| `block` | `shu` | `shu` | Blocked verdicts, block buttons |
| `allow` | `#2F7D5B` (matsu, pine) | `#4FB386` | Allowed verdicts, sparingly |
| `ask` | `#C08A1E` (kohaku, amber) | `#E3A93A` | Waiting for approval |
| `received` | `#3A5BA0` (ai, indigo) | `#7C9BE0` | Chart: received |
| `sent` | `shu` | `shu` | Chart: sent |

Neutrals are system (`.primary`, `.secondary`, window and sidebar materials).
No grey text on coloured fills; tint from the fill instead.

## Type

System font (SF Pro) only. Hierarchy from the system text styles. Numbers in
tables and charts are monospaced digits. The one display moment is the
onboarding title, set in `.largeTitle` weight semibold.

## Motif

The garden, restrained. Kekkai is a karesansui (dry garden) seen from a modern window:

- **The tied stone** (sekimori-ishi, 関守石): a stone tied with cord that means "no further". It is the app
  icon and the status mark. Raised barrier: dark basalt stone, vermilion cord. Lowered: the stone's outline.
- **Raked gravel:** faint concentric rings behind onboarding and empty states, and around your region on the
  map. Never behind data.
- **The seal** (hanko): a small vermilion square with 止 ("stop") marks a blocked verdict, always with the word.
- **The serif voice:** New York (the system serif) for headings in inspectors, empty states, onboarding and
  About. Everything else stays SF.

## Surfaces

- Main window: sidebar + content, standard toolbar. System Liquid Glass on
  sidebar and toolbar only.
- Menu bar panel and approval panel: own surfaces, `glassEffect` backgrounds.
- No cards nested in cards. Tables are plain system tables.

## Motion

One authored moment: when the filter turns on, the stone's cord ties itself
(trim 0 to 1, 700 ms, ease-out, then the knot appears) and the status settles. Everything
else is 150 to 250 ms state change. Reduce Motion: no drawing, instant state.

## Iconography

SF Symbols, one weight (regular) per context. Verdicts: `checkmark.circle`
allow, `xmark.octagon` block, `hourglass` ask. Each verdict also has a word.

## App icon

Sekimori-ishi (関守石): a basalt stone tied with shu cord on raked gravel, the
garden sign for "no further". Rendered by `scripts/make-icon.swift`; brief,
decisions and export steps in [docs/brand](docs/brand/README.md). Shared craft
standard: [docs/design/APP_DESIGN.md](docs/design/APP_DESIGN.md).

The stone carries through in three places only: the menu bar (`StoneGlyph`, a
template image: cord tied while the barrier is up, the bare stone when it is
down), the onboarding hero and the About tab (the app icon itself). Everywhere
else the hexagon stays the barrier's mark.
