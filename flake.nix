{
  description = "Agent-controllable NixOS test VM — boot a real NixOS host configuration under QEMU and drive it from the outside with native NixOS test Python.";

  outputs =
    { self }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems =
        f:
        builtins.listToAttrs (
          map (system: {
            name = system;
            value = f system;
          }) systems
        );
    in
    {
      apps = forAllSystems (
        system:
        let
          install = {
            type = "app";
            program = "${self}/install.sh";
          };
        in
        {
          default = install;
          inherit install;
        }
      );

      mkAgentVm =
        {
          pkgs,
          nixosConfig,
          host,
          extraConfig ? { },
        }:
        let
          name = "${host}-agent-vm";
          vm = pkgs.testers.runNixOSTest {
            inherit name;
            node.pkgs = pkgs;
            node.pkgsReadOnly = false;
            node.specialArgs = nixosConfig._module.specialArgs;
            imports = [
              {
                nodes.vm =
                  { lib, pkgs, ... }:
                  {
                    imports = nixosConfig._module.args.modules ++ [
                      (
                        { lib, ... }:
                        {
                          # Predictable keyboard input for send_chars().
                          console.keyMap = lib.mkForce "us";
                          # Keep the VM switchable so agents can apply a newly
                          # built test configuration without rebooting QEMU.
                          system.switch.enable = lib.mkForce true;
                          virtualisation = {
                            memorySize = 4096;
                            cores = 4;
                            graphics = true;
                            mountHostNixStore = lib.mkForce true;
                            useNixStoreImage = lib.mkForce false;
                            qemu.package = lib.mkForce pkgs.qemu;
                            qemu.options = [
                              "-vga none"
                              "-device virtio-gpu-pci"
                              "-display gtk,gl=off"
                            ];
                          };
                        }
                      )
                      extraConfig
                    ];
                  };
                # The test framework's default of one hour kills the VM
                # mid-session, indistinguishable from a crash. Backstop only.
                globalTimeout = 7 * 24 * 60 * 60;
                testScript = ''
                  SOCKET_NAME = "${name}.sock"
                ''
                + builtins.readFile ./agent-vm-driver.py;
              }
            ];
          };
          toplevel = vm.nodes.vm.system.build.toplevel;
          applyScript = pkgs.writeText "${name}-apply.py" ''
            code, out = machine.execute(
                ${builtins.toJSON "NIXOS_NO_SYNC=1 ${toplevel}/bin/switch-to-configuration test"}
            )
            assert code == 0, out
          '';
          runner = pkgs.writeShellApplication {
            inherit name;
            runtimeInputs = [
              pkgs.coreutils
              pkgs.jq
              pkgs.nix
              pkgs.socat
            ]
            ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.util-linux ];
            text = ''
              base_runtime_dir="''${XDG_RUNTIME_DIR:-/tmp}"
              session="''${AGENT_VM_SESSION:-''${CODEX_THREAD_ID:-''${CLAUDE_CODE_SESSION_ID:-''${CLAUDE_SESSION_ID:-}}}}"

              if [[ "''${1:-}" == "--session" ]]; then
                if (($# < 2)); then
                  echo "error: --session requires an ID" >&2
                  exit 2
                fi
                session="$2"
                shift 2
              fi

              if [[ -z "$session" ]]; then
                echo "error: set AGENT_VM_SESSION or pass --session ID" >&2
                exit 2
              fi

              session_digest="$(printf '%s' "$session" | sha256sum)"
              session_key="''${session_digest%% *}"
              session_key="''${session_key:0:12}"
              session_dir="$base_runtime_dir/${name}-$session_key"
              socket="$session_dir/${name}.sock"
              log="$session_dir/driver.log"
              pid_file="$session_dir/driver.pid"
              system_root="$session_dir/system"
              # Screenshots and copy_from_vm default to the driver's working
              # directory — the flake root. Keep them in the session instead.
              out_dir="$session_dir/out"

              probe_vm() {
                local response
                response="$(
                  printf '%s\n' 'machine.process is not None and machine.process.poll() is None' \
                    | socat -t 5 - UNIX-CONNECT:"$socket" 2>/dev/null
                )" || return 1
                jq -e '.ok == true and .result == "True"' <<<"$response" >/dev/null
              }

              live_pid() {
                local pid
                [[ -s "$pid_file" ]] || return 1
                pid="$(<"$pid_file")"
                [[ "$pid" =~ ^[0-9]+$ ]] || return 1
                kill -0 "$pid" 2>/dev/null
              }

              wait_for_vm() {
                local deadline
                deadline=$((SECONDS + ''${AGENT_VM_START_TIMEOUT:-300}))
                while ((SECONDS < deadline)); do
                  if probe_vm; then
                    return 0
                  fi
                  if [[ -s "$pid_file" ]] && ! live_pid; then
                    break
                  fi
                  sleep 1
                done

                echo "error: ${name} did not become ready; last log lines:" >&2
                tail -n 80 "$log" >&2 2>/dev/null || true
                return 1
              }

              root_system() {
                rm -f "$system_root"
                nix-store --add-root "$system_root" --indirect --realise ${toplevel} >/dev/null
              }

              cleanup_session() {
                if [[ "$session_dir" != "$base_runtime_dir/${name}-$session_key" ]]; then
                  echo "error: refusing to clean unexpected session path: $session_dir" >&2
                  return 1
                fi
                rm -rf -- "$session_dir"
              }

              command="''${1:-run}"
              if (($# > 0)); then
                shift
              fi

              case "$command" in
                start)
                  if probe_vm; then
                    echo "reusing ${name} for session $session_key"
                    exit 0
                  fi

                  if live_pid; then
                    echo "waiting for ${name} session $session_key to finish starting"
                    wait_for_vm
                    echo "started ${name} for session $session_key; socket: $socket"
                    exit 0
                  fi

                  mkdir -p "$session_dir"
                  chmod 700 "$session_dir"
                  rm -f "$socket" "$pid_file"
                  : >"$log"
                  if command -v setsid >/dev/null; then
                    setsid --fork "$0" --session "$session" run >>"$log" 2>&1 </dev/null
                  else
                    nohup "$0" --session "$session" run >>"$log" 2>&1 </dev/null &
                  fi
                  wait_for_vm
                  root_system
                  echo "started ${name} for session $session_key; socket: $socket; log: $log; out: $out_dir"
                  ;;

                apply)
                  if ! probe_vm; then
                    echo "error: ${name} is not running for session $session_key; start it first" >&2
                    exit 1
                  fi

                  if ! response="$(
                    socat -t "''${AGENT_VM_APPLY_TIMEOUT:-600}" - UNIX-CONNECT:"$socket" \
                      < ${applyScript}
                  )"; then
                    echo "error: lost the connection while applying ${name}" >&2
                    exit 1
                  fi

                  jq . <<<"$response"
                  jq -e '.ok == true' <<<"$response" >/dev/null
                  root_system
                  echo "applied ${toplevel} to ${name} session $session_key"
                  ;;

                status)
                  if probe_vm; then
                    echo "running session $session_key: $socket"
                  else
                    echo "stopped session $session_key: $socket"
                    exit 1
                  fi
                  ;;

                socket)
                  echo "$socket"
                  ;;

                stop)
                  if ! probe_vm; then
                    if live_pid; then
                      echo "error: ${name} session $session_key is running but its control socket is unavailable" >&2
                      exit 1
                    fi
                    cleanup_session
                    echo "already stopped: ${name} session $session_key"
                    exit 0
                  fi

                  printf '%s\n' 'raise SystemExit' \
                    | socat -t 5 - UNIX-CONNECT:"$socket" >/dev/null 2>&1 || true
                  for _ in {1..50}; do
                    if ! probe_vm && ! live_pid; then
                      cleanup_session
                      echo "stopped ${name} session $session_key"
                      exit 0
                    fi
                    sleep 0.1
                  done
                  echo "error: ${name} session $session_key did not stop" >&2
                  exit 1
                  ;;

                run)
                  mkdir -p "$session_dir" "$out_dir"
                  chmod 700 "$session_dir"
                  printf '%s\n' "$$" >"$pid_file"
                  export XDG_RUNTIME_DIR="$session_dir"
                  set +e
                  ${vm.driver}/bin/nixos-test-driver --output_directory "$out_dir" "$@"
                  status=$?
                  rm -f "$pid_file"
                  exit "$status"
                  ;;

                *)
                  echo "usage: $0 [--session ID] [start|apply|status|socket|stop|run]" >&2
                  exit 2
                  ;;
              esac
            '';
          };
        in
        {
          type = "app";
          program = "${runner}/bin/${name}";
        };
    };
}
