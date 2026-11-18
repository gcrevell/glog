#!/usr/bin/env bash
# Starts the Graylog in test/compose.yml, sends it known messages, and checks
# every glog command's output against them, once per shell given.
#
#   test/run.sh [--keep] [SHELL...]
#
# SHELL defaults to bash, plus /bin/bash when it's macOS's 3.2. --keep leaves
# the stack running afterwards (docker compose -f test/compose.yml down -v).
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
compose=(docker compose -f "$repo/test/compose.yml")
api=http://127.0.0.1:19000/api
gelf=http://127.0.0.1:19201/gelf
day=1768478400 # 2026-01-15T12:00:00Z
version=$(sed -n 's|^ *image: graylog/graylog:||p' "$repo/test/compose.yml")

keep=false
if [[ ${1-} == --keep ]]; then
  keep=true
  shift
fi
shells=("$@")
if [[ $# -eq 0 ]]; then
  shells=(bash)
  if [[ $(/bin/bash -c 'echo $BASH_VERSINFO' 2>/dev/null) == 3 ]]; then
    shells+=(/bin/bash)
  fi
fi

admin() {
  curl -fsS -u admin:admin -H 'X-Requested-By: glog-test' -H 'Content-Type: application/json' "$@"
}

send() {
  jq -nc --argjson timestamp "$1" --arg host "$2" --argjson level "$3" --arg message "$4" --argjson extra "${5:-null}" \
    '{version: "1.1", host: $host, short_message: $message, timestamp: $timestamp, level: $level} + ($extra // {})' |
    curl -fsS -X POST --data-binary @- "$gelf"
}

start_graylog() {
  echo "Starting Graylog $version..."
  "${compose[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
  if ! $keep; then
    trap '"${compose[@]}" down -v >/dev/null 2>&1' EXIT
  fi
  if ! "${compose[@]}" up -d --wait --wait-timeout 600; then
    "${compose[@]}" logs --tail 100 graylog >&2
    exit 1
  fi

  GLOG_TOKEN=$(admin -X POST "$api/users/local:admin/tokens/glog-test" -d '{}' | jq -r .token)
  admin -X POST "$api/system/inputs" -d '{
    "title": "GELF HTTP", "type": "org.graylog2.inputs.gelf.http.GELFHttpInput", "global": true,
    "configuration": {"bind_address": "0.0.0.0", "port": 12201}}' >/dev/null
  wait_for "the GELF input to start" input_running
}

seed() {
  local now long
  now=$(date +%s)
  long=$(printf 'a%.0s' {1..400})
  send $((day)) web-a 3 "upstream timed out" '{"_response_ms": 10.5}'
  send $((day + 600)) web-a 3 "upstream timed out" '{"_response_ms": 20.25}'
  send $((day + 1200)) web-b 6 "request served" '{"_response_ms": 33.333}'
  send $((day + 3900)) web-b 6 'client said "hi", then left'
  send $((day + 4500)) web-a 4 $'\e[31mdisk\e[0m almost full\nretrying'
  send $((day + 5100)) db 6 "$long"
  send $((now - 120)) recent 5 "recent one"
  send $((now - 60)) recent 5 "recent two"
  wait_for "8 messages to be searchable" all_messages_searchable
}

input_running() {
  [[ $(admin "$api/system/inputstates" | jq -r '.states[0].state') == RUNNING ]]
}

all_messages_searchable() {
  [[ $(admin -X POST "$api/search/messages" -d '{"query": "*", "timerange": {"type": "relative", "range": 0}}' |
    jq '.datarows | length') == 8 ]]
}

wait_for() {
  local what=$1 condition=$2 tries=0
  until "$condition" 2>/dev/null; do
    tries=$((tries + 1))
    [[ $tries -lt 60 ]] || { echo "Gave up waiting for $what" >&2; exit 1; }
    sleep 1
  done
}

glog() {
  "$shell" "$repo/glog" "$@"
}

failures=0

# Runs a command and compares what it prints, stderr included, with stdin. A
# nonzero exit adds an "exit N" line.
check() {
  local name=$1 expected actual status=0
  shift
  expected=$(cat)
  actual=$("$@" 2>&1) || status=$?
  if [[ $status -ne 0 ]]; then
    actual+=$'\n'"exit $status"
  fi
  if [[ $actual == "$expected" ]]; then
    echo "  ok    $name"
  else
    echo "  FAIL  $name"
    diff <(echo "$expected") <(echo "$actual") | sed 's/^/        /' || true
    failures=$((failures + 1))
  fi
}

# Like check, but each line of stdin is a regex that some line of output must match.
check_lines() {
  local name=$1 actual pattern missing=""
  shift
  actual=$("$@" 2>&1) || actual+=$'\n'"exit $?"
  while IFS= read -r pattern; do
    grep -Eq -- "$pattern" <<<"$actual" || missing+="        no line matches: $pattern"$'\n'
  done
  if [[ -z $missing ]]; then
    echo "  ok    $name"
  else
    echo "  FAIL  $name"
    printf '%s' "$missing"
    echo "        > ${actual//$'\n'/$'\n'        > }"
    failures=$((failures + 1))
  fi
}

run_checks() {
  local long
  long=$(printf 'a%.0s' {1..300})
  echo "Checking with $shell: $("$shell" --version | head -1)"

  check "search: default range, newest first" glog search -f source,level,message <<'EOF'
"source","level","message"
"recent",5,"recent two"
"recent",5,"recent one"
EOF

  check "search: absolute range" glog search --from 2026-01-15T12:00:00Z --to 2026-01-15T14:00:00Z -f timestamp,source,level,message -w 40 <<'EOF'
"timestamp","source","level","message"
"2026-01-15T13:25:00.000Z","db",6,"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa…"
"2026-01-15T13:15:00.000Z","web-a",4,"disk almost full\nretrying"
"2026-01-15T13:05:00.000Z","web-b",6,"client said ""hi"", then left"
"2026-01-15T12:20:00.000Z","web-b",6,"request served"
"2026-01-15T12:10:00.000Z","web-a",3,"upstream timed out"
"2026-01-15T12:00:00.000Z","web-a",3,"upstream timed out"
EOF

  check "search: narrow absolute range" glog search --from 2026-01-15T12:05:00Z --to 2026-01-15T12:15:00Z -f timestamp,message <<'EOF'
"timestamp","message"
"2026-01-15T12:10:00.000Z","upstream timed out"
EOF

  check "search: query, --asc, -n, --offset" glog search 'source:web-a' --from 2026-01-15T00:00:00Z --asc -n 2 --offset 1 -f timestamp <<'EOF'
"timestamp"
"2026-01-15T12:10:00.000Z"
"2026-01-15T13:15:00.000Z"
EOF

  check "search: default width" glog search source:db --from 2026-01-15T00:00:00Z -f message <<EOF
"message"
"${long}…"
EOF

  check "search: keyword range in UTC" env TZ=UTC "$shell" "$repo/glog" search -r "2026-01-15 11:55:00 to 2026-01-15 12:25:00" -f timestamp <<'EOF'
"timestamp"
"2026-01-15T12:20:00.000Z"
"2026-01-15T12:10:00.000Z"
"2026-01-15T12:00:00.000Z"
EOF

  check "search: keyword range in Tokyo time" env TZ=Asia/Tokyo "$shell" "$repo/glog" search -r "2026-01-15 20:55:00 to 2026-01-15 21:25:00" -f timestamp <<'EOF'
"timestamp"
"2026-01-15T12:20:00.000Z"
"2026-01-15T12:10:00.000Z"
"2026-01-15T12:00:00.000Z"
EOF

  check "search: stream by title" glog search -s "default stream" -f source,message <<'EOF'
"source","message"
"recent","recent two"
"recent","recent one"
EOF

  check "search: stream by ID" glog search -s 000000000000000000000001 -n 1 -f message <<'EOF'
"message"
"recent two"
EOF

  check_lines "search: unknown stream" glog search -s nope <<'EOF'
^glog: no stream called "nope"; there are: .*Default Stream
^exit 1$
EOF

  check_lines "search: query syntax error" glog search 'source:(' <<'EOF'
^glog: POST /search/messages returned HTTP 400
^exit 1$
EOF

  check "count: grouped by source by default" glog count --from 2026-01-15T00:00:00Z --to 2026-01-16T00:00:00Z <<'EOF'
"source","count()"
"web-a",3
"web-b",2
"db",1
EOF

  check "count: two groups" glog count 'level:<=4' -g source -g level:2 --from 2026-01-15T00:00:00Z <<'EOF'
"source","level","count()"
"web-a","3",2
"web-a","4",1
EOF

  check "count: --every" glog count --every 1h --from 2026-01-15T00:00:00Z --to 2026-01-16T00:00:00Z -m count <<'EOF'
"timestamp","count()"
"2026-01-15T12:00:00.000Z",3
"2026-01-15T13:00:00.000Z",3
EOF

  check "count: metrics round to two places" glog count _exists_:response_ms -g level --from 2026-01-15T00:00:00Z \
    -m count -m avg:response_ms -m max:response_ms -m card:source <<'EOF'
"level","count()","avg(response_ms)","max(response_ms)","card(source)"
"3",2,15.38,20.25,1
"6",1,33.33,33.33,1
EOF

  check_lines "count: percentile" glog count _exists_:response_ms -g source --from 2026-01-15T00:00:00Z -m percentile:response_ms:50 <<'EOF'
^"source","percentile\(response_ms\)"$
^"web-a",1[0-9.]+$
^"web-b",33.33$
EOF

  check_lines "count: --json" glog count --from 2026-01-15T00:00:00Z --json <<'EOF'
"schema"
"datarows"
EOF

  check_lines "fields" glog fields --from 2026-01-15T00:00:00Z <<'EOF'
^"field","type"$
^"message","string"$
^"source","string"$
^"timestamp","date"$
EOF

  check_lines "streams" glog streams <<'EOF'
^"id","title","disabled"$
^"000000000000000000000001","Default Stream",false$
EOF

  check_lines "status" glog status <<EOF
^version +${version//./\\.}(\+|$)
^lifecycle +running$
^indexer +green,
^input +RUNNING GELF HTTP \(GELFHttpInput\)$
EOF

  check_lines "api" glog api GET /system <<EOF
"version": *"${version//./\\.}
EOF

  check "bad token" env GLOG_TOKEN=wrong "$shell" "$repo/glog" streams <<EOF
glog: Graylog rejected the token; replace GLOG_TOKEN in $GLOG_CONFIG
exit 1
EOF
}

command -v shellcheck >/dev/null || { echo "test/run.sh needs shellcheck; install it with: brew install shellcheck" >&2; exit 1; }
shellcheck "$repo/glog" "$repo/test/run.sh" "$repo/test/bash32"

start_graylog
seed
export GLOG_URL=${api%/api} GLOG_TOKEN GLOG_CONFIG=/dev/null
for shell in "${shells[@]}"; do
  run_checks
done

if [[ $failures -gt 0 ]]; then
  echo "$failures checks failed"
  exit 1
fi
echo "All checks passed"
