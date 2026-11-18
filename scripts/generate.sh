#!/usr/bin/env bash
# Generate Eros.xcodeproj from project.yml with XcodeGen.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen not found: brew install xcodegen" >&2
    exit 1
fi

cd "$repo_root"
xcodegen generate --spec project.yml
