{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
{
  options.services.forgejo-runner.instances = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          config.settings = {
            # The daemon must not also load .runner alongside native connections.
            runner.file = "/run/forgejo-runner/${name}/unused-registration";
            server.connections.default = {
              # Filled from .runner in the runtime configuration below.
              uuid = "";
              token = "";
            };
          };
          options.registration = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "Name used when registering this runner with Forgejo.";
            };
            tokenFile = lib.mkOption {
              type = lib.types.str;
              description = "Registration token file, raw or prefixed with TOKEN=.";
            };
          };
        }
      )
    );
  };

  config.systemd.services = lib.mapAttrs' (
    name: instance:
    let
      serviceName = "forgejo-runner-${utils.escapeSystemdPath name}";
      labels = instance.settings.runner.labels;
      # This template contains no secrets. ExecStartPre fills in the existing
      # registration at runtime, keeping credentials out of the Nix store.
      template = (pkgs.formats.json { }).generate "forgejo-runner-${name}.json" (
        lib.filterAttrsRecursive (n: _: n != "assertions" && n != "warnings") instance.settings
      );
    in
    lib.nameValuePair serviceName {
      path = [ pkgs.coreutils ];
      serviceConfig = {
        RuntimeDirectory = "forgejo-runner/${name}";
        RuntimeDirectoryMode = "0700";
        LoadCredential = [ "token:${instance.registration.tokenFile}" ];
        ExecStart = lib.mkForce "${lib.getExe config.services.forgejo-runner.package} daemon --config /run/forgejo-runner/${name}/config.json";
        ExecStartPre = [
          (pkgs.writeShellScript "forgejo-register-runner-${name}" ''
            set -eu
            umask 077
            # WorkingDirectory retains the old registration and workspaces.
            mkdir -p "$HOME"
            cd "$HOME"
            token=$(cat "$CREDENTIALS_DIRECTORY/token")
            if [[ $token == TOKEN=* ]]; then
              token=''${token#TOKEN=}
            fi
            token_hash=$(printf '%s' "$token" | sha256sum | cut -d' ' -f1)
            labels=${lib.escapeShellArg (lib.concatStringsSep "\n" (lib.sort builtins.lessThan labels))}

            if [[ ! -s .runner || $token_hash != "$(cat .token-hash 2>/dev/null || true)" || $labels != "$(cat .labels 2>/dev/null || true)" ]]; then
              rm -f .runner
              ${lib.getExe config.services.forgejo-runner.package} register --no-interactive \
                --instance ${lib.escapeShellArg instance.settings.server.connections.default.url} \
                --token "$token" \
                --name ${lib.escapeShellArg instance.registration.name} \
                --labels ${lib.escapeShellArg (lib.concatStringsSep "," labels)}
              printf '%s' "$token_hash" > .token-hash
              printf '%s\n' "$labels" > .labels
            fi

            ${lib.getExe pkgs.jq} --slurpfile registration .runner '
              .server.connections.default.uuid = $registration[0].uuid |
              .server.connections.default.token = $registration[0].token
            ' ${template} > "$RUNTIME_DIRECTORY/config.json"
          '')
        ];
      };
    }
  ) config.services.forgejo-runner.instances;
}
