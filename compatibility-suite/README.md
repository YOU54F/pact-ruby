# Pact compatibility suite (core)

A Cucumber runner for the [pact-compatibility-suite](https://github.com/pact-foundation/pact-compatibility-suite)
core features: everything in V1–V4 except `V4/plugins`. The steps drive `libpact_ffi` (from the `pact-ffi` gem
pact-ruby already depends on) through the calls a client library makes, mirroring the pact-reference FFI runner.

```bash
git clone https://github.com/pact-foundation/pact-compatibility-suite ../pact-compatibility-suite
bundle install
PACT_COMPAT_SUITE=$PWD/../pact-compatibility-suite compatibility-suite/run-core.sh
```

Extra arguments go to cucumber (for example `--name 'not empty matcher'`). `CUCUMBER_FORMAT` picks the formatter.

## Features

| Area | Features |
|---|---|
| HTTP consumer | V1, V2, V3, V4 `http_consumer` |
| HTTP provider | V1, V2, V3, V4 `http_provider` |
| Messages | V3, V4 `message_consumer` and `message_provider`, V4 `synchronous_message_consumer`, V4 `v4` |
| Generators | V3 `generators`, V3 `http_generators`, V4 `generators` |
| Matching | V3 `http_matching`, V3 and V4 `matching_rules` |

## Not run

- Scenarios the suite tags `@wip` (currently the V3 message provider Kafka schema registry scenario).
- `KNOWN_FAILURES` in `core/support/env.rb`: scenarios that fail because of a pact_ffi limitation. They are
  skipped with the reason so they show in every run. Remove an entry once pact_ffi is fixed.
  - *Supports a not empty matcher with binary data (negative case)*: the pact_ffi mock server reads a 0-byte
    request body as no body, so the `notEmpty` rule never sees it.
