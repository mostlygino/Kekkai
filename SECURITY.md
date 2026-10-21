# Security

Kekkai runs a network filter with system privileges and, without it, changes macOS's firewall and `/etc/hosts`
as root. Security reports are very welcome.

## Reporting

Please report vulnerabilities privately through
[GitHub's private vulnerability reporting](https://github.com/mostlygino/Kekkai/security/advisories/new).
Don't open a public issue for a security problem.

Include what you found, how to reproduce it, and what an attacker could do with it. You'll get an answer as
soon as the maintainer can; this is a one-person project, so there is no fixed response time.

## Scope

In scope:

- The Network Extension (`Extension/`) and its XPC connection with the app (both check the other's code signature).
- The system-firewall path (`Shared/SystemFirewallPlan.swift`, `App/SystemFirewall.swift`): the root script it
  builds, how entries are validated and quoted, and what it writes to pf and `/etc/hosts`.
- The updater (`App/Updater.swift`): release download, signature check against the pinned release key, and
  the swap of the app bundle.
- Parsing of untrusted network data: TLS ClientHello (`Shared/SNI.swift`), DNS answers (`Shared/DNS.swift`),
  nettop output (`Shared/Nettop.swift`).

Out of scope: builds you modified yourself, and issues that need an attacker who already has root on the Mac.

## Supported versions

Only the latest release gets fixes.
