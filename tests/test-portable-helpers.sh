#!/usr/bin/env bash

set -u

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-portable-helpers.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

fail() { echo "test-portable-helpers.sh: $*" >&2; exit 1; }

extract_function() {
  awk '
    /^file_mtime\(\)[[:space:]]*\{/ { capture = 1 }
    capture { print }
    capture && /\}[[:space:]]*$/ { exit }
  ' "$1"
}

extract_locale_snippet() {
  awk '
    /# locale-select begin/ { capture = 1 }
    capture { print }
    /# locale-select end/ {
      if (capture) {
        exit
      }
    }
  ' "$1"
}

helper_files='
scripts/propose.sh
scripts/trial-enqueue.sh
scripts/trial-poll.sh
scripts/council-record.sh
scripts/growth-lint.sh
scripts/lib-adopt.sh
'

file_mtime_def=''
for helper_file in $helper_files; do
  body=$(extract_function "$root/$helper_file")
  [ -n "$body" ] || fail "missing file_mtime() in $helper_file"
  if [ -z "$file_mtime_def" ]; then
    file_mtime_def=$body
  elif [ "$body" != "$file_mtime_def" ]; then
    fail "file_mtime() drifted in $helper_file"
  fi
done

eval "$file_mtime_def"

mtime_target="$tmp/mtime-target"
printf 'x\n' >"$mtime_target"
mtime_value=$(file_mtime "$mtime_target") || fail "file_mtime() failed on an existing file"
case "$mtime_value" in
  ''|*[!0-9]*)
    fail "file_mtime() returned a non-numeric epoch: $mtime_value"
    ;;
esac
case "$mtime_value" in
  *'
'*)
    fail 'file_mtime() returned multiple lines'
    ;;
esac

missing_stdout="$tmp/missing.stdout"
if file_mtime "$tmp/does-not-exist" >"$missing_stdout" 2>"$tmp/missing.stderr"; then
  fail 'file_mtime() succeeded on a missing path'
else
  missing_status=$?
fi
[ "$missing_status" -ne 0 ] || fail 'file_mtime() missing-path status was zero'
[ ! -s "$missing_stdout" ] || fail 'file_mtime() wrote stdout for a missing path'

rubyless_bin="$tmp/rubyless-bin"
mkdir -p "$rubyless_bin" || fail 'could not create ruby-less bin directory'
rubyless_stdout="$tmp/rubyless.stdout"
if (
  PATH="$rubyless_bin"
  file_mtime "$mtime_target"
) >"$rubyless_stdout" 2>"$tmp/rubyless.stderr"; then
  fail 'file_mtime() unexpectedly succeeded without ruby on PATH'
else
  rubyless_status=$?
fi
[ "$rubyless_status" -eq 127 ] || fail "file_mtime() exited $rubyless_status instead of 127 without ruby"
[ ! -s "$rubyless_stdout" ] || fail 'file_mtime() wrote stdout without ruby on PATH'

locale_files='
scripts/propose.sh
scripts/trial-enqueue.sh
scripts/trial-poll.sh
scripts/council-convene.sh
scripts/council-record.sh
scripts/council-quorum.sh
scripts/run-trial-poll.sh
scripts/run-growth-lint.sh
tests/run.sh
'

locale_snippet=''
locale_snippet_count=0
for locale_file in $locale_files; do
  body=$(extract_locale_snippet "$root/$locale_file")
  [ -n "$body" ] || fail "$locale_file is missing the locale-select snippet markers"
  if [ -z "$locale_snippet" ]; then
    locale_snippet=$body
  elif [ "$body" != "$locale_snippet" ]; then
    fail "locale-select snippet drifted in $locale_file"
  fi
  locale_snippet_count=$((locale_snippet_count + 1))
done
[ "$locale_snippet_count" -eq 9 ] || fail "expected 9 identical locale-select snippets, found $locale_snippet_count"

locale_case_count=0
run_locale_case() {
  name=$1
  locale_output=$2
  expected=$3
  inherited_lc_all=${4:-}
  create_locale_stub=${5:-yes}
  stub_dir="$tmp/$name"
  mkdir -p "$stub_dir" || fail "could not create stub dir for $name"
  locale_stub="$stub_dir/locale"
  if [ "$create_locale_stub" = yes ]; then
    {
      printf '%s\n' '#!/bin/bash'
      printf '%s\n' 'if [ "${1:-}" = "-a" ]; then'
      printf '%s\n' "  while IFS= read -r line; do printf '%s\\n' \"\$line\"; done <<'OUT'"
      printf '%s\n' "$locale_output"
      printf '%s\n' 'OUT'
      printf '%s\n' '  exit 0'
      printf '%s\n' 'fi'
      printf '%s\n' 'exit 2'
    } >"$locale_stub" || fail "could not write locale stub for $name"
    chmod +x "$locale_stub" || fail "could not chmod locale stub for $name"
  fi

  locale_test="$tmp/$name.sh"
  {
    if [ -n "$inherited_lc_all" ]; then
      printf 'export LC_ALL=%s\n' "$inherited_lc_all"
    else
      printf '%s\n' 'unset LC_ALL'
    fi
    printf '%s\n' "$locale_snippet"
    printf '%s\n' 'printf "%s" "${LC_ALL:-}"'
  } >"$locale_test" || fail "could not write locale test for $name"

  selected=$(PATH="$stub_dir" /bin/bash "$locale_test") || fail "locale-select snippet failed for $name"
  [ "$selected" = "$expected" ] || fail "locale-select chose $selected instead of $expected for $name"
  locale_case_count=$((locale_case_count + 1))
}

run_locale_case c_utf8_only 'C.utf8' 'C.UTF-8'
run_locale_case en_us_utf8 'en_US.utf8' 'en_US.UTF-8'
run_locale_case neither 'POSIX' 'C.UTF-8'
run_locale_case inherited_utf8 'C.utf8' 'en_GB.UTF-8' 'en_GB.UTF-8'
run_locale_case en_us_precedence 'C.utf8
en_US.utf8' 'en_US.UTF-8'
run_locale_case en_us_macos 'en_US.UTF-8' 'en_US.UTF-8'
run_locale_case locale_absent '' 'C.UTF-8' '' no
[ "$locale_case_count" -eq 7 ] || fail "expected 7 locale-selection cases, ran $locale_case_count"

echo "test-portable-helpers.sh: PASS ($locale_case_count locale-selection cases)"
