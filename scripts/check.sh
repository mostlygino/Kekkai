#!/bin/sh
# Compiles the shared filter logic with its checks and runs them (asserts on, -Onone).
set -e
cd "$(dirname "$0")/.."
out=$(mktemp -d)
swiftc -Onone Shared/Rules.swift Shared/SNI.swift Shared/GeoTable.swift Shared/DNS.swift Shared/Nettop.swift Shared/SystemFirewallPlan.swift Tests/main.swift -o "$out/check"
"$out/check"
