#!/bin/sh
# pmp test suite — backwards-compat shim that delegates to runner.sh
#
# Run: sh tests/test_install.sh
# From: pmp repo root
#
# This file delegates to runner.sh which discovers and runs all test_*.sh files.
# Use runner.sh directly for more control: sh tests/runner.sh [test_file ...]

exec sh "$(dirname "$0")/runner.sh" "$@"
