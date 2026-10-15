{ pkgs, ... }:
{
  imports = [ ./fish.nix ];

  # Remove once nixpkgs includes 8d8ca25 (mimalloc is only supported by Lix >= 2.96).
  nixpkgs.overlays = [
    (_final: prev: {
      lixPackageSets = prev.lixPackageSets // {
        stable = prev.lixPackageSets.stable.overrideScope (
          _lixFinal: lixPrev: {
            lix = lixPrev.lix.overrideAttrs (old: {
              mesonFlags = builtins.filter (flag: !(prev.lib.hasPrefix "-Dmimalloc=" flag)) old.mesonFlags;
            });
          }
        );
      };
    })
  ];

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
  time.timeZone = "Asia/Tokyo";

  users.users.jinji = {
    isNormalUser = true;
    shell = pkgs.fish;
    extraGroups = [ "wheel" ];
    # Same public key as the existing ROCK 3B configuration.
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILEPtrVcxLNcVNkdjM80No+IjJ9Viijp8O13mopAwaEX jinji@inspiron-5425"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINlm/LW+R2mEGbAFhhdbd3vcAYxgZ/bzswlTTiKb4bmR termux@pixel8a"
    ];
  };
  # Set jinji's local password during installation; sudo requires it.
  security.sudo.wheelNeedsPassword = true;

  environment.systemPackages = with pkgs; [
    nh
    git
    gh
    vim
    micro
    tree
    btop
    nvme-cli
  ];
}
