#!/usr/bin/env bash

set -euo pipefail

binary="${1:?usage: run-android-tests.sh <test-binary> [args...]}"
shift
remote_dir="/data/local/tmp/tonalli"
remote_binary="$remote_dir/$(basename "$binary")"

# Quotes a single arg for the device shell command line below: wraps it in
# single quotes, escaping embedded single quotes as '\''. The suite filters
# forwarded here contain spaces, colons, parens, and a trailing `*`, none of
# which may be word-split or glob-expanded on the far side.
quote_for_device() {
  local s=$1 q="'" esc="'\\''"
  printf "'%s'" "${s//$q/$esc}"
}

remote_args=""
for arg in "$@"; do
  remote_args+=" $(quote_for_device "$arg")"
done

adb shell "mkdir -p '$remote_dir'"
adb push "$binary" "$remote_binary"
adb shell "chmod 755 '$remote_binary'"
adb shell "cd '$remote_dir' && '$remote_binary'$remote_args"
