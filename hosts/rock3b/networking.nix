{
  lib,
  ...
}:

{
  networking = {
    networkmanager.enable = true;
    useDHCP = lib.mkDefault false;

    interfaces = {
      end0.useDHCP = true;
      end1.useDHCP = true;
    };

    firewall = {
      enable = true;
      allowedTCPPorts = [ ];
      allowedUDPPorts = [ ];
    };
  };
}
