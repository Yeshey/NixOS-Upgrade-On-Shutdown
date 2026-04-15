{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.system.autoUpgradeOnShutdown;

  # Send a desktop notification to every logged-in GUI user.
  # https://github.com/tonywalker1/notify-send-all (MIT License)
  notify-send-all = pkgs.writeShellScriptBin "notify-send-all" ''
    display_help() {
        echo "Send a notification to all logged-in GUI users."
        echo ""
        echo "Usage: notify-send-all [options] <summary> [body]"
        echo ""
        echo "Options:"
        echo "  -? | --help    This text."
        echo ""
        echo "All options from notify-send are supported, see below..."
        echo
        ${pkgs.libnotify}/bin/notify-send --help
        exit 1
    }

    while [ $# -gt 0 ]; do
        case $1 in
            -h | --help)
                display_help
                exit 1
                ;;
            *)
                break
                ;;
        esac
    done

    for SOME_USER in /run/user/*; do
        SOME_USER=$(basename "$SOME_USER")
        if [ "$SOME_USER" = 0 ]; then
            :
        else
            /run/wrappers/bin/sudo -u $(id -u -n "$SOME_USER") \
                DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/"$SOME_USER"/bus \
                ${pkgs.libnotify}/bin/notify-send "$@"
        fi
    done

    exit 0
  '';

  # Build the system closure, set the profile, and activate via
  # switch-to-configuration boot — updates the bootloader without trying
  # to restart services, which would fail mid-shutdown.
  updateScript = pkgs.writeShellScriptBin "nixos-update-flake" ''
    set -e
    echo "Building system closure from ${cfg.flake}#nixosConfigurations.$HOST..."

    # 1. Build and get the store path
    OUT_PATH=$(${pkgs.nix}/bin/nix build \
      "${cfg.flake}#nixosConfigurations.$HOST.config.system.build.toplevel" \
      --print-out-paths --no-link --refresh \
      ${lib.escapeShellArgs cfg.flags})

    if [ -z "$OUT_PATH" ]; then
      echo "Build failed! Aborting update."
      exit 1
    fi

    echo "Build successful: $OUT_PATH"

    # 2. Register as current generation
    echo "Setting system profile..."
    ${pkgs.nix}/bin/nix-env --profile /nix/var/nix/profiles/system --set "$OUT_PATH"

    # 3. Install bootloader only (no service restarts)
    echo "Installing bootloader..."
    export NIXOS_INSTALL_BOOTLOADER=1

    if $OUT_PATH/bin/switch-to-configuration boot; then
      echo "Bootloader installed successfully. Next boot will use the new generation."
    else
      echo "Failed to install bootloader."
      exit 1
    fi
  '';

  # Base set of services the update service must wait for (and that must
  # remain alive) during the shutdown sequence.
  baseAfterServices = [
    "network-online.target"
    "nss-lookup.target"
    "nix-daemon.service"
    "systemd-user-sessions.service"
    "plymouth-quit-wait.service"
    "thermald.service"
    "systemd-oomd.service"
    "systemd-timesyncd.service"
    "systemd-resolved.service"
    "dbus.service"
    "sshd.service"
    "local-fs.target"
  ];
in
{
  options.system.autoUpgradeOnShutdown = {

    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to periodically stage a NixOS upgrade and apply it on the
        next power-off. When enabled, a systemd timer arms an update service
        on the configured schedule; the actual build and bootloader switch
        happen in the service's stop hook, so the new generation is active
        on the next boot without interrupting a running session.

        This option only works with Flake-based configurations. Set
        {option}`system.autoUpgradeOnShutdown.flake` to the URI of your
        remote config flake.
      '';
    };

    flake = lib.mkOption {
      type = lib.types.str;
      example = "github:youruser/nixos-config";
      description = ''
        The Flake URI of the NixOS configuration to build on shutdown.

        A remote flake (e.g. `github:youruser/nixos-config`) is strongly
        recommended. The update service runs as root, so a local repo
        inside a user home directory is discouraged — file-ownership and
        permission issues are likely when root writes into a
        user-owned directory.
      '';
    };

    flags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--option" "extra-binary-caches" "http://my-cache.example.org/" ];
      description = ''
        Additional flags passed to {command}`nix build` when building the
        new system closure.
      '';
    };

    dates = lib.mkOption {
      type = lib.types.str;
      default = "*-*-01,16 06:10:00";
      example = "weekly";
      description = ''
        When to arm the update service (i.e. when to fire the timer that
        stages the upgrade for the next shutdown).

        The default fires on the 1st and 16th of each month at 06:10 —
        10 minutes after the example GitHub Actions schedule that updates
        {file}`flake.lock`.

        The format is described in {manpage}`systemd.time(7)`.
      '';
    };

    persistent = lib.mkOption {
      type = lib.types.bool;
      default = true;
      example = false;
      description = ''
        If true, the time the timer last triggered is stored on disk.
        When the timer is re-activated after the system was powered off, the
        service is triggered immediately if it would have fired during the
        downtime. This is useful to catch up on missed update windows.

        See {manpage}`systemd.timer(5)` (`Persistent=`).
      '';
    };

    randomizedDelaySec = lib.mkOption {
      type = lib.types.str;
      default = "0";
      example = "45min";
      description = ''
        Add a randomized delay before each scheduled arming of the update
        service. The delay is chosen uniformly between zero and this value.
        The format is described in {manpage}`systemd.time(7)`.
      '';
    };

    fixedRandomDelay = lib.mkOption {
      type = lib.types.bool;
      default = false;
      example = true;
      description = ''
        Make the randomized delay consistent between runs, reducing jitter.
        See {option}`system.autoUpgradeOnShutdown.randomizedDelaySec`.
      '';
    };

    minimumBatteryToProceedWithoutAC = lib.mkOption {
      type = lib.types.int;
      default = 85;
      example = 50;
      description = ''
        Minimum battery percentage (0–100) required to proceed with the
        update immediately on power-off without an AC adapter connected.
        If the battery is below this threshold the service waits
        {option}`system.autoUpgradeOnShutdown.secondsToWaitBeforeCheckingAC`
        seconds and then checks whether AC has been connected in the
        meantime. On desktop machines (no battery detected) this check
        is skipped and the update always proceeds.
      '';
    };

    secondsToWaitBeforeCheckingAC = lib.mkOption {
      type = lib.types.int;
      default = 40;
      example = 60;
      description = ''
        How long (in seconds) to wait on battery before re-checking
        whether an AC adapter has been connected, when the battery level
        is below
        {option}`system.autoUpgradeOnShutdown.minimumBatteryToProceedWithoutAC`.
        If AC is still not connected after this delay, the update is
        skipped and a flag file is written so the upgrade is retried on
        the next shutdown.
      '';
    };

    jobTimeoutSec = lib.mkOption {
      type = lib.types.str;
      default = "10h";
      example = "2h";
      description = ''
        Maximum time allowed for the build and bootloader installation to
        complete. Applied as both `TimeoutStopSec` on the service (how long
        systemd waits for the stop hook to finish) and `JobTimeoutSec` on
        the poweroff target (how long the target itself may wait).

        The format is described in {manpage}`systemd.time(7)`.
      '';
    };

    extraKeepAliveServices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "tailscaled.service" "mullvad-daemon.service" ];
      description = ''
        Additional systemd units to append to the `After=` ordering
        constraint of the update service, beyond the built-in defaults.

        The built-in list already includes the most common networking,
        name-resolution, and session-management units. Use this option to
        add any site-specific services that must still be running before/during the update. For example a VPN daemon needed to reach a private Nix cache, or a
        custom pre-shutdown hook.
      '';
    };

  };

  config = lib.mkIf cfg.enable {

    # system.autoUpgrade conflicts with this module — force it off so only
    # the shutdown service handles upgrades.
    system.autoUpgrade.enable = lib.mkForce false;

    environment.systemPackages = with pkgs; [ libnotify notify-send-all ];

    # ── Timer ──────────────────────────────────────────────────────────────
    # Fires on the configured schedule. Its job is to arm the service so the
    # notification fires and the service waits for the next power-off.
    systemd.timers.nixos-upgrade-on-shutdown = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        Persistent         = cfg.persistent;
        OnCalendar         = cfg.dates;
        RandomizedDelaySec = cfg.randomizedDelaySec;
        FixedRandomDelay   = cfg.fixedRandomDelay;
        Unit               = "nixos-upgrade-on-shutdown.service";
      };
    };

    # ── Main service ───────────────────────────────────────────────────────
    systemd.services.nixos-upgrade-on-shutdown = {
      description      = "NixOS Upgrade on Shutdown";
      restartIfChanged = false;

      unitConfig = {
        DefaultDependencies = false; # critical: prevents pulling in shutdown ordering
        RequiresMountsFor   = "/boot /nix/store";
        X-StopOnRemoval     = false;
      };

      # Conflicts with reboot/shutdown targets so systemd won't stop us
      # prematurely; `before` ensures we finish before the target proceeds.
      conflicts = [ "reboot.target" "shutdown.target" ];
      before    = [ "shutdown.target" ];

      after = lib.lists.unique (baseAfterServices ++ cfg.extraKeepAliveServices);

      wants = [ "network-online.target" ];

      environment = config.nix.envVars // {
        inherit (config.environment.sessionVariables) NIX_PATH;
        HOME = "/root";
      } // config.networking.proxy.envVars;

      path = with pkgs; [
        coreutils
        findutils
        gnutar
        xz.bin
        gzip
        gitMinimal
        config.nix.package.out
      ];

      # ExecStart: runs when the timer fires.
      # Waits 3 sec then notifies all desktop users that an update is staged.
      script = ''
        echo "Will notify in 3 seconds"
        sleep 3
        ${notify-send-all}/bin/notify-send-all -u critical "Will update on shutdown..."
      '';

      # ExecStop: runs during the shutdown sequence.
      # Distinguishes power-off from reboot: on reboot, drops a flag file so
      # the boot-time check service re-arms the update for the next shutdown.
      preStop = ''
          FLAG_FILE="/etc/nixos-reboot-update.flag"
          HOST="$(${pkgs.inetutils}/bin/hostname)"

          if ! systemctl list-jobs | grep -Eq 'poweroff.target.*start'; then
            echo "Not powering off (reboot or other). Creating flag to update after next boot."
            touch "$FLAG_FILE"
          else
            echo "Power-off detected. Checking battery/power before upgrading..."

            BATTERY=$(find /sys/class/power_supply -maxdepth 1 -name "BAT*" | sort | head -1)
            AC=$(find /sys/class/power_supply -maxdepth 1 \
                  \( -name "AC*" -o -name "ADP*" -o -name "ACAD*" \) | sort | head -1)

            if [ -n "$BATTERY" ]; then
              LEVEL=$(cat "$BATTERY/capacity")
              echo "Battery level: ''${LEVEL}%"
            else
              echo "No battery detected (desktop). Treating as always-OK."
              LEVEL=100
            fi

            PROCEED=0

            if [ "$LEVEL" -ge ${toString cfg.minimumBatteryToProceedWithoutAC} ]; then
              echo "Battery >= ${toString cfg.minimumBatteryToProceedWithoutAC}% — proceeding with update."
              PROCEED=1
            else
              echo "Battery level too low (''${LEVEL}%)."
              for i in $(seq ${toString cfg.secondsToWaitBeforeCheckingAC} -1 1); do
                echo -ne "\rWaiting ''${i} seconds to check if power is left connected/disconnected... " > /dev/console
                sleep 1
              done

              ONLINE=0
              if [ -n "$AC" ]; then
                ONLINE=$(cat "$AC/online")
              fi

              if [ "$ONLINE" -eq 1 ]; then
                echo "AC adapter is connected — proceeding with update."
                PROCEED=1
              else
                echo "Battery low (''${LEVEL}%) and AC not connected. Skipping update."
                echo "Creating flag to retry update on next shutdown."
                touch "$FLAG_FILE"
              fi
            fi

            if [ "$PROCEED" -eq 1 ]; then
              if HOST="$HOST" ${updateScript}/bin/nixos-update-flake; then
                echo "Update finished successfully."
                rm -f "$FLAG_FILE"
              else
                echo "Update FAILED. System will boot into the old generation."
              fi
            fi
          fi
        '';

      serviceConfig = {
        Type            = "oneshot";
        RemainAfterExit = "yes";
        TimeoutStopSec  = cfg.jobTimeoutSec;
        KillMode        = "process";
        StandardOutput  = "journal+console";
        StandardError   = "journal+console";
      };
    };

    # Give the poweroff target enough headroom for the upgrade to complete.
    systemd.targets."poweroff".unitConfig.JobTimeoutSec = cfg.jobTimeoutSec;

    # ── Reboot flag check ──────────────────────────────────────────────────
    # If the system rebooted before a scheduled power-off update could run,
    # this service finds the flag and re-arms the update service so it waits
    # for the next shutdown.
    systemd.services.nixos-reboot-upgrade-check = {
      description = "Check for deferred upgrade flag from last reboot";
      wantedBy    = [ "multi-user.target" ];
      after = [ "network.target" "nixos-upgrade-on-shutdown.timer" ];

      script = ''
        FLAG_FILE="/etc/nixos-reboot-update.flag"

        if [ -f "$FLAG_FILE" ]; then
          if ! systemctl is-active --quiet nixos-upgrade-on-shutdown.service; then
            echo "Re-arming nixos-upgrade-on-shutdown.service"
            systemctl start nixos-upgrade-on-shutdown.service
          fi
          rm "$FLAG_FILE"
        fi
      '';

      serviceConfig.Type = "oneshot";
    };
  };
}
