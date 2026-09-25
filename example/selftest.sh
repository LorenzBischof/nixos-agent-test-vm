#!/usr/bin/env bash
# Exercises the harness against example/ so the driver, the lifecycle app and
# the patterns SKILL.md documents can be checked without a private host config.
set -euo pipefail
cd "$(dirname "$0")"

export AGENT_VM_SESSION="${AGENT_VM_SESSION:-example-selftest}"
app=".#example-agent-vm"
fails=0

# check <label> <regex>; the Python program comes in on stdin. The regex is
# matched against the result on success, or "ERROR: <traceback>" on failure.
check() {
  local label="$1" want="$2" response got
  response="$(socat -t 300 - UNIX-CONNECT:"$socket")"
  got="$(jq -r 'if .ok then .result else "ERROR: " + .error end' <<<"$response" | tr '\n' ' ')"
  if [[ "$got" =~ $want ]]; then
    echo "ok   $label"
  else
    echo "FAIL $label: $got"
    fails=$((fails + 1))
  fi
}

cleanup() {
  printf 'v1\n' >marker.txt
  nix run "$app" -- stop || true
}
trap cleanup EXIT

nix run "$app" -- start
socket="$(nix run "$app" -- socket)"

check "boots to default.target" '^null' <<'PY'
machine.wait_for_unit("default.target")
PY

check "sh() runs guest commands, merges stderr, returns a status" "example.*oops.*1" <<'PY'
code, host = sh("hostname")
assert code == 0, host
_, err = sh("echo oops >&2")
bad, _ = sh("false")
(host.strip(), err.strip(), bad)
PY

check "multiline program, final expression is the result" '^42' <<'PY'
def double(n):
    return n * 2


values = [double(n) for n in range(4)]
sum(values) + 30
PY

check "namespace persists across connections" '^42' <<'PY'
sum(values) + 30
PY

check "syntax errors are reported, not executed" 'ERROR:.*SyntaxError' <<'PY'
sh("touch /tmp/never-ran")
def broken(:
PY

check "nothing in a rejected program ran" '^1' <<'PY'
code, _ = sh("test -e /tmp/never-ran")
code
PY

check "the VM survives a failed program" '^True' <<'PY'
machine.process is not None and machine.process.poll() is None
PY

check "auto-login reaches a Sway session" 'sway' <<'PY'
machine.wait_for_unit("graphical.target")
machine.wait_until_succeeds("pgrep -x sway", timeout=120)
code, out = sh("pgrep -a -x sway")
assert code == 0, out
out
PY

check "Mod4+t opens a terminal and send_chars types into it" 'typed-by-agent' <<'PY'
# Sway silently drops keys sent before its IPC socket exists, and even then the
# first one can land too early — so resend until the terminal appears.
machine.wait_until_succeeds("ls /run/user/1000/sway-ipc.*.sock", timeout=120)
for _ in range(5):
    machine.send_key("meta_l-t")
    code, _ = sh("sleep 2; pgrep -x foot")
    if code == 0:
        break
assert code == 0, "Mod4+t never opened a terminal"
machine.send_chars("touch /tmp/typed-by-agent\n")
machine.wait_for_file("/tmp/typed-by-agent", timeout=60)
code, out = sh("ls /tmp/typed-by-agent")
assert code == 0, out
out
PY

check "screenshots capture the session" 'selftest.png' <<'PY'
machine.screenshot("selftest.png")
"selftest.png"
PY

shot="$(dirname "$socket")/out/selftest.png"
[[ -s "$shot" ]] && echo "ok   screenshot written to $shot" || {
  echo "FAIL no screenshot at $shot"
  fails=$((fails + 1))
}

printf 'v2\n' >marker.txt
nix run "$app" -- apply >/dev/null
check "apply switches the running guest without a reboot" 'v2' <<'PY'
code, out = sh("cat /etc/agent-vm-marker")
assert code == 0, out
out
PY

((fails == 0)) && echo "all checks passed" || {
  echo "$fails check(s) failed"
  exit 1
}
