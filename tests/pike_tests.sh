#!/bin/sh
# Run Pike unit tests via PUnit with JUnit XML report
# Always cd to project root first — shell tests may have left CWD at /
_pmp_shim="$(cd "$(dirname "$0")/.." && pwd)/bin/pmp"
_project_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$_project_root"

# Run with JUnit XML report
# Modules should be restored by restore_store() in helpers.sh after shell tests.
# If they're missing (e.g. network failed during reinstall), install them now.
if ! [ -e "modules/PUnit.pmod" ]; then
    sh bin/pmp install || true
fi
pike -M modules -M bin tests/run_pike_tests.pike --junit tests/reports/pike-junit.xml "$@"
# Propagate Pike test exit code
exit $?