# nixos-agent-test-vm

Give your AI coding agent eyes and hands on a NixOS desktop. You don't want it running `nixos-rebuild switch` on the host for security reasons, so without a sandbox it can only build configs and hope they work. This flake hands it a VM of your real host configuration to validate against, closing the feedback loop: boot the change, look at the screen, find what broke, fix it, try again.

## Using it with an AI coding agent

Two ways:

1. **Install the skill.** From your project root, run `nix run github:lorenzbischof/nixos-agent-test-vm` and commit the result. To refresh later (after `nix flake update`), just ask your agent to update the skill.

2. **Point the agent at this README.** The agent will install the skill and handle everything for you.

Either way, the agent ends up calling `nix run .#<host>-agent-vm` and talking to the socket. See SKILL.md for the protocol.

## Manual setup

If you'd rather wire it up by hand, read [`skills/nixos-agent-test-vm/SETUP.md`](skills/nixos-agent-test-vm/SETUP.md). It's a short flake-input + one `mkAgentVm { ... }` call.

## How it works

`mkAgentVm` wraps `pkgs.testers.runNixOSTest`, importing your `nixosConfiguration`'s modules so the VM boots the real system. The test script binds a Unix socket and runs each line of Python it receives against the test driver, replying with JSON:

```
$ echo 'machine.execute("hostname")' \
    | socat - UNIX-CONNECT:$XDG_RUNTIME_DIR/framework-agent-vm.sock
{"ok": true, "result": "(0, 'framework\\n')"}
```
