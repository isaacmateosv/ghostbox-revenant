#!/bin/zsh
# Installs the package on a CI machine (no Mbox attached) and checks that it works on that macOS version and CPU:
# files in place, signatures valid, the native slice runs, Core Audio loads the driver, the watchdog runs, the app
# serves its panel, Core Audio stays healthy, and the uninstaller works. GitHub's macOS runners have passwordless sudo.
#
#   Tools/ci-install-test.sh <GhostBoxRevenant-x.y.z.pkg>
set -u
PKG=${1:?usage: ci-install-test.sh <pkg>}
APP="/Applications/GhostBox Revenant GUI.app"
DRIVER=/Library/Audio/Plug-Ins/HAL/GhostBoxRevenant.driver
CTL="$APP/Contents/Resources/mbox3-ctl"
failures=0

pass() { print "  ok    $*"; }
fail() { print "  FAIL  $*"; failures=$((failures + 1)); }
note() { print "  note  $*"; }

print "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m)"

print "Install"
if sudo installer -pkg "$PKG" -target / ; then pass "installer finished"; else fail "installer failed"; fi
[[ -d "$APP" ]] && pass "app installed" || fail "app missing"
[[ -d "$DRIVER" ]] && pass "driver installed" || fail "driver missing"
[[ "$(stat -f %Su "$DRIVER")" == root ]] && pass "driver owned by root" || fail "driver owner $(stat -f %Su "$DRIVER")"
codesign --verify --deep --strict "$APP" && pass "app signature valid" || fail "app signature"
codesign --verify --strict "$DRIVER" && pass "driver signature valid" || fail "driver signature"

print "Native slice ($(uname -m))"
out=$("$CTL" status 2>&1)
[[ "$out" == *'"connected":false'* ]] && pass "mbox3-ctl runs natively and reports no Mbox: $out" || fail "mbox3-ctl: $out"

print "Core Audio"
loaded=0
for i in {1..30}; do
    pgrep -f "Core Audio Driver \(GhostBoxRevenant.driver\)" >/dev/null && { loaded=1; break; }
    sleep 1
done
(( loaded )) && pass "coreaudiod loaded the driver (its driver process is running)" || fail "no 'Core Audio Driver (GhostBoxRevenant.driver)' process after 30 s"
latency=$("$CTL" latency 2>&1)
[[ "$latency" == *'"latency":"safe"'* ]] && pass "driver answers through Core Audio: $latency" \
    || note "latency property not readable without the Mbox attached ($latency)"

print "Watchdog"
WATCH_LABEL=ghostbox-revenant.driver-watchdog
if sudo launchctl print system/$WATCH_LABEL >/dev/null 2>&1; then
    pass "watchdog running as a launchd daemon, outliving the installer"
else
    fail "watchdog daemon $WATCH_LABEL not running after the installer finished"
    note "install.log: $(grep -i 'ghostbox\|watchdog\|postinstall' /var/log/install.log 2>/dev/null | tail -8)"
fi
grep -q "watching Core Audio" /var/tmp/ghostbox-revenant-driver.log 2>/dev/null && pass "watchdog logged its start" \
    || fail "no watchdog start in the log: $(tail -5 /var/tmp/ghostbox-revenant-driver.log 2>/dev/null)"

print "App"
pgrep -x GhostBoxRevenantGUI >/dev/null || open "$APP"
state=""
for i in {1..40}; do
    state=$(curl -fsS -m 2 http://127.0.0.1:18080/api/state 2>/dev/null) && break
    sleep 1
done
if [[ -n "$state" ]]; then
    print -r -- "$state" | python3 -c 'import json, sys
d = json.load(sys.stdin); i = d["info"]
assert d["ok"] and d["state"]["connected"] is False
print("  ok    panel API up: app", i["app_version"], "| driver", i["driver_version"], "| bundled", i["bundled_driver_version"], "| latency", i["driver_latency"])' \
        || fail "unexpected API answer"
    code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:18080/)
    [[ "$code" == 200 ]] && pass "panel page served" || fail "panel page HTTP $code"
    code=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H 'Content-Type: application/json' -H 'Origin: https://example.com' \
        -d '{"action":"reset_defaults"}' http://127.0.0.1:18080/api/state)
    [[ "$code" == 403 ]] && pass "foreign websites are refused" || fail "foreign origin got HTTP $code"
else
    fail "the app did not answer on 127.0.0.1:18080"
fi

print "Core Audio health"
# CPU used over 10 s with the driver loaded and the app running. (A single ps sample right after the installer
# restarted Core Audio mostly measures its start-up work: 72 % once on an Intel runner.)
cpu_seconds() { ps -o time= -p "$1" | awk '{ n = split($1, p, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + p[i]; print s }'; }
pid=$(pgrep -x coreaudiod)
t0=$([[ -n "$pid" ]] && cpu_seconds $pid)
sleep 10
t1=$([[ -n "$pid" ]] && cpu_seconds $pid)
if [[ -z "$t0" || -z "$t1" ]]; then
    fail "coreaudiod was not running for the whole measurement"
else
    cpu=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%d", (b - a) * 10 }')   # percent of one core
    (( cpu < 50 )) && pass "coreaudiod used ${cpu}% CPU over 10 s" || fail "coreaudiod used ${cpu}% CPU over 10 s"
fi
pkill -x GhostBoxRevenantGUI 2>/dev/null

print "Uninstall"
sudo /bin/sh "$APP/Contents/Resources/install-driver.sh" uninstall >/dev/null && [[ ! -d "$DRIVER" ]] \
    && pass "driver removed by install-driver.sh uninstall" || fail "driver uninstall"
sudo launchctl print system/$WATCH_LABEL >/dev/null 2>&1 && fail "watchdog still running after uninstall" \
    || pass "watchdog stopped by uninstall"

if (( failures )); then print "$failures check(s) failed"; exit 1; fi
print "all install checks passed"
