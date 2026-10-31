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
      phytool = prev.phytool.overrideAttrs {
        env.NIX_CFLAGS_COMPILE = "-Wno-error=unused-but-set-variable";
      };
    })
  ];

  environment = {
    sessionVariables.NH_FLAKE = "/home/jinji/servers-config#rock3b";
    systemPackages = with pkgs; [
      wget
      curl
      ripgrep
      yazi
      fastfetch
      fetch
      htop
      zellij
      dnsutils
      
      arduino-cli
      go_latest
      gopls
      gotools
      golangci-lint
    ];
  };

  users.users.rock = {
    isNormalUser = true;
    description = "ROCK 3B";
    shell = pkgs.fish;
    extraGroups = [ "dialout" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILEPtrVcxLNcVNkdjM80No+IjJ9Viijp8O13mopAwaEX jinji@inspiron-5425"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHgigNufhOIZQFFLRY66ZgGIT4OEiKzSk7bIK9PY/zUF atsu@wsl"
    ];
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
