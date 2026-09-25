# nixos-agent-test-vm

Give your AI coding agent eyes and hands on a NixOS desktop. You don't want it running `nixos-rebuild switch` on the host for security reasons, so without a sandbox it can only build configs and hope they work. This flake hands it a VM of your real host configuration to validate against, closing the feedback loop: boot the change, look at the screen, find what broke, fix it, try again.

## Using it with an AI coding agent

Two ways:

1. **Install the skill.** From your project root, run `nix run github:lorenzbischof/nixos-agent-test-vm` and commit the result. To refresh later (after `nix flake update`), just ask your agent to update the skill.

2. **Point the agent at this README.** The agent will install the skill and handle everything for you.

Either way, the agent gets a VM scoped to its own session. `CODEX_THREAD_ID` is detected automatically; other agents can set a unique `AGENT_VM_SESSION`. Starting is idempotent within that session:

```bash
nix run .#<host>-agent-vm -- start
```

Most configuration changes can be built and activated in that same session VM without another QEMU boot:

```bash
nix run .#<host>-agent-vm -- apply
```

Independent session IDs get separate sockets and QEMU state, so agents can test concurrently. Each agent must stop its VM before finishing; stopping also removes that session's runtime state and GC root:

```bash
nix run .#<host>-agent-vm -- stop
```

See SKILL.md for the session lifecycle and socket protocol.

## Manual setup

If you'd rather wire it up by hand, read [`skills/nixos-agent-test-vm/SETUP.md`](skills/nixos-agent-test-vm/SETUP.md). It's a short flake-input + one `mkAgentVm { ... }` call.

## How it works

`mkAgentVm` wraps `pkgs.testers.runNixOSTest`, importing your `nixosConfiguration`'s modules so the VM boots the real system. The VM mounts the host Nix store, which lets `apply` activate a newly built test configuration in place. The test script binds a Unix socket and executes each connection's complete input as native NixOS test Python. Multiline programs, indentation, definitions, and a final result expression all work without another API layer:

```console
$ export AGENT_VM_SESSION=readme-example
$ socket="$(nix run .#<host>-agent-vm -- socket)"
$ socat -t 120 - UNIX-CONNECT:"$socket" <<'PY'
code, out = machine.execute("hostname")
assert code == 0, out
out
PY
{"ok": true, "result": "'<host>\\n'"}
```

## Testing the harness itself

`example/` is a self-contained flake with a minimal graphical host, so the harness can be exercised without a private configuration:

```bash
./example/selftest.sh
```

It boots the example host, checks the socket protocol, the graphical session (`Mod4+t`, `send_chars`, a screenshot) and the `apply` loop, then stops the VM. Use it after changing `agent-vm-driver.py`, `flake.nix` or the skill — it is the fastest way to find out whether a documented pattern still holds.
