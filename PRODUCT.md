# Product

Kekkai (結界, "barrier") is a native macOS app firewall. It shows which apps on
your Mac connect where and lets you block apps or domains, or hold new apps
until you decide.

## Platform

macOS 26 and later, Apple silicon and Intel. Native SwiftUI app with a
Network Extension content filter shipped as a system extension.

## Stack

Swift 5 language mode, SwiftUI, Swift Charts, NetworkExtension,
SystemExtensions, XcodeGen. No third-party dependencies.

## Users

People who want to know what their Mac talks to: developers, privacy-minded
users, security people. Comfortable with technical detail (hosts, ports,
signatures) but they want the answer at a glance.

## Product Purpose

Make network activity visible and controllable per app, without a cloud
account. Everything stays on the Mac.

## Positioning

Personal open-source project and showreel piece by mostlygino. Inspired by
the category (Little Snitch, LuLu, TinyShield); own name, code, copy and art.

## Operating Context

Runs all day. The main window is opened now and then to look; the menu bar
panel and the approval panel are the everyday surfaces. Approval prompts
interrupt other work, so they must be quick to read and answer.

## Capabilities and Constraints

- Loading the extension needs a paid Apple Developer team (Network Extension
  capability). Unsigned builds run the UI only.
- `-demo` launch argument feeds synthetic traffic for UI work and screenshots.
- Domain rules depend on knowing the hostname (system hostname or TLS SNI).

## Brand Commitments

Sumi & shu: ink and washi neutrals with a single vermilion accent used like a
hanko seal. Calm, exact, native. British English in copy.

## Evidence on Hand

None from users yet.

## Product Principles

1. The answer first: who connected, where, and was it allowed.
2. Nothing leaves the Mac.
3. Never stall the system: Apple system software is never held for approval.
4. Honest state: say when the filter is off, unreachable, or guessing.

## Accessibility & Inclusion

System text styles (Dynamic Type sizes on macOS), full keyboard reach, VoiceOver
labels on icon-only controls, colour never the only signal (verdicts also carry
a symbol and a word), Reduce Motion respected.
