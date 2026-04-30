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
exec pike -M modules -M bin -M bin/core -M bin/transport -M bin/store -M bin/project -M bin/commands tests/pike/run.pike --junit tests/reports/pike-junit.xml "$@"
