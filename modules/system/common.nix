{ pkgs, ... }:
{
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
  time.timeZone = "Asia/Tokyo";

  users.users.jinji = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    # Same public key as the existing ROCK 3B configuration.
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILEPtrVcxLNcVNkdjM80No+IjJ9Viijp8O13mopAwaEX"
    ];
  };
  # Set jinji's local password during installation; sudo requires it.
  security.sudo.wheelNeedsPassword = true;

  environment.systemPackages = with pkgs; [
    git
    vim
    btop
    nvme-cli
  ];
}
