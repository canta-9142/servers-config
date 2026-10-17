{
  lib,
  ...
}:

{
  networking = {
    networkmanager = {
      enable = true;

      # Do not create standalone DHCP profiles for the bond members.
      settings.main.no-auto-default = "*";

      ensureProfiles.profiles = {
        bond0 = {
          connection = {
            id = "bond0";
            type = "bond";
            interface-name = "bond0";
            autoconnect = true;
            autoconnect-ports = 1;
          };
          bond = {
            mode = "active-backup";
            primary = "end0";
            miimon = 100;
          };
          ipv4.method = "auto";
          ipv6.method = "auto";
        };

        bond0-end0.connection = {
          id = "bond0-end0";
          type = "ethernet";
          interface-name = "end0";
          controller = "bond0";
          port-type = "bond";
          autoconnect = true;
        };

        bond0-end1.connection = {
          id = "bond0-end1";
          type = "ethernet";
          interface-name = "end1";
          controller = "bond0";
          port-type = "bond";
          autoconnect = true;
        };
      };
    };
    useDHCP = lib.mkDefault true;

    firewall = {
      enable = true;
      allowedTCPPorts = [ ];
      allowedUDPPorts = [ ];
    };
  };
}
