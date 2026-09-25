{
  description = "Example host used to exercise the nixos-agent-test-vm harness itself.";

  # This flake exists only to give the harness something to boot without a
  # private host configuration. It is deliberately NOT part of the root flake:
  # the root stays input-free and lock-free so consumers pin their own nixpkgs.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-agent-test-vm.url = "path:..";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-agent-test-vm,
    }:
    let
      system = "x86_64-linux";

      # Exactly the wiring SETUP.md documents for a real host.
      agentVm = nixos-agent-test-vm.mkAgentVm {
        pkgs = nixpkgs.legacyPackages.${system};
        host = "example";
        nixosConfig = self.nixosConfigurations.example;

        extraConfig =
          { pkgs, ... }:
          {
            # Auto-login the graphical session so an agent can drive it.
            services.greetd.settings.initial_session = {
              command = "${pkgs.bash}/bin/bash -lc 'export WLR_RENDERER_ALLOW_SOFTWARE=1; exec ${pkgs.sway}/bin/sway'";
              user = "agent";
            };
          };
      };
    in
    {
      nixosConfigurations.example = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ ./host.nix ];
      };

      apps.${system} = {
        example-agent-vm = agentVm;
        default = agentVm;
      };
    };
}
