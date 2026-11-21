#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
evidence_dir="${1:-.omo/evidence/cloud-language}"
mkdir -p "$evidence_dir"
xcrun swiftc -swift-version 6 -default-isolation MainActor \
  Shared/CloudASR.swift Shared/Settings.swift Tests/CloudASRLanguageChecks.swift \
  -o "$evidence_dir/cloud-language-checks" 2>&1 | tee "$evidence_dir/compile.log"
printf '%s\n' 'PASS compiled production CloudASR.swift and Settings.swift with isolated test doubles' | tee -a "$evidence_dir/compile.log"
"$evidence_dir/cloud-language-checks" 2>&1 | tee "$evidence_dir/checks.log"
