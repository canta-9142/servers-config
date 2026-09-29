{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.forgejo;
  readyFile = "${cfg.stateDir}/.migration-ready";
  # Locally managed tunnel: ryzen-homelab.
  # Never reuse the ROCK tunnel: it also carries the existing website and SSH.
  tunnelId = "aa088497-b776-4cb2-989e-935dc02ed6b3";
in
{
  services.forgejo = {
    enable = true;
    # The module defaults to forgejo-lts (15); ROCK already runs 16.0.5.
    package = pkgs.forgejo;
    stateDir = "/srv/forgejo";
    database.type = "sqlite3";
    lfs.enable = true;

    settings = {
      server = {
        DOMAIN = "git.floating-gate.com";
        ROOT_URL = "https://git.floating-gate.com/";
        PROTOCOL = "http";
        HTTP_ADDR = "127.0.0.1";
        HTTP_PORT = 3000;
        APP_DATA_PATH = "${cfg.stateDir}/data";
        DISABLE_SSH = false;
        START_SSH_SERVER = true;
        BUILTIN_SSH_SERVER_USER = "git";
        SSH_DOMAIN = "ryzen.home.arpa";
        SSH_PORT = 2222;
        # Avoid depending on WARP assigning its address before Forgejo starts.
        # The firewall below limits access to the Mesh destination and sources.
        SSH_LISTEN_HOST = "0.0.0.0";
        SSH_LISTEN_PORT = 2222;
      };
      database.SQLITE_JOURNAL_MODE = "WAL";
      service = {
        DISABLE_REGISTRATION = true;
        SHOW_REGISTRATION_BUTTON = false;
      };
      actions.ENABLED = true;
      log.LEVEL = "Info";
    };

    dump = {
      enable = true;
      interval = "03:30";
      backupDir = "/var/backup/forgejo";
      type = "tar.zst";
      age = "30d";
    };
  };

  networking.firewall.extraInputRules = ''
    ip saddr 100.96.0.0/12 ip daddr 100.96.0.1 tcp dport 2222 accept
  '';

  # Gate the helper too: a condition on forgejo alone does not stop its
  # dependencies from generating replacement secrets during activation.
  systemd.services = {
    forgejo.unitConfig.ConditionPathExists = readyFile;
    forgejo-secrets = {
      unitConfig.ConditionPathExists = readyFile;
      preStart = ''
        # Refuse to initialize a fresh instance or replace missing migrated keys.
        for file in \
          data/forgejo.db \
          custom/conf/secret_key \
          custom/conf/internal_token \
          custom/conf/oauth2_jwt_secret \
          custom/conf/lfs_jwt_secret \
          data/ssh/gitea.rsa \
          data/jwt/private.pem \
          data/actions_id_token/private.pem; do
          if ! test -s "${cfg.stateDir}/$file"; then
            echo "Missing migrated Forgejo file: $file" >&2
            exit 1
          fi
        done
      '';
    };
    forgejo-dump.unitConfig.ConditionPathExists = readyFile;
  }
  // lib.optionalAttrs (tunnelId != null) {
    "cloudflared-tunnel-${tunnelId}".unitConfig.ConditionPathExists = [
      readyFile
      "/var/lib/cloudflared/${tunnelId}.json"
    ];
  };
  systemd.timers.forgejo-dump.unitConfig.ConditionPathExists = readyFile;

  services.cloudflared = lib.mkIf (tunnelId != null) {
    enable = true;
    tunnels.${tunnelId} = {
      credentialsFile = "/var/lib/cloudflared/${tunnelId}.json";
      ingress."git.floating-gate.com" = "http://127.0.0.1:3000";
      default = "http_status:404";
    };
  };
}
