{ lib, ... }:
{
  imports = [ ../../modules/system/forgejo-runner-registration.nix ];

  virtualisation.podman.enable = true;

  # Job networks use an aardvark DNS listener on their Podman bridge.
  networking.firewall.extraInputRules = ''
    iifname "podman*" udp dport 53 accept
    iifname "podman*" tcp dport 53 accept
  '';

  services.forgejo-runner = {
    instances.web = {
      enable = true;
      registration = {
        name = "ryzen-web-build";
        tokenFile = "/etc/forgejo-runner/web.env";
      };
      # Podman 5.8.7 rejects archive paths through Debian's /var/run -> /run.
      # https://github.com/podman-container-tools/podman/issues/29805
      settings = {
        server.connections.default.url = "http://127.0.0.1:3000";
        runner = {
          labels = [ "ryzen-web-build:docker://docker.io/library/node:22-alpine" ];
          capacity = 1;
          timeout = "30m";
        };
        container = {
          privileged = false;
          # WARP's loopback DNS is host-only; jobs only need public DNS.
          options = "--memory=4g --cpus=2 --dns=1.1.1.1 --dns=1.0.0.1";
          # Only the production workflow requests this mount. Workflow authors
          # in this trusted repository consequently have production write access.
          valid_volumes = [ "/srv/www/floating-gate" ];
          # Use the host runtime without exposing its socket to jobs.
          docker_host = "-";
        };
        cache.enabled = false;
      };
    };
  };

  systemd.services.forgejo-runner-web = {
    environment = {
      HOME = lib.mkForce "/var/lib/gitea-runner/web";
      DOCKER_HOST = "unix:///run/podman/podman.sock";
    };
    serviceConfig = {
      User = "gitea-runner";
      StateDirectory = lib.mkForce [
        "gitea-runner"
        "gitea-runner/web"
      ];
      WorkingDirectory = lib.mkForce "/var/lib/gitea-runner/web";
    };
    after = [ "forgejo.service" ];
    wants = [ "forgejo.service" ];
    unitConfig.ConditionPathExists = [
      "/srv/forgejo/.migration-ready"
      "/etc/forgejo-runner/web.env"
    ];
  };
}
