#!/usr/bin/env bash

set -u

failures=0

pass() {
  printf 'PASS: %s\n' "$1"
}

fail() {
  printf 'FAIL: %s\n' "$1"
  failures=$((failures + 1))
}

player_present() {
  local state
  state=$(hs -c 'return player ~= nil and "present" or "missing"' 2>/dev/null) || return 1
  [[ "$state" == *present* ]]
}

if ! command -v hs >/dev/null 2>&1; then
  fail "hs CLI is available"
  exit 1
fi

(hs -c 'hs.reload()' >/dev/null 2>&1 &)
sleep 3

if hs -c 'assert(type(speak) == "function"); assert(type(readSelection) == "function"); return "alive"' >/dev/null 2>&1; then
  pass "config reloads and stays alive"
else
  fail "config reloads and stays alive"
fi

started=$SECONDS
hs -c 'speak(string.rep("The first audio should start quickly and playback should continue smoothly while following chunks are fetched in the background without pausing between words ", 6))' >/dev/null 2>&1

ready=false
for _ in {1..30}; do
  if player_present; then
    ready=true
    break
  fi
  sleep 0.1
done
if $ready; then
  pass "first audio starts within 3 seconds"
else
  fail "first audio starts within 3 seconds"
fi

while (( SECONDS - started < 10 )); do sleep 0.2; done
if player_present; then
  pass "playback is active at +10 seconds"
else
  fail "playback is active at +10 seconds"
fi

while (( SECONDS - started < 20 )); do sleep 0.2; done
if player_present; then
  pass "playback is active at +20 seconds"
  active_at_20=true
else
  fail "playback is active at +20 seconds"
  active_at_20=false
fi

if $active_at_20 && hs -c 'readSelection(); return player == nil and "stopped" or "playing"' 2>/dev/null | grep -q stopped; then
  pass "second trigger stops playback"
else
  fail "second trigger stops playback"
  hs -c 'speak("")' >/dev/null 2>&1 || true
fi

# About 1,755 characters split into at most five requests, or one before quota fallback.
long_started=$SECONDS
hs -c 'speak(string.rep("Long-form reading keeps enough audio buffered so later chunks can wait in sequence while the current chunk plays smoothly without interruptions or silence even when a request needs a short retry ", 9))' >/dev/null 2>&1

for checkpoint in 10 25 40; do
  while (( SECONDS - long_started < checkpoint )); do sleep 0.2; done
  if player_present; then
    pass "long playback is active at +${checkpoint} seconds"
  else
    fail "long playback is active at +${checkpoint} seconds"
  fi
done

hs -c 'readSelection()' >/dev/null 2>&1 || true

if curl --silent --show-error --fail --max-time 2 \
    http://127.0.0.1:8930/v1/models >/dev/null 2>&1; then
  kokoro_audio=$(mktemp "${TMPDIR:-/tmp}/readflow-kokoro.XXXXXX")
  kokoro_status=$(curl --silent --show-error --max-time 30 \
    --output "$kokoro_audio" --write-out '%{http_code}' \
    --header 'Content-Type: application/json' \
    --data '{"model":"mlx-community/Kokoro-82M-bf16","input":"Readflow local voice test.","voice":"af_heart","response_format":"wav"}' \
    http://127.0.0.1:8930/v1/audio/speech) || kokoro_status=""
  if [[ "$kokoro_status" == "200" && -s "$kokoro_audio" ]]; then
    pass "local kokoro voice serves audio"
  else
    fail "local kokoro voice serves audio"
  fi
  rm -f "$kokoro_audio"
else
  printf 'SKIP: local kokoro not installed\n'
fi

if (( failures > 0 )); then
  printf '%d check(s) failed\n' "$failures"
  exit 1
fi

printf 'All checks passed\n'
