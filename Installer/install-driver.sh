#!/bin/sh
# Installs or removes the GhostBox Revenant Core Audio driver for the Mbox 3. Runs as root: from GhostBox Revenant
# GUI's "Install Driver…" (through the macOS password prompt), from the package, and from ./build.sh install-driver.
#
#   install-driver.sh install <path/to/GhostBoxRevenant.driver> [--watch | --watch-background]
#   install-driver.sh restart [path/to/mbox3-ctl]     (the package's postinstall)
#   install-driver.sh watch | watch-background
#   install-driver.sh uninstall
#
# Installing restarts Core Audio, stopping the previous driver process first, and replugs the Mbox in software
# (restarting Core Audio mid-stream can leave the Mbox ignoring playback until it is replugged). The watchdog then
# watches coreaudiod for 3 minutes and removes the driver again if Core Audio pins the CPU, so the Mac's audio
# always comes back. Log: /var/tmp/ghostbox-revenant-driver.log
#
# In the background the watchdog runs as a one-shot launchd daemon in the system domain. A background process
# does not survive (the package installer and the password prompt's shell end what a script leaves behind), and
# neither does a job from `launchctl submit` under the installer, which lands in the installer's own context.

HAL=/Library/Audio/Plug-Ins/HAL
DST="$HAL/GhostBoxRevenant.driver"
LEGACY="$HAL/Mbox3.driver"   # the same driver under its name before the project was renamed
LOG=/var/tmp/ghostbox-revenant-driver.log
WATCH_LABEL=ghostbox-revenant.driver-watchdog
WATCH_DIRS=/var/tmp/ghostbox-revenant-watchdog   # prefix of the private folders holding its job definition
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"   # launchd needs an absolute path

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"; }

# Core Audio runs each driver in a process of its own ("Core Audio Driver (GhostBoxRevenant.driver)"). When
# coreaudiod is killed, that process lingers for about 5 s and keeps streaming until launchd kills it. Meanwhile the
# new driver cannot open the Mbox, and a process killed mid-stream leaves the Mbox ignoring playback until it is
# replugged. So the old driver process is asked to stop first (this driver stops streaming on SIGTERM; older ones
# ignore it), then killed, and only then is the Mbox replugged.
driver_processes() { pgrep -f 'Core Audio Driver \((GhostBoxRevenant|Mbox3)\.driver\)' | tr '\n' ' '; }

restart_core_audio() {  # $1: the mbox3-ctl that replugs the Mbox afterwards (optional)
    old=$(driver_processes)
    killall coreaudiod 2>/dev/null
    if [ -n "$old" ]; then
        kill -TERM $old 2>/dev/null
        sleep 1
        kill -KILL $old 2>/dev/null
        i=0
        while [ "$i" -lt 10 ]; do
            alive=""
            for p in $old; do kill -0 "$p" 2>/dev/null && alive="$alive $p"; done
            [ -z "$alive" ] && break
            sleep 0.2
            i=$((i + 1))
        done
        if [ -n "$alive" ]; then log "the previous driver process did not exit:$alive"; else log "stopped the previous driver process"; fi
    fi
    sleep 2
    if [ -n "$1" ] && [ -x "$1" ] && "$1" reenumerate >/dev/null 2>&1; then log "replugged the Mbox in software"; fi
}

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
            restart_core_audio
            return 1
        fi
    done
    log "Core Audio stayed healthy for 3 minutes"
}

watch_background() {
    launchctl bootout system/"$WATCH_LABEL" 2>/dev/null
    rm -rf "$WATCH_DIRS".*
    dir=$(mktemp -d "$WATCH_DIRS.XXXXXX") || return 1   # root-owned and private: launchd trusts only such plists
    cat > "$dir/$WATCH_LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$WATCH_LABEL</string>
    <key>ProgramArguments</key>
    <array><string>/bin/sh</string><string>$SELF</string><string>watch-job</string><string>$dir</string></array>
    <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST
    chmod 644 "$dir/$WATCH_LABEL.plist"
    if launchctl bootstrap system "$dir/$WATCH_LABEL.plist"; then
        log "watchdog scheduled with launchd"
    else
        log "launchd refused the watchdog; running it as a background process instead"
        rm -rf "$dir"
        nohup /bin/sh "$SELF" watch >/dev/null 2>&1 &
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
        restart_core_audio "$(dirname "$SRC")/mbox3-ctl"
        log "driver installed, Core Audio restarted"
        case "$3" in
            --watch) watch ;;
            --watch-background) watch_background ;;
        esac
        ;;
    restart)  # the package's postinstall: the new driver is in place; $2 = mbox3-ctl
        restart_core_audio "$2"
        log "Core Audio restarted"
        ;;
    watch)
        watch
        ;;
    watch-background)
        watch_background
        ;;
    watch-job)  # started by launchd (watch_background); $2 is the folder holding the job definition
        watch
        case "$2" in "$WATCH_DIRS".*) rm -rf "$2" ;; esac
        launchctl bootout system/"$WATCH_LABEL"  # unloads this job, which ends it
        ;;
    uninstall)
        launchctl bootout system/"$WATCH_LABEL" 2>/dev/null
        rm -rf "$WATCH_DIRS".*
        rm -rf "$DST" "$LEGACY"
        restart_core_audio
        log "driver removed, Core Audio restarted"
        ;;
    *)
        sed -n '5,8p' "$0" >&2
        exit 2
        ;;
esac
