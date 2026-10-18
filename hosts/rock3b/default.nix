{ pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./rock3b.nix
    ./boot.nix
    ./networking.nix
    ../../modules/system/common.nix
    ../../modules/system/ssh.nix
    ../../modules/system/cloudflare-mesh.nix
  ];

  networking.hostName = "rock3b";

  programs.direnv.enable = true;

  # Preserve the existing ROCK's Nix implementation and nh environment handling.
  nix.package = pkgs.lixPackageSets.stable.lix;
  nixpkgs.overlays = [
    (_final: prev: {
      nh = prev.symlinkJoin {
        name = "nh-${prev.nh.version}";
        paths = [ prev.nh ];
        nativeBuildInputs = [ prev.makeWrapper ];
        postBuild = ''
          wrapProgram $out/bin/nh --set NH_PRESERVE_ENV 0
        '';
      };
      # Upstream phytool has an unused speed variable rejected by newer GCC.
      phytool = prev.phytool.overrideAttrs {
        env.NIX_CFLAGS_COMPILE = "-Wno-error=unused-but-set-variable";
      };
    })
  ];

  environment = {
    sessionVariables.NH_FLAKE = "/home/jinji/servers-config#rock3b";
    systemPackages = with pkgs; [
      jujutsu
      wget
      curl
      ripgrep
      yazi
      fastfetch
      fetch
      htop
      zellij
      dnsutils
    ];
  };

  users.users = {
    root.shell = pkgs.fish;
    jinji.description = "Kanta IMAI";
  };

  security.sudo.extraRules = [
    {
      users = [ "jinji" ];
      commands = [
        {
          command = "/run/current-system/sw/bin/nixos-rebuild";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

  systemd.tmpfiles.rules = [
    "L+ /etc/nixos - jinji users - /home/jinji/servers-config"
  ];

  system.stateVersion = "26.05";
}
