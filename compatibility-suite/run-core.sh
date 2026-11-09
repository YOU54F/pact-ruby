#!/usr/bin/env bash
# Runs the core (non-plugin) pact-compatibility-suite V1-V4 features against pact-ruby.
#
#   PACT_COMPAT_SUITE=/path/to/pact-compatibility-suite compatibility-suite/run-core.sh [cucumber args]
#
# CUCUMBER_FORMAT (default: progress) picks the formatter.
# Skips (exit 0) when PACT_COMPAT_SUITE is unset or has no features.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUITE="${PACT_COMPAT_SUITE:-}"

if [[ -z "$SUITE" || ! -d "$SUITE/features/V1" ]]; then
  echo "Skipping core compatibility suite: PACT_COMPAT_SUITE is unset or has no features"
  exit 0
fi

FEATURES=(
  V1/http_consumer V1/http_provider
  V2/http_consumer V2/http_provider
  V3/http_consumer V3/http_provider V3/message_consumer V3/message_provider
  V3/generators V3/http_generators V3/http_matching V3/matching_rules
  V4/http_consumer V4/http_provider V4/message_consumer V4/message_provider
  V4/synchronous_message_consumer V4/generators V4/matching_rules V4/v4
)
PATHS=()
for f in "${FEATURES[@]}"; do
  [[ -f "$SUITE/features/$f.feature" ]] && PATHS+=("$SUITE/features/$f.feature")
done

cd "$ROOT"
export CUCUMBER_PUBLISH_QUIET=true
exec bundle exec cucumber "${PATHS[@]}" \
  --require compatibility-suite/core \
  --tags 'not @wip' \
  --format "${CUCUMBER_FORMAT:-progress}" \
  "$@"
