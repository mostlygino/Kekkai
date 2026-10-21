# Contributing to Kekkai

Thanks for taking a look. Kekkai is a small native macOS app; contributions of every size are welcome, from a
typo to a new feature.

## Before you start

- **Bugs:** open an issue with the bug template. Include your macOS version and whether you run the network
  filter, Watch mode or the system firewall.
- **Features:** open an issue first, so we can agree on the shape before you write code.
- **Security problems:** don't open a public issue. See [SECURITY.md](SECURITY.md).

## Build and run

You need macOS 26 or later, Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
scripts/fetch-geoip.sh     # optional: country data (not in git)
scripts/check.sh           # the logic checks; run these before every pull request
xcodegen generate
open Kekkai.xcodeproj
```

You don't need an Apple Developer account to work on Kekkai. Without one the network filter can't load, but
everything else works:

```sh
scripts/install.sh                                    # ad-hoc build into /Applications
open -n build/Build/Products/Debug/Kekkai.app --args -demo            # demo traffic, no filter needed
open -n build/Build/Products/Debug/Kekkai.app --args -demo -demoTour  # walks every screen, then quits
```

More demo flags: `-demoPane <apps|destinations|activity|map|rules>`, `-demoAppearance light|dark`,
`-demoOffline` (as if the filter can't load), `-demoOnboarding` (first launch), `-quitAfter <seconds>`.

## How the code is laid out

| Path | What |
|---|---|
| `Shared/` | Pure logic shared by app and extension: rules, TLS SNI and DNS parsing, GeoIP, the system-firewall plan. Covered by `scripts/check.sh`. |
| `Extension/` | The Network Extension content filter (system extension). |
| `App/` | The SwiftUI app. |
| `scripts/` | Checks, install, release, artwork (`make-art.swift`), DMG and installer builders. |
| `DESIGN.md`, `PRODUCT.md` | The design system and product principles. Read these before UI changes. |

## Pull requests

- Keep a pull request to one change. Small is good.
- Add or extend a check in `Tests/main.swift` when you change logic in `Shared/`.
- Match the code around you: comment density, naming, idiom. Comments say *why*.
- UI: follow [DESIGN.md](DESIGN.md). One vermilion accent, system fonts (New York only for headings), verdicts
  never rely on colour alone, every control reachable by keyboard and VoiceOver.
- Copy: British English, short sentences, plain words. Say what happens, not what the code does.
- Never add telemetry, analytics or anything that sends data off the Mac. That is a product principle, not a
  preference.

## Licence

By contributing you license your work under [AGPL-3.0-or-later](LICENSE), the same licence as the rest of the
code. There is no contributor licence agreement. The Kekkai name, icon and artwork are not part of that licence;
see [BRAND.md](BRAND.md).
