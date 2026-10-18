{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
{
  # The Gitea module now uses --token-file, which Forgejo Runner does not support.
  # Keep existing .runner files and registration tokens until migrating to the
  # native Forgejo module's UUID/token connections.
  systemd.services = lib.mapAttrs' (
    name: instance:
    lib.nameValuePair "gitea-runner-${utils.escapeSystemdPath name}" {
      serviceConfig.ExecStartPre = lib.mkForce [
        (pkgs.writeShellScript "forgejo-register-runner-${name}" ''
          set -eu
          mkdir -p "$INSTANCE_DIR"
          cd "$INSTANCE_DIR"

          token=$(cat "$CREDENTIALS_DIRECTORY/token")
          if [[ $token == TOKEN=* ]]; then
            token=''${token#TOKEN=}
          fi
          token_hash=$(printf '%s' "$token" | sha256sum | cut -d' ' -f1)
          labels=${lib.escapeShellArg (lib.concatStringsSep "\n" (lib.sort builtins.lessThan instance.labels))}

          if [[ ! -s .runner || $token_hash != "$(cat "$TOKEN_HASH_FILE" 2>/dev/null || true)" || $labels != "$(cat "$LABELS_FILE" 2>/dev/null || true)" ]]; then
            rm -f .runner
            ${lib.getExe config.services.gitea-actions-runner.package} register --no-interactive \
              --instance ${lib.escapeShellArg instance.url} \
              --token "$token" \
              --name ${lib.escapeShellArg instance.name} \
              --labels ${lib.escapeShellArg (lib.concatStringsSep "," instance.labels)}
            printf '%s' "$token_hash" > "$TOKEN_HASH_FILE"
            printf '%s\n' "$labels" > "$LABELS_FILE"
          fi
        '')
      ];
    }
  ) config.services.gitea-actions-runner.instances;
}
