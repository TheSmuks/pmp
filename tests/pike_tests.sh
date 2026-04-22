#!/bin/sh
# Run Pike unit tests via PUnit
_self="$(cd "$(dirname "$0")" && pwd)"
cd "$_self/.."

# Install PUnit if not present
if [ ! -d modules/PUnit.pmod ]; then
    sh bin/pmp install || exit 1
fi

exec pike -M modules -M bin tests/pike/run.pike "$@"
