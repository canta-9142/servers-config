{ pkgs, ... }:
{
  imports = [ ./fish.nix ];

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
