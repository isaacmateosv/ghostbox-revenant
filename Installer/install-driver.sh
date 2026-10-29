#!/bin/sh
# Installs or removes the GhostBox Revenant Core Audio driver for the Mbox 3. Runs as root: from GhostBox Revenant
# GUI's "Install Driver…" (through the macOS password prompt), from the package, and from ./build.sh install-driver.
#
#   install-driver.sh install <path/to/GhostBoxRevenant.driver> [--watch | --watch-background]
#   install-driver.sh watch | watch-background
#   install-driver.sh uninstall
#
# Installing restarts Core Audio and replugs the Mbox in software (restarting Core Audio mid-stream can leave the
# Mbox ignoring playback until it is replugged). The watchdog then watches coreaudiod for 3 minutes and removes
# the driver again if Core Audio pins the CPU, so the Mac's audio always comes back. Log: /var/tmp/ghostbox-revenant-driver.log
#
# In the background the watchdog runs as a one-shot launchd job: a plain background process does not survive,
# because the password prompt's shell and the package installer end the processes a script leaves behind.

HAL=/Library/Audio/Plug-Ins/HAL
DST="$HAL/GhostBoxRevenant.driver"
LEGACY="$HAL/Mbox3.driver"   # the same driver under its name before the project was renamed
LOG=/var/tmp/ghostbox-revenant-driver.log
WATCH_LABEL=ghostbox-revenant.driver-watchdog
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"   # launchd needs an absolute path

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"; }

watch() {
    log "watching Core Audio for 3 minutes"
    hot=0
    i=0
    while [ "$i" -lt 180 ]; do
        sleep 1
        i=$((i + 1))
        cpu=$(ps -axo %cpu=,comm= | awk '$2 == "/usr/sbin/coreaudiod" { print int($1); exit }')
        if [ "${cpu:-0}" -gt 80 ]; then hot=$((hot + 1)); else hot=0; fi
        [ $((i % 30)) -eq 0 ] && log "${i}s: coreaudiod ${cpu:-?}% CPU"
        if [ "$hot" -ge 15 ]; then
            log "Core Audio above 80% CPU for 15 s: saving a sample and removing the driver"
            sample coreaudiod 5 -file /var/tmp/ghostbox-revenant-coreaudiod-sample.txt >/dev/null 2>&1
            rm -rf "$DST"
            killall coreaudiod 2>/dev/null
            return 1
        fi
    done
    log "Core Audio stayed healthy for 3 minutes"
}

watch_background() {
    launchctl remove "$WATCH_LABEL" 2>/dev/null
    if ! launchctl submit -l "$WATCH_LABEL" -- /bin/sh "$SELF" watch-job; then
        nohup /bin/sh "$SELF" watch >/dev/null 2>&1 &   # fallback where launchctl submit is unavailable
    fi
}

if [ "$(id -u)" != 0 ]; then
    echo "install-driver.sh must run as root" >&2
    exit 2
fi

case "$1" in
    install)
        SRC="$2"
        if [ ! -d "$SRC/Contents/MacOS" ]; then
            echo "no driver bundle at $SRC" >&2
            exit 2
        fi
        log "installing $SRC"
        mkdir -p "$HAL"
        if [ -d "$LEGACY" ]; then rm -rf "$LEGACY"; log "removed the driver installed under its old name"; fi
        rm -rf "$DST"
        ditto "$SRC" "$DST" || exit 1
        chown -R root:wheel "$DST"
        killall coreaudiod 2>/dev/null
        sleep 2
        CTL="$(dirname "$SRC")/mbox3-ctl"
        if [ -x "$CTL" ] && "$CTL" reenumerate >/dev/null 2>&1; then log "replugged the Mbox in software"; fi
        log "driver installed, Core Audio restarted"
        case "$3" in
            --watch) watch ;;
            --watch-background) watch_background ;;
        esac
        ;;
    watch)
        watch
        ;;
    watch-background)
        watch_background
        ;;
    watch-job)  # started by launchd (watch_background)
        watch
        launchctl remove "$WATCH_LABEL"  # unloads this job and ends it; launchd would otherwise keep it loaded
        ;;
    uninstall)
        launchctl remove "$WATCH_LABEL" 2>/dev/null
        rm -rf "$DST" "$LEGACY"
        killall coreaudiod 2>/dev/null
        log "driver removed, Core Audio restarted"
        ;;
    *)
        sed -n '5,7p' "$0" >&2
        exit 2
        ;;
esac
