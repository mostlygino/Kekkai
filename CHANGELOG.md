# Changelog

All notable changes. Versions follow [semantic versioning](https://semver.org).

## [0.1.1] - 2026-10-21 · Beta

### Changed
- **New app icon:** the tied river stone on raked gravel, redrawn to the standard of the other mostlygino apps.
  README banners and the social preview carry it too.

## [0.1.0] - 2026-10-19 · Beta

First public release.

### Added
- **Watch mode:** live connections per app from macOS's own `nettop`, without the network filter or an admin password.
- **System Firewall:** apply the Block List to macOS itself (pf for addresses, `/etc/hosts` for names), with one
  password prompt per change, a "not applied yet" bar and one-click removal. Verified on a real Mac.
- **Block one app without the filter:** blocks the addresses only that app has used; extends as it reaches new ones.
- Network filter (Network Extension) with four modes (Block List, Require Approval, Allow All, Block All), rules
  per app and per domain, an Allow List, Block All exceptions for Apple software and DNS, and hostnames from TLS
  server names and DNS answers.
- Apps, Destinations, Activity and Map panes; inspector with code signature and the developer's declared connections.
- ⌘K command palette; menu bar panel with Recently Blocked; floating approval panel with notifications.
- Readable names and real icons for helpers, macOS services, system extensions and command-line tools.
- Signed updates from GitHub releases; DMG, guided installer and updater zip, each with a release-key signature.
- Demo mode for screenshots and UI work.

