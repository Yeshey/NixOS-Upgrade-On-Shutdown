# upgrade-on-shutdown

A NixOS module that stages a system update on every scheduled shutdown,
keeping your machines up-to-date without interrupting your work session.

## How it works

1. A **systemd timer** fires on the 1st and 16th of each month at 06:10
   (10 minutes after a scheduled CI push) and **starts the update service**.
2. The service **notifies all logged-in desktop users** that an update has
   been staged and will apply on the next power-off.
3. When you **power off**, the service's `ExecStop` hook runs:
   - If the machine is **rebooting** instead of powering off, a flag file is
     written to `/etc/nixos-reboot-update.flag` so the update is re-armed on
     the next boot.
   - If the **battery is below 85 %**, the service waits 40 seconds to see
     whether the AC adapter is connected before deciding to proceed.
   - On success it builds the new system closure, registers it as the current
     generation, and installs the bootloader — so the **next boot** runs the
     new generation.

## Installation

### Option A — plain `nixosModules` (recommended for most setups)

Add the flake as an input and include the module in your NixOS configuration:

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    upgrade-on-shutdown.url = "github:yeshey/upgrade-on-shutdown";
  };

  outputs = { nixpkgs, upgrade-on-shutdown, ... }: {
    nixosConfigurations.my-host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        upgrade-on-shutdown.nixosModules.default
        ./configuration.nix
      ];
    };
  };
}
```

### Option B — flake-parts

If your configuration is built with
[flake-parts](https://flake.parts), import the flake module instead:

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url     = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    upgrade-on-shutdown.url = "github:yeshey/upgrade-on-shutdown";
  };

  outputs = inputs@{ flake-parts, upgrade-on-shutdown, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        upgrade-on-shutdown.flakeModules.default
      ];

      # The module is now available as:
      #   flake.modules.nixos.upgrade-on-shutdown
      # and can be used in your nixosConfigurations normally.
    };
}
```

## Customisation

The module hard-codes a few values that you may want to adjust for your own
setup. Edit `modules/nixos/upgrade-on-shutdown.nix` (or override the module
options in your configuration):

| Value | Where | Description |
|---|---|---|
| `github:yeshey/nixos-config` | `flakeLocation` | The flake URL that is built on shutdown. Change this to your own config repo. |
| `*-*-01,16 06:10:00` | `timerConfig.OnCalendar` | Schedule of when to arm the update service. |
| `85` | `preStop` script | Minimum battery percentage required to proceed without AC. |
| `40` | `preStop` script | Seconds to wait for AC before giving up on a low-battery machine. |
| `10h` | `TimeoutStopSec` / `JobTimeoutSec` | Maximum time allowed for the build + bootloader install. |

## Impermanence

If you use [impermanence](https://github.com/nix-community/impermanence) to
wipe `/` on every boot, the flag file that tracks deferred updates
(`/etc/nixos-reboot-update.flag`) will be lost across reboots. You need to
persist it yourself. Add the following to your impermanence configuration:

```nix
environment.persistence."/persistent" = {
  files = [
    "/etc/nixos-reboot-update.flag"
  ];
};
```