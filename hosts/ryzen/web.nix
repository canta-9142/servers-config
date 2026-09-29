_:
let
  siteRoot = "/srv/www/floating-gate";
in
{
  users.groups.site-deploy = { };
  users.users.site-deploy = {
    isSystemUser = true;
    group = "site-deploy";
    home = siteRoot;
    createHome = false;
  };

  systemd.tmpfiles.rules = [
    "d ${siteRoot} 2775 site-deploy site-deploy -"
    "d ${siteRoot}/releases 2775 site-deploy site-deploy -"
    "d ${siteRoot}/.staging 2770 site-deploy site-deploy -"
  ];

  services.nginx = {
    enable = true;
    recommendedOptimisation = true;
    virtualHosts."floating-gate.com" = {
      listen = [
        {
          addr = "127.0.0.1";
          port = 8080;
        }
      ];
      root = "${siteRoot}/current";
      locations."= /healthz".extraConfig = ''
        default_type text/plain;
        if (!-f $document_root/index.html) { return 503; }
        return 200 "ok\n";
      '';
    };
  };

  # DNS stays on ROCK until the first Ryzen release has passed acceptance.
  services.cloudflared.tunnels."aa088497-b776-4cb2-989e-935dc02ed6b3".ingress."floating-gate.com" =
    "http://127.0.0.1:8080";
}
