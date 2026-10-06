{ pkgs, ... }:
let
  cacheRoot = "/srv/nix-cache";
  secretKey = "/var/lib/nix-cache/signing-key";
  publish = pkgs.writeShellApplication {
    name = "nix-cache-publish";
    runtimeInputs = [
      pkgs.nix
      pkgs.util-linux
    ];
    text = ''
      if (( EUID != 0 )); then
        echo "Run as root; the signing key is root-only." >&2
        exit 1
      fi
      if (( $# == 0 )); then
        echo "Usage: nix-cache-publish /nix/store/<path> [...]" >&2
        exit 1
      fi
      for storePath in "$@"; do
        if [[ ! $storePath =~ ^/nix/store/[0123456789abcdfghijklmnpqrsvwxyz]{32}-[^/]+$ ]]; then
          echo "Expected an absolute Nix store path." >&2
          exit 1
        fi
      done
      # Validate without evaluating an installable or a flake as root.
      nix-store --check-validity "$@"
      if [[ ! -s ${secretKey} ]]; then
        echo "Missing ${secretKey}; follow docs/nix-binary-cache.md." >&2
        exit 1
      fi
      umask 022
      exec 9>/run/lock/nix-cache-publish.lock
      flock 9
      nix copy --to 'file://${cacheRoot}?secret-key=${secretKey}&compression=zstd' "$@"
    '';
  };
in
{
  environment.systemPackages = [ publish ];
  systemd.tmpfiles.rules = [
    "d ${cacheRoot} 0755 root root -"
    "d /var/lib/nix-cache 0700 root root -"
  ];

  services.nginx = {
    enable = true;
    virtualHosts."cache.floating-gate.com" = {
      listen = [
        {
          addr = "127.0.0.1";
          port = 8081;
        }
      ];
      root = cacheRoot;
      extraConfig = ''
        autoindex off;
        # Negative responses must not outlive a later successful publication.
        add_header Cache-Control "no-store" always;
      '';
      locations."/".extraConfig = ''
        limit_except GET { deny all; }
        try_files $uri =404;
      '';
    };
  };
  services.cloudflared.tunnels."aa088497-b776-4cb2-989e-935dc02ed6b3".ingress."cache.floating-gate.com" =
    "http://127.0.0.1:8081";
}
