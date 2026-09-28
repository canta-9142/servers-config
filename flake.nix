{
  description = "NixOS home servers";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in
    {
      nixosConfigurations.ryzen = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ ./hosts/ryzen ];
      };

      devShells.${system}.default = pkgs.mkShellNoCC {
        packages = with pkgs; [
          nixfmt-tree
          statix
          deadnix
        ];
      };
      formatter.${system} = pkgs.nixfmt-tree;
      checks.${system} = {
        forgejo = import ./tests/forgejo.nix { inherit pkgs; };
      };
    };
}
