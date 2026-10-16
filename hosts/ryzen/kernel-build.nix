{ config, ... }:
{
  programs.ccache = {
    enable = true;
    cacheDir = "/srv/kernel/ccache";
  };

  nix.settings.extra-sandbox-paths = [ config.programs.ccache.cacheDir ];
}
