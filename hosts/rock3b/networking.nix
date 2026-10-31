{
  lib,
  ...
}:

{
  networking = {
    networkmanager.enable = true;
    useDHCP = lib.mkDefault false;

    interfaces = {
      end0 = {
        useDHCP = false;
        ipv4.addresses = [
          { address = "192.168.1.100"; prefixLength = 16; }
        ];
      };
      end1.useDHCP = true;
    };

    firewall = {
      enable = true;
      allowedTCPPorts = [ 80 8080 ];
      allowedUDPPorts = [ ];
    };
  };
}
