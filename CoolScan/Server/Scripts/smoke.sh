#!/bin/sh
# End-to-end check of the server API without photogrammetry: starts the
# server in stub mode, walks a job through create → upload → start → poll →
# download, verifies the result bundle, and shuts the server down.
#
#   Scripts/smoke.sh            # builds and runs with the ball.usdz fixture

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
package_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
port=${PORT:-8799}
work=$(mktemp -d "${TMPDIR:-/tmp}/coolscan-smoke.XXXXXX")
trap 'kill "$server_pid" 2>/dev/null || true; rm -rf "$work"' EXIT

cd "$package_root"
swift build --product CoolScanServer >/dev/null
bin="$(swift build --show-bin-path)/CoolScanServer"

"$bin" --port "$port" --jobs-dir "$work/jobs" \
    --stub-usdz "$package_root/Tests/CoolScanServerCoreTests/Resources/ball.usdz" \
    > "$work/server.log" 2>&1 &
server_pid=$!

for _ in 1 2 3 4 5 6 7 8 9 10; do
    curl -sf "http://localhost:$port/health" >/dev/null 2>&1 && break
    sleep 0.5
done
echo "health: $(curl -s "http://localhost:$port/health")"

printf 'not really a photo' > "$work/img1.heic"
printf 'nor this one' > "$work/img2.heic"
printf 'poses' > "$work/poses.bin"

job=$(curl -sf -X POST "http://localhost:$port/jobs" -H 'Content-Type: application/json' \
    -d '{"name":"smoke","files":["Images/img1.heic","Images/img2.heic","Checkpoints/poses.bin"]}')
id=$(printf '%s' "$job" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
echo "job: $id"

for f in "Images/img1.heic:$work/img1.heic" "Images/img2.heic:$work/img2.heic" "Checkpoints/poses.bin:$work/poses.bin"; do
    path=${f%%:*}; file=${f#*:}
    curl -sf -X PUT "http://localhost:$port/jobs/$id/files" -H "X-File-Path: $path" --data-binary @"$file" >/dev/null
    echo "uploaded $path"
done

curl -sf -X POST "http://localhost:$port/jobs/$id/start" >/dev/null
for _ in $(seq 1 60); do
    status=$(curl -s "http://localhost:$port/jobs/$id")
    state=$(printf '%s' "$status" | sed -n 's/.*"state":"\([^"]*\)".*/\1/p')
    echo "state: $state"
    case "$state" in done|failed|cancelled) break ;; esac
    sleep 0.5
done
[ "$state" = "done" ] || { echo "FAILED: $status"; cat "$work/server.log"; exit 1; }

curl -sf -o "$work/result.zip" "http://localhost:$port/jobs/$id/result"
unzip -l "$work/result.zip"
unzip -tq "$work/result.zip"

code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "http://localhost:$port/jobs/$id")
[ "$code" = "204" ] || { echo "DELETE returned $code"; exit 1; }
code=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$port/jobs/$id")
[ "$code" = "404" ] || { echo "job still visible after delete ($code)"; exit 1; }

echo "--- server log"
cat "$work/server.log"
echo "SMOKE OK"
