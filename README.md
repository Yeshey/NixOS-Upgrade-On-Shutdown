# nixos-upgrade-on-shutdown

NixOS on desktop by default can significantly slow down the computer on bigger rebuilds [[1](https://github.com/NixOS/nixpkgs/issues/198668)]. This means that the computer can get really slow if the default `system.autoUpgrade` quicks in when the user is using the PC.

This module makes the upgrade run on Shutdown, not on Reboots, Suspends, etc. If an upgrade is queued, and a Reboot is issued, it will leave a flag at `/etc/nixos-reboot-update.flag` so it is queued again when it boots back up.

It only supports flakes, and is expected to be used with a remote repository that updates itself (through for example GitHub actions.) See [GitHub Actions](#github-actions) for more details.

By default, it waits `40` seconds to see if the user will leave the computer/Laptop connected to AC. This is configurable. If you want it to only activate when connected to AC, you can set `minimumBatteryToProceedWithoutAC` to something higher than `100`.

## Installation

### Option A — plain `nixosModules` (recommended for most setups)

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    upgrade-on-shutdown.url = "github:youruser/nixos-upgrade-on-shutdown";
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

Then enable it in your NixOS configuration:

```nix
system.autoUpgradeOnShutdown = {
  enable = true;
  flake  = "github:youruser/nixos-config";
};
```

### Option B — flake-parts

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url     = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    upgrade-on-shutdown.url = "github:youruser/nixos-upgrade-on-shutdown";
  };

  outputs = inputs@{ flake-parts, upgrade-on-shutdown, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        upgrade-on-shutdown.flakeModules.default
      ];

      # flake.modules.nixos.upgrade-on-shutdown is now available
      # to include in your nixosConfigurations.
    };
}
```

## Usage

Example Usage:

```nix
  system.autoUpgradeOnShutdown = {
    enable = true;
    flake = "github:yeshey/nixos-config";
    host = config.networking.hostName;
    dates  = "*-*-01,16 06:10:00";
    extraKeepAliveServices = [ "autossh-reverseProxy.service" ]; # service that is kept during the upgrade process on shutdown
  };
```

## Options

All options live under `system.autoUpgradeOnShutdown`.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `false` | Enable the module. |
| `flake` | str | *(required)* | Flake URI of the NixOS config to build, e.g. `github:youruser/nixos-config`. A remote URI is strongly recommended — see above. |
| `flags` | list of str | `[]` | Extra flags forwarded to `nix build`. |
| `useNom` | bool | `true` | Whether to use `nix-output-monitor` (`nom`) for build output. Provides a more detailed UI for the build process. |
| `dates` | str | `*-*-01,16 06:10:00` | When to arm the update service. Accepts any `systemd.time(7)` calendar expression. |
| `persistent` | bool | `true` | If true, missed timer firings are caught up on next boot (`Persistent=` in the timer). |
| `randomizedDelaySec` | str | `"0"` | Random jitter added before each timer firing. |
| `fixedRandomDelay` | bool | `false` | Keep the random delay consistent across runs (reduces jitter spread). |
| `minimumBatteryToProceedWithoutAC` | int | `85` | Battery % threshold below which the update waits to see if AC is connected before proceeding. Ignored on desktops (no battery). |
| `secondsToWaitBeforeCheckingAC` | int | `40` | Seconds to wait on low battery before re-checking the AC adapter state. |
| `jobTimeoutSec` | str | `"10h"` | Maximum time for the build + bootloader install (`TimeoutStopSec` on the service, `JobTimeoutSec` on the poweroff target). |
| `extraKeepAliveServices` | list of str | `[]` | Additional systemd units appended to the built-in `After=` list, they'll be kept running during the upgrade process on shutdown. Useful for VPN daemons or other services that must be up during the upgrade. Duplicates of built-in entries are silently ignored. This already includes entries like `sshd.service`, `thermald.service`, `network-online.target`, etc. |

## Impermanence

If you use [impermanence](https://github.com/nix-community/impermanence) to
wipe `/` on every boot, the flag file that tracks deferred updates
(`/etc/nixos-reboot-update.flag`) will be lost. You need to persist it
yourself:

```nix
environment.persistence."/persistent" = {
  files = [
    "/etc/nixos-reboot-update.flag"
  ];
};
```

## GitHub Actions

You are expected to point this module to a remote repository that it will then use to update the computer. Automatically updating flake.lock isn't supported, that has to be done externally. You can see an example of a GitHub Action that does this twice a month being used in my config [here](https://github.com/Yeshey/nixOS-Config/blob/main/.github/workflows/update-flake.yml)

Below is an example workflow that updates `flake.lock` on the 1st and 16th
of each month at 06:00 UTC. This is 10 minutes before the module's default timer.

<details>
<summary><b>Click to expand the <code>update-flake.yml</code> Github Action example code</b></summary>

```yaml
# .github/workflows/update-flake.yml
name: Auto bump flake.lock

on:
  schedule:
    - cron: "0 6 1,16 * *"
  workflow_dispatch:

concurrency:
  group: bump-flake-lock
  cancel-in-progress: true

permissions:
  contents: write

jobs:
  bump:
    name: Bump flake.lock
    runs-on: ubuntu-latest
    steps:
      - name: Set up QEMU for multi-arch
        uses: docker/setup-qemu-action@v3
        with:
          platforms: arm64

      - name: Nothing but Nix (reclaim disk space for /nix)
        uses: wimpysworld/nothing-but-nix@main
        with:
          hatchet-protocol: "cleave"

      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Install Nix
        uses: cachix/install-nix-action@v31
        with:
          extra_nix_config: |
            experimental-features = nix-command flakes pipe-operators
            extra-platforms = aarch64-linux
            extra-system-features = nixos-test benchmark big-parallel kvm

      - name: Update all flake inputs
        run: |
          git checkout main || git checkout -b main
          nix flake update

      - name: Check flake
        run: nix flake check --all-systems

      - name: Commit and push flake.lock
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git fetch origin main
          git add flake.lock
          
          # Check if there are actually changes to commit
          if ! git diff --cached --quiet flake.lock; then
            git commit --no-verify --signoff -m "chore(deps): update flake.lock (all inputs)"
            git push origin main
          else
            echo "No changes detected in flake.lock"
          fi
```
</details>