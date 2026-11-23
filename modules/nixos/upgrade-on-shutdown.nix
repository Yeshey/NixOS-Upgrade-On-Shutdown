{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.system.autoUpgradeOnShutdown;
  serviceDescription = "NixOS Upgrade on Shutdown";
  buildBin = if cfg.useNom 
    then "${pkgs.nix-output-monitor}/bin/nom" 
    else "${pkgs.nix}/bin/nix";

  # Where the outcome of the last shutdown-time update is recorded, so the
  # post-boot report service can notify the user about failures.
  stateDir = "/var/lib/nixos-upgrade-on-shutdown";
  statusFile = "${stateDir}/last-result";

  # Hard floor for free space, in bytes.
  minimumFreeBytes = cfg.minimumFreeSpace * 1024 * 1024 * 1024;

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

  # Disk-space preflight, cleanup and monitoring helper, shared by the
  # timer-triggered start script, the shutdown hook and the build watcher.
  #
  #   check [full|reserve]  report free space and whether it is enough
  #   clean [full|reserve]  free space in stages until the target is met
  #   reserve               silent check against the build reserve (for the
  #                         watcher, which runs it every couple of seconds)
  #   free                  print free bytes on the store filesystem
  #
  # "full" targets the preflight requirement (minimumFreeSpace or the current
  # system closure); "reserve" targets buildSpaceReserve, the headroom kept
  # free while a build is running.
  spaceTool = pkgs.writeShellScriptBin "nixos-upgrade-space" ''
    set -uo pipefail

    STORE="/nix/store"
    MIN_FREE_BYTES=${toString minimumFreeBytes}
    RESERVE_BYTES=${toString (cfg.buildSpaceReserve * 1024 * 1024 * 1024)}
    ESTIMATE_FROM_CURRENT=${if cfg.estimateSpaceFromCurrentSystem then "1" else "0"}
    KEEP_DAYS=${toString cfg.cleanup.generationsOlderThan}
    AGGRESSIVE=${if cfg.cleanup.aggressive then "1" else "0"}
    CLEANUP_ENABLED=${if cfg.cleanup.enable then "1" else "0"}
    GC_TIMEOUT=900

    free_bytes() {
      df -P -B1 "$STORE" | awk 'NR == 2 { print $4 }'
    }

    current_closure_bytes() {
      ${pkgs.nix}/bin/nix path-info -S /run/current-system 2>/dev/null \
        | awk 'NR == 1 { print $2 }'
    }

    required_bytes() {
      local req="$MIN_FREE_BYTES" closure
      if [ "$ESTIMATE_FROM_CURRENT" = "1" ]; then
        closure="$(current_closure_bytes)"
        case "$closure" in
          "" | *[!0-9]*) closure=0 ;;
        esac
        if [ "$closure" -gt "$req" ]; then
          req="$closure"
        fi
      fi
      printf '%s\n' "$req"
    }

    target_bytes() {
      case "''${1:-full}" in
        reserve) printf '%s\n' "$RESERVE_BYTES" ;;
        *) required_bytes ;;
      esac
    }

    human() {
      numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || printf '%s bytes\n' "$1"
    }

    have_enough() {
      [ "$(free_bytes)" -ge "$(target_bytes "''${1:-full}")" ]
    }

    check() {
      local mode="''${1:-full}" free target
      free="$(free_bytes)"
      target="$(target_bytes "$mode")"
      printf 'free: %s available on %s\n' "$(human "$free")" "$STORE"
      if [ "$mode" = "reserve" ]; then
        printf 'reserve: %s must stay free while building\n' "$(human "$target")"
      elif [ "$ESTIMATE_FROM_CURRENT" = "1" ]; then
        printf 'required: %s (floor %s, or the size of the current system closure)\n' \
          "$(human "$target")" "$(human "$MIN_FREE_BYTES")"
      else
        printf 'required: %s\n' "$(human "$target")"
      fi
      [ "$free" -ge "$target" ]
    }

    clean() {
      local mode="''${1:-full}"
      if [ "$CLEANUP_ENABLED" != "1" ]; then
        echo "Automatic cleanup is disabled; not deleting anything."
        return 0
      fi
      echo "Trying to free space on $STORE..."
      if [ "$KEEP_DAYS" -gt 0 ]; then
        echo "Deleting generations older than $KEEP_DAYS days and collecting garbage..."
        timeout "$GC_TIMEOUT" \
          ${pkgs.nix}/bin/nix-collect-garbage --delete-older-than "$KEEP_DAYS"d \
          || echo "warning: deleting old generations failed or timed out"
      fi
      if [ "$AGGRESSIVE" = "1" ] && ! have_enough "$mode"; then
        echo "Still short on space; deleting ALL old generations (the current one is kept)..."
        timeout "$GC_TIMEOUT" ${pkgs.nix}/bin/nix-collect-garbage -d \
          || echo "warning: aggressive garbage collection failed or timed out"
      fi
      df -h "$STORE" | tail -n 1
    }

    case "''${1:-}" in
      check) check "''${2:-full}" ;;
      clean) clean "''${2:-full}" ;;
      reserve) have_enough reserve ;;
      free) free_bytes ;;
      *) echo "usage: $0 check|clean [full|reserve] | reserve | free" >&2; exit 2 ;;
    esac
  '';

  # Exit code used by the update script to signal "aborted: not enough disk
  # space", so the shutdown hook can record the right reason.
  spaceAbortExitCode = 10;

  # Build the system closure, set the profile, and activate via
  # switch-to-configuration boot — updates the bootloader without trying
  # to restart services, which would fail mid-shutdown.
  #
  # The build runs under a watchdog that stops it if the store runs low on
  # space, so space can be freed and the build retried instead of ending in a
  # half-full disk (and a nix client that may hang after an ENOSPC failure).
  updateScript = pkgs.writeShellScriptBin "nixos-update-flake" ''
    set -e

    FLAKE="${cfg.flake}#nixosConfigurations.${cfg.host}"
    OUT_FILE=$(mktemp)
    SENTINEL="/run/nixos-upgrade-space-stop"
    trap 'rm -f "$OUT_FILE"; rm -f "$SENTINEL"' EXIT

    echo "Building system closure from $FLAKE..."

    run_build() {
      : > "$OUT_FILE"
      rm -f "$SENTINEL"

      # Job control puts the build in its own process group, so the watchdog
      # can stop the whole tree (nom, the nix client and any builders it
      # spawned) with a single signal.
      set -m
      ${buildBin} build "$FLAKE.config.system.build.toplevel" \
        --print-out-paths --no-link --refresh \
        ${lib.escapeShellArgs cfg.flags} > "$OUT_FILE" &
      local pid=$!
      set +m

      (
        while kill -0 "$pid" 2>/dev/null; do
          if ! ${spaceTool}/bin/nixos-upgrade-space reserve; then
            ${spaceTool}/bin/nixos-upgrade-space check reserve >&2 || true
            echo "Free space dropped below the reserve; stopping the build so space can be freed." >&2
            : > "$SENTINEL"
            kill -TERM -"$pid" 2>/dev/null
            sleep 5
            kill -KILL -"$pid" 2>/dev/null
            break
          fi
          sleep 2
        done
      ) &
      local watchdog=$!

      local rc=0
      wait "$pid" || rc=$?

      kill "$watchdog" 2>/dev/null || true
      wait "$watchdog" 2>/dev/null || true

      return "$rc"
    }

    attempt=0
    OUT_PATH=""

    while :; do
      attempt=$((attempt + 1))

      RC=0
      set +e
      run_build
      RC=$?
      set -e

      if [ "$RC" -eq 0 ]; then
        OUT_PATH=$(cat "$OUT_FILE")
        break
      fi

      if [ ! -e "$SENTINEL" ]; then
        echo "Build failed (exit code $RC)."
        exit 1
      fi

      echo "Build was stopped because the store ran low on space."
      if [ "$attempt" -gt ${toString cfg.maxBuildRetries} ]; then
        echo "Giving up after $attempt attempt(s)."
        exit ${toString spaceAbortExitCode}
      fi

      echo "Cleaning up to free space, then retrying the build..."
      ${spaceTool}/bin/nixos-upgrade-space clean reserve || true

      if ! ${spaceTool}/bin/nixos-upgrade-space check reserve; then
        echo "Not enough free space even after cleanup."
        exit ${toString spaceAbortExitCode}
      fi

      echo "Retrying build (attempt $((attempt + 1)))."
    done

    if [ -z "$OUT_PATH" ]; then
      echo "Build failed! Aborting update."
      exit 1
    fi

    echo "Build successful: $OUT_PATH"

    # Register as current generation
    echo "Setting system profile..."
    ${pkgs.nix}/bin/nix-env --profile /nix/var/nix/profiles/system --set "$OUT_PATH"

    # Install bootloader only (no service restarts)
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
    "nix-daemon.service"
    "systemd-user-sessions.service"
    "plymouth-quit-wait.service"
    "thermald.service"
    "systemd-oomd.service"
    "systemd-timesyncd.service"
    "systemd-resolved.service"
    "systemd-journald.service"
    "nss-lookup.target"
    "dbus.service"
    "dbus.socket"
    "sshd.service"
    "local-fs.target"
    "avahi-daemon.service"
    "avahi-daemon.socket"
    "NetworkManager.service"
    "wpa_supplicant.service"
    "remote-fs.target"
    "cryptsetup.target"
    "tlp.service"
    "power-profiles-daemon.service"
    "acpid.service"
    "upower.service"
    "systemd-logind.service"
    "dbus-org.freedesktop.login1.service"
    "polkit.service" 
    "tailscaled.service"
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

    host = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      example = "my-laptop";
      description = ''
        The attribute name under `nixosConfigurations` in your flake.
        Defaults to the system's networking hostname.
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

    minimumFreeSpace = lib.mkOption {
      type = lib.types.int;
      default = 25;
      example = 10;
      description = ''
        Minimum free disk space, in GiB, that must be available on the
        filesystem holding {file}`/nix/store` before the update is allowed to
        run.

        If less than this is available, old Nix data is cleaned up first (see
        {option}`system.autoUpgradeOnShutdown.cleanup`) and the space is
        checked again. If it is still insufficient the update is skipped, the
        system boots into the old generation, and a notification is shown
        after the next boot.
      '';
    };

    estimateSpaceFromCurrentSystem = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        When enabled, the space requirement is raised to at least the size of
        the closure of the currently running system
        ({file}`/run/current-system`). A new system generation can be roughly
        as large as the current one, so this is a conservative estimate of
        what a rebuild may need.

        Set to `false` to only enforce
        {option}`system.autoUpgradeOnShutdown.minimumFreeSpace`.
      '';
    };

    buildSpaceReserve = lib.mkOption {
      type = lib.types.int;
      default = 5;
      example = 10;
      description = ''
        Free space, in GiB, that must stay available on the store filesystem
        while the build is running.

        The build runs under a watchdog that checks the free space every few
        seconds. If it drops below this reserve, the build is stopped, old
        Nix data is cleaned up, and the build is retried. This turns a "disk
        filled up mid-build" failure into a cleanup + retry cycle instead of a
        broken update (and a nix client that may hang after an `ENOSPC`).

        Set to `0` to disable mid-build monitoring.
      '';
    };

    maxBuildRetries = lib.mkOption {
      type = lib.types.int;
      default = 2;
      example = 0;
      description = ''
        How many times a build that was stopped because of low disk space is
        retried after cleanup, before the update is aborted. Each retry reuses
        everything that was already downloaded or built.
      '';
    };

    cleanup = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether to automatically free disk space when there is not enough
          for the update. When disabled, a space shortfall simply skips the
          update instead of deleting old generations.
        '';
      };

      generationsOlderThan = lib.mkOption {
        type = lib.types.int;
        default = 21;
        example = 14;
        description = ''
          First cleanup stage: delete system generations older than this many
          days and garbage-collect unreachable store paths (similar to
          `nh clean --keep-since`). Set to `0` to skip this stage.
        '';
      };

      aggressive = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Second cleanup stage: if space is still insufficient after deleting
          generations older than
          {option}`system.autoUpgradeOnShutdown.cleanup.generationsOlderThan`,
          delete *all* old generations (keeping the current generation only)
          and garbage-collect again.

          This removes rollback points, so it is only attempted after the
          gentler stage failed to free enough space.
        '';
      };
    };

    notificationWaitSeconds = lib.mkOption {
      type = lib.types.int;
      default = 60;
      example = 0;
      description = ''
        After a skipped or failed update, how long (in seconds) the post-boot
        notification service waits for a graphical user session to appear
        before showing the desktop notification. A value above zero makes it
        more likely that the notification is actually seen after login.

        The message is always written to the journal and to the console as
        well, so it is not lost when no desktop session is running.
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

    useNom = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to use nix-output-monitor (nom) for builds to provide a more detailed UI.";
    };

  };

  config = lib.mkIf cfg.enable {

    # system.autoUpgrade conflicts with this module — force it off so only
    # the shutdown service handles upgrades.
    system.autoUpgrade.enable = lib.mkForce false;

    environment.systemPackages = with pkgs; [ libnotify notify-send-all nix-output-monitor ];

    # ── Timer ──────────────────────────────────────────────────────────────
    # Fires on the configured schedule. Its job is to arm the service so the
    # notification fires and the service waits for the next power-off.
    systemd.timers.nixos-upgrade-on-shutdown = {
      wantedBy = [ "timers.target" ];
      after = [ "time-sync.target" "network.target" ];
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
      description      = serviceDescription;
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
        gawk
        gnutar
        xz.bin
        gzip
        gitMinimal
        nix-output-monitor
        config.nix.package.out
      ];

      # ExecStart: runs when the timer fires.
      # Waits 3 sec then notifies all desktop users that an update is staged.
      # Also preflights disk space while the system is still running, so old
      # generations can be cleaned up in a healthy system instead of at
      # shutdown.
      script = ''
        echo "Will notify in 3 seconds"
        sleep 3
        ${notify-send-all}/bin/notify-send-all -u critical "Will update on shutdown..." || true

        if ! ${spaceTool}/bin/nixos-upgrade-space check; then
          ${notify-send-all}/bin/notify-send-all -u normal \
            "Cleaning up old NixOS generations" \
            "Not enough free disk space for the next update; freeing space now." || true

          ${spaceTool}/bin/nixos-upgrade-space clean || true

          if ! SPACE_REPORT=$(${spaceTool}/bin/nixos-upgrade-space check 2>&1); then
            DETAIL=$(printf '%s' "$SPACE_REPORT" | tr '\n' ' ')
            ${notify-send-all}/bin/notify-send-all -u critical \
              "Not enough disk space for the NixOS update" \
              "$DETAIL Free up some space, or the update will be skipped at the next shutdown." || true
          fi
        fi
      '';

      # ExecStop: runs during the shutdown sequence.
      # Distinguishes power-off from reboot: on reboot, drops a flag file so
      # the boot-time check service re-arms the update for the next shutdown.
      preStop = ''
          FLAG_FILE="/etc/nixos-reboot-update.flag"
          STATUS_FILE="${statusFile}"

          # Record the outcome so the post-boot report service can tell the
          # user what happened while the machine was shutting down.
          write_status() {
            mkdir -p "${stateDir}" 2>/dev/null || true
            printf 'result=%s\nreason=%s\nmessage=%s\n' "$1" "$2" "$3" \
              > "$STATUS_FILE" 2>/dev/null || true
          }

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
                echo -ne "\r [${serviceDescription}] Waiting ''${i} seconds to check if power is left connected/disconnected... " > /dev/console
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
              if ! ${spaceTool}/bin/nixos-upgrade-space check; then
                echo "Not enough disk space for the update; cleaning up old Nix data..."
                ${spaceTool}/bin/nixos-upgrade-space clean || true

                if ! SPACE_REPORT=$(${spaceTool}/bin/nixos-upgrade-space check 2>&1); then
                  echo "Not enough disk space even after cleanup. Skipping update."
                  DETAIL=$(printf '%s' "$SPACE_REPORT" | tr '\n' ' ')
                  echo " [${serviceDescription}] Update skipped: not enough disk space. $DETAIL" > /dev/console 2>/dev/null || true
                  write_status aborted no-space "Not enough disk space: $DETAIL The old generation was kept; the update will be retried on the next shutdown."
                  echo "Creating flag to retry update on next shutdown."
                  touch "$FLAG_FILE" 2>/dev/null || true
                  exit 0
                fi

                echo "Cleanup freed enough space; continuing with the update."
              fi

              if ${updateScript}/bin/nixos-update-flake; then
                echo "Update finished successfully."
                rm -f "$FLAG_FILE"
                rm -f "$STATUS_FILE" 2>/dev/null || true
              else
                UPDATE_RC=$?
                if [ "$UPDATE_RC" -eq ${toString spaceAbortExitCode} ]; then
                  echo "Update skipped: not enough disk space, even after cleanup."
                  DETAIL=$(${spaceTool}/bin/nixos-upgrade-space check reserve 2>&1 || true)
                  DETAIL=$(printf '%s' "$DETAIL" | tr '\n' ' ')
                  echo " [${serviceDescription}] Update skipped: not enough disk space. $DETAIL" > /dev/console 2>/dev/null || true
                  write_status aborted no-space "The build ran out of disk space and cleanup could not free enough space. $DETAIL The old generation was kept; the update will be retried on the next shutdown."
                  echo "Creating flag to retry update on next shutdown."
                  touch "$FLAG_FILE" 2>/dev/null || true
                  exit 0
                fi
                echo "Update FAILED. System will boot into the old generation."
                write_status failed build-failed "The build or bootloader installation failed; the old generation was kept. Run 'journalctl -u nixos-upgrade-on-shutdown' for details."
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
      after = [ "network.target" "nixos-upgrade-on-shutdown.timer" "time-sync.target" ];

      script = ''
        FLAG_FILE="/etc/nixos-reboot-update.flag"

        if [ -f "$FLAG_FILE" ]; then
          if ! systemctl is-active --quiet nixos-upgrade-on-shutdown.service; then
            echo "Re-arming nixos-upgrade-on-shutdown.service"
            systemctl start --no-block nixos-upgrade-on-shutdown.service
          fi
          rm "$FLAG_FILE"
        fi
      '';

      serviceConfig.Type = "oneshot";
    };

    # ── Post-boot report ───────────────────────────────────────────────────
    # If the last shutdown-time update was skipped (e.g. not enough disk
    # space) or failed, tell the user why on the next boot. The message goes
    # to the console and the journal, and is shown as a desktop notification
    # once a graphical session is available.
    systemd.services.nixos-upgrade-on-shutdown-report = {
      description = "Report the result of the last NixOS upgrade on shutdown";
      wantedBy = [ "multi-user.target" ];
      after = [ "multi-user.target" "nixos-reboot-upgrade-check.service" ];

      path = [
        pkgs.coreutils
        pkgs.gnugrep
      ];

      script = ''
        STATUS_FILE="${statusFile}"
        WAIT=${toString cfg.notificationWaitSeconds}

        [ -f "$STATUS_FILE" ] || exit 0

        REASON=$(grep -m1 '^reason=' "$STATUS_FILE" | cut -d= -f2- || true)
        MESSAGE=$(grep -m1 '^message=' "$STATUS_FILE" | cut -d= -f2- || true)

        case "$REASON" in
          no-space)     TITLE="NixOS update skipped: not enough disk space" ;;
          build-failed) TITLE="NixOS update failed" ;;
          *)            TITLE="NixOS update was not applied" ;;
        esac

        echo "$TITLE" > /dev/console 2>/dev/null || true
        echo "$MESSAGE" > /dev/console 2>/dev/null || true
        echo "$TITLE: $MESSAGE"

        # The desktop session usually shows up shortly after multi-user.target;
        # give it a moment so the notification is not lost.
        SESSION_READY=0
        WAITED=0
        while [ "$WAITED" -lt "$WAIT" ] && [ "$SESSION_READY" -eq 0 ]; do
          for bus in /run/user/*/bus; do
            if [ -S "$bus" ]; then
              SESSION_READY=1
              break
            fi
          done
          if [ "$SESSION_READY" -eq 0 ]; then
            sleep 2
            WAITED=$((WAITED + 2))
          fi
        done

        if [ "$SESSION_READY" -eq 1 ]; then
          ${notify-send-all}/bin/notify-send-all -u critical "$TITLE" "$MESSAGE" || true
        fi

        rm -f "$STATUS_FILE"
      '';

      serviceConfig = {
        Type = "oneshot";
        TimeoutStartSec = "${toString (cfg.notificationWaitSeconds + 60)}s";
      };
    };
  };
}
