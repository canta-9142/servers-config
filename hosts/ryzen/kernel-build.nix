{ config, ... }:
{
  programs.ccache = {
    enable = true;
    cacheDir = "/srv/kernel/ccache";
  };

  # The Perl management helper fails the security wrapper ELF check.
  security.wrappers.nix-ccache.enable = false;

  nix.settings.extra-sandbox-paths = [ config.programs.ccache.cacheDir ];
}
