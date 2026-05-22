{
  description = "Agent-controllable NixOS test VM — boot a real NixOS host configuration under QEMU and drive it from the outside via a Unix-socket Python REPL.";

  outputs =
    { self }:
    {
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
                          virtualisation = {
                            memorySize = 4096;
                            cores = 4;
                            graphics = true;
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
                testScript = ''
                  SOCKET_NAME = "${name}.sock"
                '' + builtins.readFile ./agent-vm-driver.py;
              }
            ];
          };
        in
        {
          type = "app";
          program = "${vm.driver}/bin/nixos-test-driver";
        };
    };
}
