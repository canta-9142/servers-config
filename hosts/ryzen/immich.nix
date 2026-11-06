{ config, ... }:
let
  cfg = config.services.immich;
in
{
  services.immich = {
    enable = true;
    # Start independently of WARP assigning the Mesh address. The firewall
    # below restricts both the source and destination of incoming traffic.
    host = "0.0.0.0";
    port = 2283;
    openFirewall = false;
    mediaLocation = "/srv/immich";
  };

  # The upstream module only creates its default /var/lib/immich directory.
  systemd.tmpfiles.rules = [
    "d ${cfg.mediaLocation} 0700 ${cfg.user} ${cfg.group} -"
  ];

  networking.firewall.extraInputRules = ''
    iifname "enp39s0" ip saddr 192.168.11.0/24 ip daddr 192.168.11.201 tcp dport ${toString cfg.port} accept
    ip saddr 100.96.0.0/12 ip daddr 100.96.0.1 tcp dport ${toString cfg.port} accept
  '';
}
