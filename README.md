# nixos-upgrade-on-shutdown

![WhatsApp Image 2026-04-15 at 03 52 20](https://github.com/user-attachments/assets/cf7e452b-b39d-4de3-b69a-531919b84588)

NixOS' [default upgrade module](https://github.com/NixOS/nixpkgs/blob/nixos-unstable/nixos/modules/tasks/auto-upgrade.nix) on desktop by default can significantly slow down the computer on bigger rebuilds [[1](https://github.com/NixOS/nixpkgs/issues/198668)]. This means that the computer can get really slow if the upgrade kicks in when the user is using the PC.

This module makes the upgrade run on Shutdown, not on Reboots or Suspends, etc. If an upgrade is queued, and a Reboot is issued, it will leave a flag at `/etc/nixos-reboot-update.flag` so it is queued again when it boots back up.

It only supports flakes, and is expected to be used with a remote repository that updates itself (through for example GitHub actions.). This module doesn't run `nix flake update` itself. See the [GitHub Actions Section](#github-actions) for more details.

By default, it waits `40` seconds to see if the user will leave the computer/Laptop connected to AC. This is configurable. If you want it to only activate when connected to AC, you can set `minimumBatteryToProceedWithoutAC` to something higher than `100`.

By default it uses [nix-output-monitor](https://github.com/maralorn/nix-output-monitor):

![gif4](https://github.com/user-attachments/assets/21d0fc8f-8101-45e7-858f-db6b7b0304a9)

## Installation & Usage

### Option A — plain `nixosModules` (recommended for most setups)

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    upgrade-on-shutdown.url = "github:yeshey/nixos-upgrade-on-shutdown";
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
  flake  = "github:youruser/yourRepoName";
  host = "yourhost";
};
```

### Option B — flake-parts

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url     = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    upgrade-on-shutdown.url = "github:yeshey/nixos-upgrade-on-shutdown";
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
| `flake` | str | *(required)* | Flake URI of the NixOS config to build, e.g. `github:youruser/nixos-config`. A remote URI is strongly recommended, see above. |
| `flags` | list of str | `[]` | Extra flags forwarded to `nix build`. |
| `useNom` | bool | `true` | Whether to use `nix-output-monitor` (`nom`) for build output. Provides a more detailed UI for the build process. |
| `dates` | str | `*-*-01,16 06:10:00` | When to arm the update service. Accepts any `systemd.time(7)` calendar expression. |
| `persistent` | bool | `true` | If true, missed timer firings are caught up on next boot (`Persistent=` in the timer). |
| `randomizedDelaySec` | str | `"0"` | Random jitter added before each timer firing. |
| `fixedRandomDelay` | bool | `false` | Keep the random delay consistent across runs (reduces jitter spread). |
| `minimumBatteryToProceedWithoutAC` | int | `85` | Battery % threshold below which the update waits to see if AC is connected before proceeding. Ignored on desktops (no battery). |
| `secondsToWaitBeforeCheckingAC` | int | `40` | Seconds to wait on low battery before re-checking the AC adapter state. |
| `jobTimeoutSec` | str | `"10h"` | Maximum time for the update before killing it. This also sets the maximum time for the entire poweroff process, so it shouldn't be less than the `30min` default. |
| `minimumFreeSpace` | int | `25` | Minimum free space (GiB) on the filesystem holding `/nix/store` before an update is allowed to run. |
| `estimateSpaceFromCurrentSystem` | bool | `true` | Also require at least as much free space as the closure of the currently running system occupies. |
| `cleanup.enable` | bool | `true` | Automatically free disk space when there is not enough for the update. |
| `cleanup.generationsOlderThan` | int | `21` | First cleanup stage: delete generations older than this many days and garbage-collect. Set to `0` to skip. |
| `cleanup.aggressive` | bool | `true` | Second cleanup stage: if still short on space, delete *all* old generations (keeps the current one). |
| `notificationWaitSeconds` | int | `60` | How long the post-boot notification service waits for a graphical session before reporting a skipped/failed update. |
| `extraKeepAliveServices` | list of str | `[]` | Additional systemd units appended to the built-in `After=` list, they'll be kept running during the upgrade process on shutdown. Useful for VPN daemons or other services that must be up during the upgrade. Duplicates of built-in entries are silently ignored. This already includes entries like `sshd.service`, `thermald.service`, `network-online.target`, etc. |

## Disk space checks

A full NixOS build needs a lot of room. If `/nix/store` runs out of space
mid-build, the update fails at the worst possible moment — during shutdown.
Before building, the module therefore checks the free space on the filesystem
holding `/nix/store`:

* The **floor** is `minimumFreeSpace` GiB (default `25`).
* If `estimateSpaceFromCurrentSystem` is enabled (the default), the requirement
  is raised to the size of the closure of the currently running system
  (`nix path-info -S /run/current-system`). A new generation can be roughly as
  large as the current one, so this is a conservative estimate of what a
  rebuild may need.

If the space is insufficient, old Nix data is deleted in two stages
(`cleanup`):

1. `nix-collect-garbage --delete-older-than <N>d` — deletes generations older
   than `cleanup.generationsOlderThan` days (default `21`, like
   `nh clean --keep-since 21d`) and garbage-collects unreachable paths.
2. If that still isn't enough, `nix-collect-garbage -d` deletes **all** old
   generations, keeping only the current one. This removes rollback points, so
   it only runs when stage 1 was insufficient. Disable it with
   `cleanup.aggressive = false`.

The check runs twice:

* When the timer fires (while the system is running), so cleanup happens in a
  healthy system and you get a desktop notification if space is still short.
* Right before the build at shutdown, in case something filled the disk in the
  meantime.

If space is still insufficient at shutdown, the update is **skipped**: the old
generation is kept, the retry flag is written so the update is attempted again
on the next shutdown, and the result is recorded in
`/var/lib/nixos-upgrade-on-shutdown/last-result`. On the next boot a one-shot
service reads that file and reports the outcome — on the console, in the
journal, and as a desktop notification (waiting up to
`notificationWaitSeconds` for a graphical session to appear). Failed builds are
reported the same way.

> **Tip:** setting `nix.settings.min-free = "20G"` (and optionally
> `max-free`) is a good complement: it makes Nix itself garbage-collect during
> builds instead of failing when the disk fills up.

## Impermanence

If you use [impermanence](https://github.com/nix-community/impermanence) to
wipe `/` on every boot, the flag file that tracks deferred updates accross reboots
(`/etc/nixos-reboot-update.flag`) will be lost. You need to persist it
yourself. The same applies to the result of the last shutdown-time update
(`/var/lib/nixos-upgrade-on-shutdown`), which is used to notify you about
skipped or failed updates after a reboot:

```nix
environment.persistence."/persistent" = {
  files = [
    "/etc/nixos-reboot-update.flag"
  ];
  directories = [
    "/var/lib/nixos-upgrade-on-shutdown"
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
