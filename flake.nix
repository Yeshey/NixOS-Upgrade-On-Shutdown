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
        # ── Plain NixOS module ─────────────────────────────────────────────
        # Use this if you compose your config with nixpkgs.lib.nixosSystem
        # and just want to add the module to your modules list:
        #
        #   nixosModules.default = import ./modules/nixos/upgrade-on-shutdown.nix;
        #
        nixosModules.default =
          import ./modules/nixos/upgrade-on-shutdown.nix;

        # ── flake-parts module ─────────────────────────────────────────────
        # Use this if your own config is built with flake-parts.
        # Import it under flakeModules.default and it registers itself under
        # flake.modules.nixos.upgrade-on-shutdown, matching the original
        # module key used in this repo.
        flakeModules.default = { ... }: {
          flake.modules.nixos.upgrade-on-shutdown =
            import ./modules/nixos/upgrade-on-shutdown.nix;
        };
      };
    };
}
