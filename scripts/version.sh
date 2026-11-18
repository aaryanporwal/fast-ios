#!/bin/bash
# Prints fast-ios's version, read from the one place it is set:
# `static let current` in Sources/fast-ios/SimpleCommands.swift.
cd "$(dirname "$0")/.."
sed -n 's/.*static let current = "\([^"]*\)".*/\1/p' Sources/fast-ios/SimpleCommands.swift | head -1
