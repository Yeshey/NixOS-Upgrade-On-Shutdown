# nixos-upgrade-on-shutdown

A NixOS module that stages a system update on every scheduled shutdown,
keeping your machines up-to-date without interrupting your work session.

## Concept

The typical workflow this module is designed for:

1. Your NixOS config lives in a **remote Git repository** (e.g. GitHub).
2. A **CI job** (e.g. GitHub Actions) periodically runs `nix flake update`
   and pushes a new `flake.lock`, keeping your inputs fresh.
3. This module's **timer fires shortly after** the CI job, arms the update
   service, and notifies logged-in users that an update will apply on the
   next power-off.
4. When you **power off**, the service builds the new closure, registers it
   as the current system generation, and installs the bootloader — so the
   **next boot** runs the updated system, with no intervention needed.

> **Why a remote flake?**
> The update service runs as root. If your config lives in a local directory
> owned by a regular user (e.g. `~/nixos-config`), root's writes — lock
> files, build artefacts — will change ownership and break your day-to-day
> `git` workflow. Use a remote flake URI such as
> `github:youruser/nixos-config` to avoid this entirely.

## GitHub Actions: keeping `flake.lock` fresh

Below is an example workflow that updates `flake.lock` on the 1st and 16th
of each month at 06:00 UTC — 10 minutes before the module's default timer.
It tries a full update first, falls back to updating only `nixpkgs` inputs
if `nix flake check` fails.

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

      - name: Cache Nix store
        uses: nix-community/cache-nix-action@v6
        with:
          primary-key: nix-${{ runner.os }}-${{ hashFiles('flake.nix') }}
          restore-prefixes-first-match: nix-${{ runner.os }}-
          gc-max-store-size-linux: 4G
          purge: true
          purge-prefixes: nix-${{ runner.os }}-
          purge-last-accessed: 1209600

      - name: Update all flake inputs
        id: full-update
        continue-on-error: true
        run: |
          git checkout main || git checkout -b main
          nix flake update

      - name: Check flake (full update)
        id: full-check
        if: steps.full-update.outcome == 'success'
        continue-on-error: true
        run: nix flake check --all-systems

      - name: Rollback and update nixpkgs + nixpkgs-unstable
        id: dual-update
        if: steps.full-check.outcome == 'failure'
        continue-on-error: true
        run: |
          git restore flake.lock
          nix flake update nixpkgs nixpkgs-unstable

      - name: Check flake (nixpkgs + nixpkgs-unstable)
        id: dual-check
        if: steps.full-check.outcome == 'failure' && steps.dual-update.outcome == 'success'
        continue-on-error: true
        run: nix flake check --all-systems

      - name: Rollback and update nixpkgs only
        if: steps.dual-check.outcome == 'failure'
        run: |
          git restore flake.lock
          nix flake update nixpkgs

      - name: Check flake (nixpkgs only)
        id: single-check
        if: steps.dual-check.outcome == 'failure'
        run: nix flake check --all-systems

      - name: Set commit message
        id: commit-msg
        run: |
          if [ "${{ steps.full-check.outcome }}" == "success" ]; then
            echo "message=chore(deps): update flake.lock (all inputs)" >> $GITHUB_OUTPUT
          elif [ "${{ steps.dual-check.outcome }}" == "success" ]; then
            echo "message=chore(deps): update flake.lock (nixpkgs + nixpkgs-unstable)" >> $GITHUB_OUTPUT
          else
            echo "message=chore(deps): update flake.lock (nixpkgs only)" >> $GITHUB_OUTPUT
          fi

      - name: Commit and push flake.lock
        if: steps.full-check.outcome == 'success' || steps.dual-check.outcome == 'success' || steps.single-check.outcome == 'success'
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git fetch origin main
          git add flake.lock
          git stash
          git reset --hard origin/main
          git stash pop
          if ! git diff --quiet flake.lock; then
            git add flake.lock
            git commit --no-verify --signoff -m "${{ steps.commit-msg.outputs.message }}"
            git push origin main
          else
            echo "No changes to commit"
          fi
```

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

## Options

All options live under `system.autoUpgradeOnShutdown`.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `false` | Enable the module. |
| `flake` | str | *(required)* | Flake URI of the NixOS config to build, e.g. `github:youruser/nixos-config`. A remote URI is strongly recommended — see above. |
| `flags` | list of str | `[]` | Extra flags forwarded to `nix build`. |
| `dates` | str | `*-*-01,16 06:10:00` | When to arm the update service. Accepts any `systemd.time(7)` calendar expression. |
| `persistent` | bool | `true` | If true, missed timer firings are caught up on next boot (`Persistent=` in the timer). |
| `randomizedDelaySec` | str | `"0"` | Random jitter added before each timer firing. |
| `fixedRandomDelay` | bool | `false` | Keep the random delay consistent across runs (reduces jitter spread). |
| `minimumBatteryToProceedWithoutAC` | int | `85` | Battery % threshold below which the update waits to see if AC is connected before proceeding. Ignored on desktops (no battery). |
| `secondsToWaitBeforeCheckingAC` | int | `40` | Seconds to wait on low battery before re-checking the AC adapter state. |
| `jobTimeoutSec` | str | `"10h"` | Maximum time for the build + bootloader install (`TimeoutStopSec` on the service, `JobTimeoutSec` on the poweroff target). |
| `extraKeepAliveServices` | list of str | `[]` | Additional systemd units appended to the built-in `After=` list, they'll be kept running during the upgrade process on shutdown. Useful for VPN daemons or other services that must be up during the upgrade. Duplicates of built-in entries are silently ignored. This already includes entries like `sshd.service`, `thermald.service`, `network-online.target`, etc. |


## How it works

1. **Timer** (`nixos-upgrade-on-shutdown.timer`) fires on `dates`. It starts
   the main service.
2. **Main service** (`nixos-upgrade-on-shutdown.service`) runs a short
   `ExecStart` that notifies all logged-in desktop users that an update has
   been staged. The service then stays active (`RemainAfterExit=yes`),
   waiting for shutdown.
3. **On power-off**, systemd invokes the `ExecStop` hook:
   - If this is a **reboot** (not a power-off), a flag file is written to
     `/etc/nixos-reboot-update.flag` and the update is deferred.
   - If **battery is low** and AC is not connected after
     `secondsToWaitBeforeCheckingAC`, the update is also deferred via the
     same flag file.
   - Otherwise, `nix build` fetches and builds the new closure, `nix-env
     --profile` registers it, and `switch-to-configuration boot` installs
     the bootloader — no service restarts, safe during shutdown.
4. **On next boot**, `nixos-reboot-update-check.service` looks for the flag
   file and re-arms the main service if found, so the deferred update applies
   on the next power-off.

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

This is not included in the module because the persistence mount path
(`/persistent` above) varies between setups.