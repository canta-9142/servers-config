{
  config,
  lib,
  pkgs,
  ...
}:
let
  update = pkgs.writeShellApplication {
    name = "nix-cache-update";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      gitMinimal
      jq
      config.nix.package
    ];
    text = builtins.readFile ../../scripts/update-nix-cache.sh;
  };
in
{
  nix.package = pkgs.lixPackageSets.stable.lix;
  nix.settings = {
    extra-substituters = [
      "https://noctalia.cachix.org"
      "https://look.cachix.org"
    ];
    extra-trusted-public-keys = [
      "noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4="
      "look.cachix.org-1:8elPCeSVBzlDZXqIRKBK9GyLIK/Hoe1xiWZF0ir7uX4="
    ];
  };

  environment.systemPackages = [ update ];
  users.groups.nix-ci = { };
  users.users.nix-ci = {
    isSystemUser = true;
    group = "nix-ci";
    home = "/var/lib/gitea-runner-nix/nix";
  };

  services.gitea-actions-runner = {
    package = lib.mkDefault pkgs.forgejo-runner;
    instances.nix = {
      enable = true;
      name = "ryzen-nix-build";
      url = "http://127.0.0.1:3000";
      tokenFile = "/etc/forgejo-runner/nix.env";
      labels = [ "ryzen-nix-build:host" ];
      hostPackages = with pkgs; [
        bash
        coreutils
        gitMinimal
        nodejs_22
        config.nix.package
      ];
      settings = {
        runner = {
          capacity = 1;
          timeout = "8h";
        };
        cache.enabled = false;
      };
    };
  };

  systemd.services.gitea-runner-nix = {
    after = [ "forgejo.service" ];
    wants = [ "forgejo.service" ];
    environment = {
      HOME = lib.mkForce "/var/lib/gitea-runner-nix/nix";
      INSTANCE_DIR = lib.mkForce "/var/lib/gitea-runner-nix/nix";
      TOKEN_HASH_FILE = lib.mkForce "/var/lib/gitea-runner-nix/nix/.token-hash";
      LABELS_FILE = lib.mkForce "/var/lib/gitea-runner-nix/nix/.labels";
      NIX_REMOTE = "daemon";
    };
    unitConfig.ConditionPathExists = [
      "/srv/forgejo/.migration-ready"
      "/etc/forgejo-runner/nix.env"
      "/var/lib/nix-cache/signing-key"
    ];
    serviceConfig = {
      DynamicUser = lib.mkForce false;
      User = lib.mkForce "nix-ci";
      Group = "nix-ci";
      StateDirectory = lib.mkForce "gitea-runner-nix";
      StateDirectoryMode = "0700";
      WorkingDirectory = lib.mkForce "-/var/lib/gitea-runner-nix/nix";
      UMask = "0077";
    };
  };

  # Workflow authors can sign and publish store outputs, but cannot read the key.
  # nix-ci remains an untrusted Nix daemon user and is not a wheel member.
  security.sudo.extraRules = [
    {
      users = [ "nix-ci" ];
      commands = [
        {
          command = "/run/current-system/sw/bin/nix-cache-publish";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];
}
