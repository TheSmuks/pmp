#!/bin/sh
# Run Pike unit tests via PUnit with JUnit XML report
_self="$(cd "$(dirname "$0")" && pwd)"
cd "$_self/.."

# Install PUnit if not present
if [ ! -d modules/PUnit.pmod ]; then
    sh bin/pmp install || exit 1
fi

# Ensure reports directory exists
mkdir -p tests/reports

# Run with JUnit XML output
# Note: we specify --nojit to avoid potential JIT caching issues
# that can cause non-deterministic behavior in test runners
exec pike --nojit -M modules -M bin tests/pike/run_tests.pike --junit tests/reports/pike-junit.xml "$@"