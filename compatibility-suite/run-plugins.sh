#!/usr/bin/env bash
# Runs the pact-compatibility-suite V4 plugin features against pact-ruby.
#
#   PACT_COMPAT_SUITE=/path/to/pact-compatibility-suite compatibility-suite/run-plugins.sh [cucumber args]
#
# CUCUMBER_FORMAT (default: progress) picks the formatter. PACT_COMPAT_PATH_REPORT=<file>
# writes the per-feature DSL/FFI path counts as JSON.
# Skips (exit 0) when PACT_COMPAT_SUITE is unset or has no features/V4/plugins.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FEATURES="${PACT_COMPAT_SUITE:-}/features/V4/plugins"

if [[ -z "${PACT_COMPAT_SUITE:-}" || ! -d "$FEATURES" ]]; then
  echo "Skipping plugin compatibility suite: PACT_COMPAT_SUITE is unset or has no features/V4/plugins"
  exit 0
fi

cd "$ROOT"
export CUCUMBER_PUBLISH_QUIET=true
exec bundle exec cucumber "$FEATURES" \
  --require compatibility-suite/plugins \
  --tags 'not @wip' \
  --format "${CUCUMBER_FORMAT:-progress}" \
  "$@"
