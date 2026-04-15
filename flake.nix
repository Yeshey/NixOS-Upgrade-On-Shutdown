{
  description = "NixOS module that builds and applies system updates on shutdown";

  inputs = {
    nixpkgs.url     = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" ];

      flake = {
        nixosModules.default =
          import ./modules/nixos/upgrade-on-shutdown.nix;

        flakeModules.default = { ... }: {
          flake.nixosModules.upgrade-on-shutdown =
            import ./modules/nixos/upgrade-on-shutdown.nix;
        };
      };
    };
}