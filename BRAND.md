# Name, icon and artwork

Kekkai's **source code** is free software under the [GNU Affero General Public License, version 3 or any
later version](LICENSE) (AGPL-3.0-or-later).

The **Kekkai name and its brand assets are not covered by that licence.** They stay © 2026 Gino de Graaff
(mostlygino), all rights reserved:

- the name "Kekkai" and "結界" used as the name of this app;
- the app icon (the tied stone on raked gravel) in `App/Assets.xcassets/AppIcon.appiconset/`;
- the mostlygino seal in `App/Assets.xcassets/Developer.imageset/`;
- the images in `docs/brand/` and `docs/screenshots/`;
- the DMG and installer artwork that `scripts/make-art.swift` draws (the script itself is AGPL code).

You're welcome to show them when you write about, review or link to Kekkai. If you **fork** Kekkai and
distribute your fork, give it a different name and icon, so people can tell the two apart. The code is yours to
use under the AGPL either way.

## Third-party data

- Country outlines: [Natural Earth](https://www.naturalearthdata.com), public domain (`App/Resources/world.json`).
- IP to country: [DB-IP](https://db-ip.com) IP to Country Lite, CC BY 4.0. Not in the repository;
  `scripts/fetch-geoip.sh` downloads it at build time, and the app shows the attribution.
