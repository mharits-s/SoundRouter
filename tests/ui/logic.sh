#!/bin/sh
# headless UI-logic tests (no display, no permissions): meter ballistics
cd "$(dirname "$0")/../.." || exit 1
T=$(mktemp -d); mkdir $T/src; cp tests/ui/logic-ui.swift $T/src/main.swift
swiftc -O $T/src/main.swift app/Model.swift app/Logic.swift -o $T/logic-ui 2>$T/err.log || { cat $T/err.log; exit 1; }
$T/logic-ui
