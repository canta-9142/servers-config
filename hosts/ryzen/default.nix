{ lib, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./storage.nix
    ../../modules/system/common.nix
    ../../modules/system/ssh.nix
    ../../modules/system/cloudflare-mesh.nix
    ../../modules/system/maintenance.nix
    ../../modules/system/nix-builder.nix
  ];

  networking = {
    hostName = "ryzen";
    # The router reserves the address using the physical Ethernet MAC.
    useDHCP = lib.mkDefault true;
    firewall.enable = true;
  };

  boot.blacklistedKernelModules = [ "nouveau" ];

  environment.sessionVariables.NH_FLAKE = "/home/jinji/servers-config#ryzen";

  system.stateVersion = "26.05";
}
