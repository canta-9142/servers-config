{ lib, ... }:
{
  nixpkgs.config.allowUnfreePredicate = pkg: lib.getName pkg == "cloudflare-warp";
  services.cloudflare-warp.enable = true;
  # WARP uses policy routing; strict reverse-path filtering can reject replies.
  networking.firewall.checkReversePath = "loose";
  # Register once with `warp-cli connector new` on the host. Registration
  # persists in /var/lib/cloudflare-warp; no token belongs in the Nix store.
  # This host is a Mesh endpoint, not a LAN router: no IP forwarding needed.
}
