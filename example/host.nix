# A minimal stand-in for a real host configuration: a graphical session to
# drive, a terminal to launch, and one /etc file the apply loop can flip.
{ pkgs, ... }:
{
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
  boot.loader.grub.device = "nodev";

  networking.hostName = "example";

  users.users.agent = {
    isNormalUser = true;
    password = "agent";
    extraGroups = [ "wheel" ];
  };

  programs.sway.enable = true;

  services.greetd = {
    enable = true;
    settings.default_session = {
      command = "${pkgs.tuigreet}/bin/tuigreet --cmd sway";
      user = "greeter";
    };
  };

  # Sway's packaged default config binds a terminal that isn't installed here,
  # so ship a tiny config with the Mod4+t binding SKILL.md documents.
  environment.etc."sway/config".text = ''
    set $mod Mod4
    bindsym $mod+t exec ${pkgs.foot}/bin/foot
    output * bg #202020 solid_color
  '';

  environment.systemPackages = [
    pkgs.foot
    pkgs.wev
  ];

  # `apply` target: selftest.sh rewrites marker.txt and checks this file.
  environment.etc."agent-vm-marker".text = builtins.readFile ./marker.txt;

  system.stateVersion = "25.05";
}
