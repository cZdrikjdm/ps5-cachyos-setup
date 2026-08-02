#!/bin/bash
# ==========================================================
#  PS5-LINUX FINAL SETUP (CachyOS gaming image) — v21
#  Lives on the console: ~/ps5-final.sh
#  Usage:
#    ~/ps5-final.sh         full setup + optional pairing/desktop
#    ~/ps5-final.sh pair    DualSense pairing ONLY
#  Helpers installed on console:
#    ~/pair-dualsense.sh  ~/pair-dualsense-tile.sh (+ desktop/Steam tile)
#    ~/switch-to-desktop.sh  ~/rescue-gaming.sh  ~/boost-on.sh
#    ~/toggle-1080p.sh (reverts the optional 1080p boot flag)
#  Session model (v8):
#    boot     -> gaming (ps5-session-default.service resets token)
#    gaming   -> desktop: "Switch to Desktop" tile in Big Picture
#    desktop  -> gaming: Steam's own "Switch to Gaming Mode" button
#    emergency: ~/rescue-gaming.sh over SSH
#  BT notes (v11): upstream FIXED the double-bind in ps5-linux-patches PR #19
#  (2026-06-23, btusb quirk BTUSB_IFNUM_0). Kernels built from older patches
#  still double-bind -> this script installs the userspace equivalent (udev
#  rule) as a backstop; harmless on already-fixed kernels. ERTM/SC "fixes"
#  from old guides are REMOVED — they break the DualSense's HID channel.
#  v12: adds the Pair-DualSense tile helper (wired-fallback re-pairing
#  ritual, usable without SSH/keyboard).
#  v13 (btmon-verified on fresh flash): pairing rewritten around the pad's
#  real behavior — host-side 'connect' NEVER works on an idle DualSense
#  (br-connection-create-socket is expected); the pad reconnects ITSELF when
#  you tap PS. The old connect-retry loop is gone; the script now waits for
#  the pad-initiated connection instead. hidp is preloaded at boot so the
#  first PS-tap after boot sticks instead of dropping once.
#  v14: pair tile gets the same pad-initiated connect flow + zenity timed
#  popups (kdialog passivepopup needs Plasma, which doesn't exist in the
#  gamescope gaming session — popups were invisible there). Progress also
#  lands in /tmp/pair-tile.log.
#  v15: pairing now handles the #1 user trap — a still-CONNECTED pad ignores
#  PS+Create and can never enter pairing mode (script disconnects before
#  removal, verifies the bond is gone, and shows the bluetoothctl output on
#  failure instead of hiding it). Screensaver step writes Plasma-6
#  powerdevilrc keys (Plasma-5 powermanagementprofilesrc was ignored).
#  v16 (btmon-diffed, fail vs success): the host-initiated bond is usually
#  TEMPORARY — BlueZ answers SSP with "No Bonding" and actively unpairs at
#  the drop (MGMT Unpair Device on the wire). The PERMANENT bond is the one
#  the PAD creates when it re-connects after a PS tap (it requests General
#  Bonding). Pairing no longer bails on the throwaway bond's death — it
#  opens the tap-PS window and waits for the pad-made bond instead, and the
#  pair pipe registers an agent first. This is also why the tile always
#  "worked": its real bonding happened pad-initiated, out of sight.
#  v17 (btmon-verified race): pairable must stay ON until the pad is
#  CONNECTED **and** BONDED — the pad's re-pair request arrives ~2 s after
#  its connect, and closing pairable on 'Connected' alone rejects it with
#  "Pairing Not Allowed (0x18)": unbonded link, no encryption, no HID.
#  Both pairing paths now wait for Paired: yes (50 s window).
#  v21: questions RESTORED (v20 overcorrected — auto-removing all bonds is
#  wrong when pairing a SECOND pad), but made terminal-proof: every prompt
#  is printed with echo (visible with or without a TTY, one-shot ssh too)
#  and every read has a timeout (60 s questions / 30 s bond removal / 15 s
#  press-Enter), so the script can never wait invisibly again. Timeout =
#  same default as pressing Enter — except bond removal, which defaults to
#  the non-destructive "keep".
#  v20: root cause of "the script does nothing over one-shot ssh": read -p
#  only DISPLAYS its prompt when stdin is a terminal — over ssh host "cmd"
#  the script was waiting for input at an invisible prompt and only looked
#  dead.
#  v19 (btmon full timeline, interactive-success capture): the throwaway
#  bond is UNIVERSAL — even a perfect interactive pairing answers SSP with
#  "No Bonding" and the daemon unpairs at the drop (MGMT Unpair Device).
#  The pad then reconnects BY ITSELF: knock #1 ~+5 s is ALWAYS rejected
#  ("Pairing Not Allowed") because the daemon needs ~8 s to restore
#  pairable after Pair Device unwinds; the pad's own retry ~+11 s lands the
#  permanent General-Bonding bond. A PS tap is only the FALLBACK for a pad
#  that burned its retries and went dark — ritual texts rewritten to match
#  the wire (watch first, tap only if dark). The tile now narrates to
#  stdout too, so runs launched over SSH guide themselves in one window.
#  v18: USB-assisted-pairing theory RETRACTED (user-confirmed: the tile
#  succeeds over pure Bluetooth, pad never on USB in CachyOS). A line-by-line
#  diff of tile vs script shows every BT-relevant command is now IDENTICAL —
#  so the remaining difference must be run-time STATE, not code. Two changes
#  follow from that: (1) do_pairing now restarts bluetoothd first, clearing
#  stale state from dozens of pair/remove cycles in long-lived sessions (the
#  tile's successes cluster on fresh boots); (2) BOTH paths capture a btmon
#  trace of the bonding window — /tmp/pair-trace.btsnoop (script) and
#  /tmp/tile-trace.btsnoop (tile) — so a failure can be diffed against a
#  success packet-by-packet instead of argued about. Also: explicit pad
#  ritual block, live nudges inside a 100 s window, pairable only closes on
#  success (a late knock can no longer be rejected).
#  v22 (btmon A/B, failed-script vs success-tile trace, SAME boot/pad):
#  THE tile-vs-script root cause found. At 'pair' time the tile's adapter
#  was pairable (MGMT settings 0x00400ad1) and BlueZ answered the pad's
#  SSP request with "Dedicated Bonding (0x03)" -> PERMANENT bond on the
#  first try, no dance. The script's adapter was NOT pairable
#  (0x00400ac1 — the early 'pairable on' had silently worn off ~30 s
#  later during the prompts + scan) -> BlueZ answered "No Bonding (0x01)"
#  -> throwaway key, deleted at the drop, and all three pad re-knocks
#  were rejected "Pairing Not Allowed (0x18)". Both paths issued
#  byte-identical Pair Device commands — the ONLY difference was the
#  bondable bit at pair time. Fix: PairableTimeout=0 enforced in
#  main.conf + 'pairable on' re-issued INSIDE the pair pipe 1 s before
#  'pair' (script and tile). Also: auto-revive of the wedged IW620 BT
#  side after warm reboots (btusb reload) before giving up.
#  v24: NetworkManager boot-skip turned out to be intermittent on warm
#  boots too — re-asserting NM at script run time can't fix a boot that
#  never pulls it in. Now installs nm-ensure.service, a oneshot watchdog
#  (WantedBy multi-user + graphical targets) that force-starts NM at
#  every boot; the immediate enable --now stays for the current session.
#  v23 (same-session A/B on a cold boot, tile SUCCESS vs script FAIL):
#  the v22 pipe's 'pairable on' was REJECTED by the daemon — "Failed to
#  set pairable on: org.bluez.Error.Busy" in bt-pair.out — so pairable was
#  STILL off at 'pair' and the pad again got "No Bonding (0x01)" ->
#  throwaway -> 0x18 storm, while the tile's pipe the same minute got
#  "Dedicated Bonding (0x03)" and bonded permanently. Root cause of the
#  whole saga: pairable is best-effort — it can be flipped off by daemon
#  churn after disconnect/remove and SetPairable can be refused while the
#  daemon settles. Never ASSUME it: both paths now SET + VERIFY pairable
#  in a 20 s retry loop immediately before 'pair' (aborting with a clear
#  re-run message if the daemon stays Busy) and re-assert it after the
#  pair pipe exits so the re-knock window stays open.
#  v21: all prompts visible without a TTY (echo + read -t), bond removal
#  asks again (non-destructive default) — v20's auto-remove could eat a
#  second pad's bond.
#  Interactive: opinionated steps ask [Y/n] (Enter = default).
#  Core system steps always run (BT stack, Wi-Fi driver, ps5-linux-tools,
#  SSH, session machinery); app choices (keymap, screensaver, Firefox,
#  app deps, Steam autostart, 1080p, pairing, desktop test) are prompted.
# ==========================================================
exec > >(tee ~/ps5-final.log) 2>&1
say(){ echo; echo "================  $*  ================"; }

do_pairing(){
  MAC_RE='([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}'
  if [ -d /sys/class/bluetooth/hci1 ]; then
    echo "WARNING: phantom hci1 is active — this kernel still double-binds the BT chip."
    echo "Pairing on the polluted adapter is unreliable. Best: reboot (udev rule),"
    echo "then run: bash ~/ps5-final.sh pair     — continuing anyway in 5 s..."
    sleep 5
  fi
  sudo rfkill unblock bluetooth
  sudo modprobe hidp 2>/dev/null  # BT HID transport: first pad connect after boot drops without it
  # Start from a KNOWN-CLEAN daemon: tile successes cluster on fresh boots,
  # while script failures happen in long-lived bluetoothd sessions after many
  # pair/remove/unpair cycles. A restart clears any stale device state —
  # removing the last uncontrolled state variable between the two paths.
  sudo systemctl restart bluetooth; sleep 2
  bluetoothctl power on >/dev/null 2>&1; sleep 1
  if ! bluetoothctl show | grep -q "Powered: yes"; then
    # IW620 combo chip: the BT side wedges after a WARM reboot (hci tx
    # timeout in dmesg) while Wi-Fi keeps working. Reloading btusb revives
    # it without a cold boot (user-confirmed fix).
    echo "Adapter did not come up — reloading the BT driver (btusb) to revive"
    echo "the wedged IW620 bluetooth side (known warm-reboot issue)..."
    sudo systemctl stop bluetooth
    sudo modprobe -r btusb 2>/dev/null; sleep 3
    sudo modprobe btusb; sleep 3
    sudo systemctl start bluetooth; sleep 2
    bluetoothctl power on >/dev/null 2>&1; sleep 1
  fi
  if ! bluetoothctl show | grep -q "Powered: yes"; then
    echo "ADAPTER STILL NOT UP — the chip needs a COLD boot: power off and"
    echo "re-run the payload from the PS5 menu (a warm reboot does NOT reset it)."
    echo "Diagnostics:"; rfkill list
    sudo dmesg | grep -iE 'bluetooth|btusb|hci' | tail -25
    return 1
  fi
  # DualSense pairing dance (packet-verified): ~1.5 s after the first pairing
  # the pad RE-PAIRS ("repairing") to upgrade its link key. Two things must
  # hold or BlueZ rejects that round and the bond self-destructs:
  #   1. adapter stays PAIRABLE through the whole dance
  #   2. BlueZ policy JustWorksRepairing=always
  # main.conf policy (btmon root-cause, v22): BOTH settings below are
  # required, and BOTH survive only if enforced here:
  #   JustWorksRepairing=always — the pad re-pairs ~1.5 s after pairing to
  #     upgrade its link key; the default policy rejects that round.
  #   PairableTimeout=0 — the REAL tile-vs-script difference: 'pairable on'
  #     silently wears off (~30 s timeout). The tile pairs ~22 s after its
  #     pairable-on (still alive -> Dedicated Bonding -> PERMANENT bond);
  #     the script's prompts + scan take 40-60 s, so by 'pair' the adapter
  #     was NOT pairable -> BlueZ answers SSP with "No Bonding" (0x01) ->
  #     throwaway key, deleted at the drop, and every pad re-knock gets
  #     "Pairing Not Allowed (0x18)". 0 = stay pairable until WE say off.
  BTL_CHANGED=0
  if ! grep -q '^JustWorksRepairing=always' /etc/bluetooth/main.conf 2>/dev/null; then
    grep -q '^JustWorksRepairing' /etc/bluetooth/main.conf 2>/dev/null || \
      sudo sed -i '/^\[General\]/a JustWorksRepairing=always' /etc/bluetooth/main.conf
    sudo sed -i 's/^#\?JustWorksRepairing=.*/JustWorksRepairing=always/' /etc/bluetooth/main.conf
    BTL_CHANGED=1
  fi
  if ! grep -q '^PairableTimeout=0' /etc/bluetooth/main.conf 2>/dev/null; then
    grep -q '^PairableTimeout' /etc/bluetooth/main.conf 2>/dev/null || \
      sudo sed -i '/^\[General\]/a PairableTimeout=0' /etc/bluetooth/main.conf
    sudo sed -i 's/^#\?PairableTimeout=.*/PairableTimeout=0/' /etc/bluetooth/main.conf
    BTL_CHANGED=1
  fi
  if [ $BTL_CHANGED -eq 1 ]; then
    echo "BlueZ policy set (JustWorksRepairing=always, PairableTimeout=0)..."
    sudo systemctl restart bluetooth; sleep 2
    bluetoothctl power on >/dev/null 2>&1
  fi
  bluetoothctl pairable on >/dev/null
  EXISTING=$(bluetoothctl devices | awk '/Wireless Controller|DualSense/{print $2}')
  if [ -n "$EXISTING" ]; then
    echo "Known controllers on this system:"
    bluetoothctl devices | grep -iE 'Wireless Controller|DualSense'
    echo "Remove these bonds before pairing? [y/n] (default: keep)"
    echo "  y = re-pairing the SAME pad cleanly (stale pad-side state kills"
    echo "      the dance; a still-CONNECTED pad ignores PS+Create)"
    echo "  n = pairing a SECOND pad (keeps the first pad's bond!)"
    read -t 30 RM || true
    if [[ "$RM" =~ ^[Yy]$ ]]; then
      # disconnect BEFORE remove: a still-connected pad keeps its link up,
      # and a connected DualSense IGNORES PS+Create (never enters pairing
      # mode — every later 'pair' then fails for no visible reason).
      { for M in $EXISTING; do echo "disconnect $M"; sleep 1; echo "remove $M"; sleep 2; done; echo "quit"; } | bluetoothctl
      for M in $EXISTING; do
        if bluetoothctl devices 2>/dev/null | grep -q "$M"; then
          echo "WARNING: bond $M still present — retrying removal..."
          { echo "remove $M"; sleep 2; echo "quit"; } | bluetoothctl
        fi
      done
    else
      echo "Keeping existing bonds."
    fi
  fi
  echo "0) If the pad is CONNECTED right now (solid light bar): hold PS ~10 s"
  echo "   until the light goes DARK — a connected pad ignores PS+Create."
  echo "1) PAPERCLIP-reset the pad (small hole on the back, ~3 s) — this clears"
  echo "   old bonds on the PAD side; a stale pad-side bond kills the dance."
  echo "2) Then hold PS + Create until the light bar double-blinks rapidly."
  echo "Press Enter while it blinks (auto-continues in 15 s):"
  read -t 15 || true
  { echo "scan on"; sleep 10; echo "scan off"; echo "quit"; } | bluetoothctl | tee /tmp/bt-scan.out >/dev/null
  MAC=$(grep -iE 'DualSense|Wireless Controller' /tmp/bt-scan.out | grep -oE "$MAC_RE" | head -1)
  [ -z "$MAC" ] && MAC=$(bluetoothctl devices | awk '/Wireless Controller|DualSense/{print $2}' | head -1)
  [ -z "$MAC" ] && { echo "No DualSense seen — retry and be quicker."; bluetoothctl pairable off >/dev/null; return 1; }
  echo "Found: $MAC — pairing (keep it blinking)..."
  # 'pairable' is THE make-or-break bit: whenever it is off at pair time,
  # BlueZ answers the pad's SSP request with "No Bonding (0x01)" — a throwaway
  # key deleted at the drop, after which every pad re-knock is rejected
  # "Pairing Not Allowed (0x18)". It can be silently flipped off by daemon
  # churn after the disconnect/removal above, and SetPairable can be REJECTED
  # outright ("Failed to set pairable on: org.bluez.Error.Busy") while the
  # daemon is still settling (both btmon/ bt-pair.out verified, same-session
  # A/B vs the tile). So don't ASSUME pairable — set it, VERIFY it, retry
  # while the daemon settles, and refuse to pair until it is confirmed.
  PAIRABLE_OK=0
  for t in $(seq 1 20); do
    bluetoothctl pairable on >/dev/null 2>&1
    bluetoothctl show 2>/dev/null | grep -q "Pairable: yes" && { PAIRABLE_OK=1; break; }
    sleep 1
  done
  if [ $PAIRABLE_OK -eq 0 ]; then
    echo "Adapter still refuses pairable (Busy) after 20 s — the daemon is"
    echo "stuck mid-operation. Wait ~10 s and re-run: bash ~/ps5-final.sh pair"
    return 1
  fi
  echo "Adapter pairable confirmed."
  # Self-documenting run: capture a packet trace of the whole bonding window.
  # If this attempt fails, the trace can be diffed against the working tile
  # trace packet-by-packet — no guessing about light-bar colors after the fact.
  sudo sh -c 'exec btmon -w /tmp/pair-trace.btsnoop' >/dev/null 2>&1 &
  TRACE_PID=$!
  # 'agent on' first: pairing with no agent registered yet makes BlueZ answer
  # the SSP request with "No Bonding" — a THROWAWAY key it deletes at the drop.
  # 'pairable on' AGAIN inside this pipe, 1 s before 'pair' (btmon root-cause,
  # v22): pairable wears off ~30 s after being set, so the early pairable-on
  # was already dead by this point in slow runs — the pair then negotiated
  # "No Bonding (0x01)" (throwaway) instead of "Dedicated Bonding (0x03)"
  # (permanent). Fresh pairable HERE makes the FIRST bond permanent and the
  # whole re-knock dance below usually unnecessary.
  { echo "agent on"; echo "pairable on"; sleep 1; echo "pair $MAC"; sleep 2; echo "trust $MAC"; sleep 8; echo "quit"; } | bluetoothctl > /tmp/bt-pair.out 2>&1
  # The pipe's bluetoothctl session just exited — re-assert pairable so the
  # pad's re-knocks during the window below find it ON even if the session's
  # exit reset it (the fallback path still needs it).
  bluetoothctl pairable on >/dev/null 2>&1
  # Packet-verified (btmon, BlueZ 5.87): the host-initiated bond is often
  # TEMPORARY — the daemon sends MGMT Unpair Device at the drop seconds later.
  # That drop + "Paired: no" is EXPECTED, not a failure. The PERMANENT bond is
  # created when the PAD re-connects itself (it requests General Bonding) —
  # so we do NOT judge yet; we open the tap-PS window first.
  echo "Pairing round done. With pairable fresh at pair time (v22) the first"
  echo "bond is usually PERMANENT already — expect the light bar to go SOLID"
  echo "within ~15 s. If the link drops and 'Paired: no' flashes by, that was"
  echo "the old throwaway path — the pad then re-connects by itself below."
  echo
  echo "================  WHAT TO EXPECT (packet-verified)  ================"
  echo " WATCH the pad — most v22 runs: brief pulse, then SOLID, done."
  echo " Fallback (throwaway path): the pad auto-retries ~5 s and ~11 s after"
  echo " a drop and lands the permanent bond on a retry — still no tap needed."
  echo " Only if the bar is still DARK after ~20 s: tap PS ONCE (short press)."
  echo " If it is still double-blinking, press PS once first to leave pairing"
  echo " mode — a tap while it blinks is absorbed. Never 'bluetoothctl"
  echo " connect' or KDE's Connect button — they can never work."
  echo "===================================================================="
  echo "Watching for the pad to connect AND bond (up to 100 s)..."
  # pairable must stay ON until the BOND exists: the pad's re-pair request
  # arrives ~2 s AFTER it connects (btmon-verified) — closing pairable on
  # 'Connected: yes' alone rejects the re-pair ("Pairing Not Allowed"),
  # leaving an unbonded connection with no encrypted HID channel.
  OK=0
  for i in $(seq 1 50); do
    sleep 2
    INFO=$(bluetoothctl info $MAC)
    if echo "$INFO" | grep -q "Connected: yes" && echo "$INFO" | grep -q "Paired: yes"; then OK=1; break; fi
    case $i in
      10|25|40) echo "  ($((i*2)) s) no connection yet — light bar dark? tap PS ONCE now. Still blinking? press PS to cancel pairing mode, then tap once.";;
    esac
  done
  sudo kill $TRACE_PID 2>/dev/null
  if [ $OK -eq 1 ]; then
    bluetoothctl pairable off >/dev/null
  else
    echo "(Leaving the adapter pairable — the pad can still bond late."
    echo " Check any time with: bluetoothctl info $MAC)"
  fi
  echo "$INFO" | grep -E 'Paired|Trusted|Connected|ServicesResolved'
  if [ $OK -eq 1 ]; then
    bluetoothctl trust $MAC >/dev/null 2>&1   # the permanent bond is pad-made; make sure it's trusted
    sleep 2   # encryption comes up with the bond; HID input devices attach
    if grep -qiE 'DualSense|Wireless Controller' /proc/bus/input/devices; then
      echo "FULL SUCCESS — DualSense paired, bonded, input device live (js/event)."
    else
      echo "Bonded + connected — input device not listed yet; tap PS once more."
    fi
  elif echo "$INFO" | grep -q "Connected: yes"; then
    echo "Connected but NOT bonded — the pad's re-pair didn't land in time."
    echo "Just re-run: bash ~/ps5-final.sh pair (the window is now 50 s and"
    echo "waits for the bond — a second run practically always lands it)."
  elif echo "$INFO" | grep -q "Paired: yes"; then
    echo "Bond stored but the pad isn't connected — tap PS once (short press)."
    echo "Do NOT use 'bluetoothctl connect' or the KDE Connect button."
  else
    echo "Pairing failed — last bluetoothctl output:"
    tail -15 /tmp/bt-pair.out
    echo "---"
    echo "Most common cause: the PS tap never landed — the pad was still"
    echo "double-blinking (pairing mode absorbs the tap) or had gone dark and"
    echo "nobody tapped. Re-run and follow the PAD RITUAL block with the pad"
    echo "in your hands: cancel blinking with one PS press, wait for dark, one tap."
    echo "A packet trace of this attempt was saved: /tmp/pair-trace.btsnoop"
    echo "  (from Windows: scp steam@<ps5-ip>:/tmp/pair-trace.btsnoop . )"
    echo "Diagnostics: sudo dmesg | grep -iE 'bluetooth|btusb|hci' | tail -25"
    return 1
  fi
}

# ---- pairing-only mode:  ~/ps5-final.sh pair ----
if [ "${1:-}" = "pair" ]; then
  say "DualSense pairing (standalone)"
  do_pairing
  exit 0
fi

say "1/15 Internet check + Wi-Fi setup"
# NM is 'enabled' but intermittently NEVER STARTS at boot (zero NM lines in
# the journal until started by hand — observed on cold AND warm boots; the
# boot transaction sometimes just doesn't pull it in). Two layers:
#  1. re-assert + start it NOW (fixes the current session immediately)
#  2. a tiny watchdog unit that force-starts NM at EVERY boot, hooked into
#     both multi-user and graphical targets so no boot path can skip it
sudo systemctl enable --now NetworkManager 2>/dev/null || true
sudo tee /etc/systemd/system/nm-ensure.service >/dev/null <<'NMEOF'
[Unit]
Description=Ensure NetworkManager is running (works around intermittent boot skip)
After=dbus.service
Wants=dbus.service

[Service]
Type=oneshot
ExecStart=/usr/bin/sh -c '/usr/bin/systemctl is-active --quiet NetworkManager || /usr/bin/systemctl start NetworkManager'
TimeoutStartSec=30

[Install]
WantedBy=multi-user.target
WantedBy=graphical.target
NMEOF
sudo systemctl daemon-reload
sudo systemctl enable nm-ensure.service 2>/dev/null && echo "NM boot watchdog installed (nm-ensure.service)"
if curl -sfI -m 5 https://archlinux.org -o /dev/null 2>&1; then
  echo "online"
else
  echo "NO INTERNET yet — if this box is Wi-Fi only, let's connect now."
  echo "Set up Wi-Fi? [Y/n]:"; read -t 60 WF || true
  if [[ ! "$WF" =~ ^[Nn]$ ]]; then
    nmcli device wifi list
    echo "SSID (exact spelling):"; read WSSID || true
    echo "Wi-Fi password (typing is hidden):"; read -s WPASS || true; echo
    sudo nmcli device wifi connect "$WSSID" password "$WPASS" || {
      echo "retrying: removing stale profile for '$WSSID' (GUI/KWallet-backed profiles break this)"
      sudo nmcli connection delete id "$WSSID" 2>/dev/null
      sudo nmcli device wifi connect "$WSSID" password "$WPASS"
    }
  fi
  curl -sfI -m 5 https://archlinux.org -o /dev/null 2>&1 && echo "online" \
    || { echo "STILL OFFLINE — plug in Ethernet (or fix Wi-Fi) and re-run."; exit 1; }
fi
# optional: save Wi-Fi as a SYSTEM connection (auto-connect at boot, no KWallet
# prompts — the desktop applet stores secrets in KWallet and nags; nmcli doesn't)
if nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null | grep -q ':wifi:disconnected'; then
  echo "Save your Wi-Fi for cable-free use (auto-connect at boot)? [y/N]:"; read -t 60 WF2 || true
  if [[ "$WF2" =~ ^[Yy]$ ]]; then
    nmcli device wifi list
    echo "SSID (exact spelling):"; read WSSID2 || true
    echo "Wi-Fi password (typing is hidden):"; read -s WPASS2 || true; echo
    if ! sudo nmcli device wifi connect "$WSSID2" password "$WPASS2"; then
      echo "retrying: removing stale profile for '$WSSID2' (GUI/KWallet-backed profiles break this)"
      sudo nmcli connection delete id "$WSSID2" 2>/dev/null
      sudo nmcli device wifi connect "$WSSID2" password "$WPASS2" \
        && echo "Wi-Fi saved system-wide — auto-connects at boot, no wallet prompts"
    else
      echo "Wi-Fi saved system-wide — auto-connects at boot, no wallet prompts"
    fi
  fi
fi

say "2/15 System update (rolling-release sync)"
echo "The image is a rolling release and may be weeks old. Installing NEW packages"
echo "onto an OLD base breaks them (real case: firefox needs GLIBC_2.44, the image"
echo "shipped an older glibc -> 'Couldn't load XPCOM'). A full upgrade first avoids"
echo "this whole class of breakage."
echo "Run a full system upgrade now (pacman -Syu, can take a while)? [Y/n]:"; read -t 60 UP || true
if [[ ! "$UP" =~ ^[Nn]$ ]]; then
  sudo pacman -Syu --noconfirm && echo "system upgraded — reboot after this script is a good idea"
else
  echo "skipped — note: freshly installed apps may fail with GLIBC version errors"
fi

say "3/15 Keyboard layout"
while true; do
  echo "Console keymap [de]:"; read -t 60 KM || true
  KM=${KM:-de}
  if sudo localectl set-keymap "$KM" 2>/dev/null; then break; fi
  echo "Keymap '$KM' is not available — try again (Enter = de)."
done
localectl | grep -i keymap || true

say "4/15 Quiet kernel console spam"
echo 'kernel.printk = 3 4 1 3' | sudo tee /etc/sysctl.d/20-quiet-printk.conf
sudo sysctl -p /etc/sysctl.d/20-quiet-printk.conf

say "5/15 Bluetooth kernel fixes (hid-playstation + phantom-interface rule)"
# v10: NO ERTM/SC hacks — both break the DualSense's HID channel.
# Clean up relics from older script versions:
sudo rm -f /etc/modprobe.d/bluetooth-ertm.conf
echo 0 | sudo tee /sys/module/bluetooth/parameters/disable_ertm 2>/dev/null || true
sudo systemctl disable bt-sc-off.service 2>/dev/null
sudo rm -f /etc/systemd/system/bt-sc-off.service
sudo systemctl disable ps5-bt-quiet.service 2>/dev/null   # v7-era phantom-hci1 workaround,
sudo rm -f /etc/systemd/system/ps5-bt-quiet.service /usr/local/sbin/ps5-bt-quiet
sudo btmgmt --index 0 power off 2>/dev/null; sudo btmgmt --index 0 sc on 2>/dev/null
sudo btmgmt --index 0 ssp on 2>/dev/null; sudo btmgmt --index 0 power on 2>/dev/null
# Kernel HID driver for the DualSense:
echo 'hid-playstation' | sudo tee /etc/modules-load.d/hid-playstation.conf
sudo modprobe hid-playstation && echo "hid-playstation loaded"
# hidp = kernel BT-HID transport (UserspaceHID=false on this image). Without it
# loaded at boot, the FIRST pad-initiated connect after boot drops once.
echo 'hidp' | sudo tee /etc/modules-load.d/hidp.conf
sudo modprobe hidp && echo "hidp loaded (first PS-tap after boot now sticks)"
# The internal Marvell 1286:2059 exposes a second BT interface (5-1:1.2);
# btusb binding it creates a phantom hci1 that breaks pairing. Block it:
cat <<'RULE' | sudo tee /etc/udev/rules.d/99-ps5-bt-no-phantom.rules
# PS5 internal BT (Marvell 1286:2059): keep btusb off interface 1.2 -
# it registers a phantom second HCI controller that breaks pairing.
ACTION=="add", SUBSYSTEM=="usb", ATTRS{idVendor}=="1286", ATTRS{idProduct}=="2059", ATTR{bInterfaceNumber}=="02", ATTR{authorized}="0"
RULE
sudo udevadm control --reload && echo "phantom-interface udev rule installed"
if [ -d /sys/class/bluetooth/hci1 ]; then
  echo "NOTE: phantom hci1 is present NOW — this kernel lacks the upstream quirk (PR #19)."
  echo "      The rule takes effect from next boot; pair controllers after a reboot."
else
  echo "hci0 only — clean (fixed kernel, or rule already active)"
fi

say "6/15 SSH server"
sudo systemctl enable --now sshd 2>/dev/null && echo "sshd active"
echo "Install an SSH public key for password-less login from your PC? [y/N]:"
read -t 60 SK || true
if [[ "$SK" =~ ^[Yy]$ ]]; then
  echo "Paste the full PUBLIC key line (starts with ssh-ed25519 / ssh-rsa), then Enter:"
  read PUBKEY || true
  if [[ "$PUBKEY" =~ ^ssh-(ed25519|rsa|ecdsa)[[:space:]] ]]; then
    mkdir -p ~/.ssh && chmod 700 ~/.ssh
    touch ~/.ssh/authorized_keys
    grep -qF "$PUBKEY" ~/.ssh/authorized_keys || echo "$PUBKEY" >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
    echo "Key installed — password-less SSH from that PC should work now."
  else
    echo "That did not look like a public key — skipping (re-run the script to retry)."
  fi
fi

say "7/15 Stock BlueZ + kernel HID path (hidp, NOT userspace)"
sudo sed -i 's/^IgnorePkg.*/#IgnorePkg   =/' /etc/pacman.conf
sudo pacman -S --noconfirm bluez bluez-libs bluez-utils
# v10: UserspaceHID=false — the userspace uhid path never created an input
# device; kernel hidp + hid-playstation registers the DualSense properly.
if grep -q '^#\?UserspaceHID=' /etc/bluetooth/input.conf 2>/dev/null; then
  sudo sed -i 's/^#\?UserspaceHID=.*/UserspaceHID=false/' /etc/bluetooth/input.conf
else
  echo 'UserspaceHID=false' | sudo tee -a /etc/bluetooth/input.conf
fi
grep UserspaceHID /etc/bluetooth/input.conf
# JustWorksRepairing=always — the DualSense re-pairs ("repairs") ~1.5 s after
# the first pairing to upgrade its link key. The default policy rejects that
# round -> the bond self-destructs 1 s after "Pairing successful" and every
# later connect dies ("Connection terminated by local host" /
# br-connection-key-missing). This policy is THE fix (packet-verified).
if ! grep -q '^JustWorksRepairing=' /etc/bluetooth/main.conf 2>/dev/null; then
  sudo sed -i '/^\[General\]/a JustWorksRepairing=always' /etc/bluetooth/main.conf
else
  sudo sed -i 's/^#\?JustWorksRepairing=.*/JustWorksRepairing=always/' /etc/bluetooth/main.conf
fi
grep JustWorksRepairing /etc/bluetooth/main.conf
sudo systemctl restart bluetooth
sleep 2
bluetoothctl --version

say "8/15 NXP mwifiex driver + combo firmware (LONG on first run)"
if [ -f /lib/firmware/nxp/pcieuartiw620_combo_v1.bin ] && [ -d "/lib/modules/$(uname -r)/extra/ps5-iw620" ]; then
  echo "firmware + modules already present — skipping"
else
  sudo pacman -Sy --needed --noconfirm git base-devel bc
  cd ~ && rm -rf ps5-linux-mwifiex
  git clone https://github.com/ps5-linux/ps5-linux-mwifiex
  cd ps5-linux-mwifiex && sudo ./install.sh && cd ~
fi

say "9/15 ps5-linux-tools (fan + boost automatically at boot)"
if systemctl is-enabled ps5fan.service >/dev/null 2>&1; then
  echo "already installed — skipping"
else
  # -Sy first: a fresh image ships a stale package DB -> 404s on moved packages
  sudo pacman -Sy --needed --noconfirm git base-devel zlib
  cd ~ && rm -rf ps5-linux-tools
  if git clone https://github.com/ps5-linux/ps5-linux-tools; then
    cd ps5-linux-tools && make && sudo ./install.sh && cd ~
  else
    echo "WARN: clone/build failed — ps5-linux-tools NOT installed."
    echo "      fix: sudo pacman -Sy   then re-run this script (it is idempotent)."
  fi
fi

say "10/15 Helper scripts"
cat > ~/switch-to-desktop.sh <<'H1'
#!/bin/bash
# Switch to Desktop v7 - soft switch, zombie-proof, no watchdog
# If you ever black-screen after switching: run ~/rescue-gaming.sh from SSH

sudo systemctl stop session-rollback.timer session-rollback.service ps5-desktop-switch.service 2>/dev/null

sudo systemd-run --unit=ps5-desktop-switch --collect bash -c '
  echo plasmax11 > /home/steam/.config/ps5-next-session
  pkill kwin_wayland 2>/dev/null
  pkill plasmashell 2>/dev/null
  pkill Xorg 2>/dev/null
  sleep 2
  pkill gamescope 2>/dev/null
  pkill -f "g[a]mescope" 2>/dev/null
  sleep 3
  systemctl restart getty@tty1.service
' >/dev/null 2>&1

echo "switching to desktop..."
H1
chmod +x ~/switch-to-desktop.sh
cat > ~/rescue-gaming.sh <<'H2'
#!/bin/bash
# Emergency return to gaming mode - run this from SSH if a desktop switch black-screens
echo gamescope > /home/steam/.config/ps5-next-session
sudo systemctl restart getty@tty1.service
H2
chmod +x ~/rescue-gaming.sh
cat > ~/boost-on.sh <<'H3'
#!/bin/bash
sudo /usr/local/sbin/ps5_control --fan on
sudo /usr/local/sbin/ps5_control --boost on
H3
chmod +x ~/boost-on.sh
{ echo '#!/bin/bash'; declare -f say do_pairing; echo 'do_pairing'; } > ~/pair-dualsense.sh
chmod +x ~/pair-dualsense.sh
cat > ~/pair-dualsense-tile.sh <<'H5'
#!/bin/bash
# pair-dualsense-tile.sh — non-interactive DualSense re-pairing ritual.
# Use when the pad lost its bond (after PS5 OS use, or pairing to another
# host). Launch from the desktop icon or the Steam "Pair DualSense" tile.
# The pad works WIRED meanwhile: plug it in via USB to navigate, run this,
# unplug when it says SUCCESS.
# Feedback: zenity timed popups (visible in the gamescope gaming session —
# kdialog's passivepopup needs Plasma, which only exists on the desktop),
# plus /tmp/pair-tile.log — tail that via SSH if no popup ever shows.
LOG=/tmp/pair-tile.log; : > "$LOG"
notify(){
  echo ">> $1" | tee -a "$LOG"   # stdout too: runs launched over SSH narrate themselves
  if command -v zenity >/dev/null; then
    zenity --info --title "DualSense Pairing" --text "$1" --timeout "${2:-10}" >/dev/null 2>&1 &
  else
    kdialog --title "DualSense Pairing" --passivepopup "$1" "${2:-10}" >/dev/null 2>&1 &
  fi
}

# BlueZ repairing policy (idempotent; the DualSense re-pairs ~1.5 s after
# pairing to upgrade its link key — default policy rejects that round)
BTL_CHANGED=0
if ! grep -q '^JustWorksRepairing=always' /etc/bluetooth/main.conf 2>/dev/null; then
  grep -q '^JustWorksRepairing' /etc/bluetooth/main.conf 2>/dev/null || \
    sudo -n sed -i '/^\[General\]/a JustWorksRepairing=always' /etc/bluetooth/main.conf
  sudo -n sed -i 's/^#\?JustWorksRepairing=.*/JustWorksRepairing=always/' /etc/bluetooth/main.conf
  BTL_CHANGED=1
fi
# PairableTimeout=0: pairable must not self-expire (~30 s default) — an
# expired pairable at 'pair' time yields a throwaway No-Bonding key (0x01)
# instead of a permanent Dedicated-Bonding one (0x03). btmon root-cause.
if ! grep -q '^PairableTimeout=0' /etc/bluetooth/main.conf 2>/dev/null; then
  grep -q '^PairableTimeout' /etc/bluetooth/main.conf 2>/dev/null || \
    sudo -n sed -i '/^\[General\]/a PairableTimeout=0' /etc/bluetooth/main.conf
  sudo -n sed -i 's/^#\?PairableTimeout=.*/PairableTimeout=0/' /etc/bluetooth/main.conf
  BTL_CHANGED=1
fi
if [ $BTL_CHANGED -eq 1 ]; then
  sudo -n systemctl restart bluetooth; sleep 2
fi
sudo -n modprobe hidp 2>/dev/null
bluetoothctl pairable on >/dev/null 2>&1

# drop stale bond (pad side was overwritten by the other host anyway) —
# disconnect first: a connected pad ignores PS+Create later on
for M in $(bluetoothctl devices | awk '/Wireless Controller|DualSense/{print $2}'); do
  bluetoothctl disconnect "$M" >/dev/null 2>&1
  bluetoothctl remove "$M" >/dev/null 2>&1
done

notify "PAPERCLIP-reset the pad, then hold PS+Create until it double-blinks. Scanning starts in 12 s..." 12
sleep 12
MAC_RE='([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}'
{ echo "scan on"; sleep 10; echo "scan off"; echo "quit"; } | bluetoothctl > /tmp/bt-tile-scan.out 2>&1
MAC=$(grep -iE 'DualSense|Wireless Controller' /tmp/bt-tile-scan.out | grep -oE "$MAC_RE" | head -1)
[ -z "$MAC" ] && MAC=$(bluetoothctl devices | awk '/Wireless Controller|DualSense/{print $2}' | head -1)
if [ -z "$MAC" ]; then
  bluetoothctl pairable off >/dev/null 2>&1
  notify "FAILED: no DualSense seen — re-run and be quicker with PS+Create." 15
  sleep 16; exit 1
fi

notify "Found $MAC — pairing (keep it blinking)..." 8
# pairable must be CONFIRMED on before 'pair': with it off, BlueZ answers the
# pad "No Bonding" (throwaway key), and SetPairable can be rejected with
# org.bluez.Error.Busy while the daemon settles after removals (verified in
# bt-pair.out/btmon A/B vs the script). Set + verify + retry — never assume.
PAIRABLE_OK=0
for t in $(seq 1 20); do
  bluetoothctl pairable on >/dev/null 2>&1
  bluetoothctl show 2>/dev/null | grep -q "Pairable: yes" && { PAIRABLE_OK=1; break; }
  sleep 1
done
if [ $PAIRABLE_OK -eq 0 ]; then
  notify "FAILED: adapter stuck Busy (refuses pairable) — re-run the tile in ~10 s." 15
  sleep 16; exit 1
fi
# capture the wire too: a tile SUCCESS trace is the reference to diff a
# script FAILURE trace against — packet-by-packet, no theories
sudo -n sh -c 'exec btmon -w /tmp/tile-trace.btsnoop' >/dev/null 2>&1 &
TILE_TRACE=$!
{ echo "agent on"; echo "pairable on"; sleep 1; echo "pair $MAC"; sleep 2; echo "trust $MAC"; sleep 8; echo "quit"; } | bluetoothctl >> "$LOG" 2>&1
bluetoothctl pairable on >/dev/null 2>&1   # pipe session exited; keep the re-knock window open
# btmon-verified: the host-initiated bond is often TEMPORARY (BlueZ deletes
# it at the drop via MGMT Unpair Device). Do NOT judge here — the PERMANENT
# bond forms when the pad re-connects itself after a PS tap. Just wait.
notify "Paired! A short drop now is NORMAL (throwaway bond). The pad usually re-connects BY ITSELF within ~15 s — tap PS once ONLY if it stays dark..." 12
# wait for CONNECTED + BONDED: the re-pair lands ~2 s after the connect —
# closing pairable earlier rejects it ("Pairing Not Allowed", btmon-verified)
OK=0
for i in $(seq 1 25); do
  sleep 2
  INFO=$(bluetoothctl info "$MAC")
  if echo "$INFO" | grep -q "Connected: yes" && echo "$INFO" | grep -q "Paired: yes"; then OK=1; break; fi
done
sudo -n kill $TILE_TRACE 2>/dev/null
bluetoothctl pairable off >/dev/null 2>&1
[ $OK -eq 1 ] && bluetoothctl trust "$MAC" >/dev/null 2>&1

if [ $OK -eq 1 ]; then
  notify "SUCCESS — DualSense bonded and connected (light bar solid). Have fun!" 15
  sleep 16   # keep the script (Steam's "running" state) alive until the popup expires
else
  notify "FAILED to connect — tap PS once more; if it stays dark, re-run. Log: /tmp/pair-tile.log" 15
  sleep 16; exit 1
fi
H5
chmod +x ~/pair-dualsense-tile.sh
mkdir -p ~/.local/share/applications
cat > ~/.local/share/applications/pair-dualsense.desktop <<'H6'
[Desktop Entry]
Name=Pair DualSense (Bluetooth)
Comment=Re-pair the DualSense to internal Bluetooth (after PS5 OS / other host use)
Exec=/home/steam/pair-dualsense-tile.sh
Icon=preferences-system-bluetooth
Terminal=false
Type=Application
Categories=Utility;
H6
update-desktop-database ~/.local/share/applications 2>/dev/null
echo "created: ~/switch-to-desktop.sh, ~/rescue-gaming.sh, ~/boost-on.sh,"
echo "         ~/pair-dualsense.sh, ~/pair-dualsense-tile.sh (+ Pair-DualSense tile)"

say "11/15 Force 1080p output (capture-card setups ONLY)"
cat <<'NOTE'
WHAT THIS IS:
  The image locks the output resolution at BOOT time — Plasma display
  settings cannot change it afterwards. With a directly attached TV or
  monitor, the console reads its EDID and picks the native mode by
  itself. A bare 1080p monitor just works — NO flag needed.

WHEN YOU NEED THIS FLAG (amdgpu.force_1080p=1):
  Only for capture-card setups (Elgato etc.) where NOTHING is plugged
  into the card's HDMI OUT port. With no monitor downstream, the card
  answers with its own fallback EDID, which can advertise modes the
  capture hardware cannot actually encode (commonly: 4K input OK,
  1080p capture max) -> black/unsupported signal in OBS or whatever
  software you preview with. The flag forces 1080p so the card can
  capture it. (With a 1080p monitor on the card's OUT port, the
  console sees the MONITOR's EDID and negotiates 1080p on its own.)

WARNING — THE FLAG IS GLOBAL:
  It applies to EVERY boot and EVERY display until removed. On a
  normal TV/monitor it forces 1080p even if the display can do more.
  Revert at any time:  bash ~/toggle-1080p.sh   (then reboot)
NOTE
for f in /sys/class/drm/card*/status; do echo "$f: $(cat $f 2>/dev/null)"; done
echo "Add amdgpu.force_1080p=1 to cmdline.txt (active from NEXT boot)? [y/N]:"; read -t 60 R1080 || true
if [[ "$R1080" =~ ^[Yy]$ ]]; then
  DONE=""
  for P in $(lsblk -rnpo NAME,FSTYPE | awk '$2=="vfat"{print $1}'); do
    sudo mkdir -p /mnt/ps5efi
    if sudo mount "$P" /mnt/ps5efi 2>/dev/null; then
      if [ -f /mnt/ps5efi/cmdline.txt ]; then
        echo "found cmdline.txt on $P:"; cat /mnt/ps5efi/cmdline.txt
        sudo cp /mnt/ps5efi/cmdline.txt /mnt/ps5efi/cmdline.txt.bak
        if ! grep -q 'amdgpu.force_1080p=1' /mnt/ps5efi/cmdline.txt; then
          sudo sed -i 's/[ \t]*$/ amdgpu.force_1080p=1/' /mnt/ps5efi/cmdline.txt
          echo "patched ->"; cat /mnt/ps5efi/cmdline.txt
        else
          echo "already patched"
        fi
        DONE=1
      fi
      sync; sudo umount /mnt/ps5efi
    fi
    [ -n "$DONE" ] && break
  done
  [ -z "$DONE" ] && echo "cmdline.txt not found — edit it from Windows (FAT32 partition), append: amdgpu.force_1080p=1"
  echo "revert anytime with: bash ~/toggle-1080p.sh (then reboot)"
fi

# toggle helper is installed UNCONDITIONALLY so the flag can always be reverted
cat > ~/toggle-1080p.sh <<'H8'
#!/bin/bash
# Toggle the 1080p boot flag (amdgpu.force_1080p=1) in cmdline.txt.
# Run once to force 1080p on all displays; run again to restore native
# resolution negotiation. Active from the NEXT boot. Usage: bash ~/toggle-1080p.sh
DONE=""
for P in $(lsblk -rnpo NAME,FSTYPE | awk '$2=="vfat"{print $1}'); do
  sudo mkdir -p /mnt/ps5efi
  if sudo mount "$P" /mnt/ps5efi 2>/dev/null; then
    if [ -f /mnt/ps5efi/cmdline.txt ]; then
      if grep -q 'amdgpu.force_1080p=1' /mnt/ps5efi/cmdline.txt; then
        sudo sed -i 's/ *amdgpu\.force_1080p=1//g' /mnt/ps5efi/cmdline.txt
        echo "1080p flag REMOVED ($P) — native resolution from next boot."
      else
        sudo cp /mnt/ps5efi/cmdline.txt /mnt/ps5efi/cmdline.txt.bak
        sudo sed -i 's/[ \t]*$/ amdgpu.force_1080p=1/' /mnt/ps5efi/cmdline.txt
        echo "1080p flag ADDED ($P) — 1080p forced from next boot."
      fi
      echo "cmdline.txt now:"; cat /mnt/ps5efi/cmdline.txt
      DONE=1
    fi
    sync; sudo umount /mnt/ps5efi
  fi
  [ -n "$DONE" ] && break
done
[ -z "$DONE" ] && echo "cmdline.txt not found — edit it from Windows (FAT boot partition): add/remove amdgpu.force_1080p=1"
H8
chmod +x ~/toggle-1080p.sh
echo "helper installed: ~/toggle-1080p.sh (toggles the 1080p flag; reboot to apply)"

say "12/15 Disable screensaver / auto-lock / display sleep"
echo "Disable screensaver/lock/display sleep? [Y/n]:"; read -t 60 SCR || true
if [[ ! "$SCR" =~ ^[Nn]$ ]]; then
KW=$(command -v kwriteconfig6 || command -v kwriteconfig5)
if [ -n "$KW" ]; then
  $KW --file kscreenlockerrc --group Daemon --key Autolock false
  $KW --file kscreenlockerrc --group Daemon --key LockOnResume false
  # Plasma 6: powerdevil reads powerdevilrc (the old Plasma-5
  # powermanagementprofilesrc is IGNORED). -1 = "never"; --notify makes a
  # running desktop pick it up without re-login. All power profiles covered.
  for GRP in AC Battery LowBattery; do
    $KW --file powerdevilrc --notify --group "$GRP" --group Display \
        --key TurnOffDisplayIdleTimeoutSec -1
    $KW --file powerdevilrc --notify --group "$GRP" --group SuspendAndShutdown \
        --key AutoSuspendIdleTimeoutSec -1
  done
  echo "Plasma 6: autolock OFF, lock-on-resume OFF, display sleep OFF + suspend OFF (powerdevilrc)"
else
  echo "kwriteconfig not found (not a Plasma system?)"
fi
cat > ~/.xprofile <<'H5'
xset s off
xset s noblank
xset -dpms
H5
echo "~/.xprofile: xset s off / noblank / -dpms"
grep -q 'setterm -blank 0' ~/.bash_profile 2>/dev/null \
  || echo 'setterm -blank 0 -powerdown 0 2>/dev/null' >> ~/.bash_profile
echo "console blanking disabled via ~/.bash_profile"
else
  echo "skipped"
fi

say "13/15 Firefox browser"
echo "Install Firefox? [Y/n]:"; read -t 60 FF || true
if [[ ! "$FF" =~ ^[Nn]$ ]]; then
  sudo pacman -Sy --needed --noconfirm firefox && echo "firefox installed"
else
  echo "skipped"
fi

say "14/15 Desktop hardening (KWin X11 window manager + NM polkit rule)"
sudo pacman -Sy --needed --noconfirm plasma-x11-session kwin-x11 && echo "kwin-x11 installed"
# polkit: single-user couch console — GUI admin actions (network, mounts,
# power) should not demand a password. Don't use this on multi-user machines.
sudo rm -f /etc/polkit-1/rules.d/49-nm-steam.rules
cat <<'POL' | sudo tee /etc/polkit-1/rules.d/50-steam-console-admin.rules
polkit.addRule(function(action, subject) {
  if (subject.user == "steam") {
    return polkit.Result.YES;
  }
});
POL
echo "polkit: user steam may perform GUI admin actions without password prompts"
# KWallet: with Wi-Fi stored system-wide the wallet only nags to be unlocked
KW=$(command -v kwriteconfig6 || command -v kwriteconfig5)
[ -n "$KW" ] && $KW --file kwalletrc --group Wallet --key Enabled false \
  && echo "KDE Wallet disabled (re-enable: System Settings -> KDE Wallet)"

say "15/15 Session machinery + app dependencies"
echo "Install app deps (zenity for gaming-mode tile popups, Java 17, rsync/jq/xmlstarlet, fuse2 for AppImages, Ark, Kate)? [Y/n]:"; read -t 60 DEPS || true
if [[ ! "$DEPS" =~ ^[Nn]$ ]]; then
  sudo pacman -Sy --needed --noconfirm zenity jre17-openjdk rsync jq xmlstarlet libnewt fuse2 ark kate \
    && echo "deps installed (zenity, Java 17, rsync/jq/xmlstarlet, AppImage FUSE, Ark, Kate)"
else
  echo "skipped"
fi
mkdir -p ~/.local/share/applications
cat > ~/.local/share/applications/switch-to-desktop.desktop <<'H6'
[Desktop Entry]
Type=Application
Name=Switch to Desktop
Comment=Soft-switch from gaming mode to Plasma desktop
Exec=/home/steam/switch-to-desktop.sh
Icon=system-switch-user
Terminal=false
Categories=Utility;
H6
echo "tile entry created (add via Steam -> Add a Non-Steam Game)"
echo "Autostart Steam (tray) on desktop for gamepad-as-mouse? [Y/n]:"; read -t 60 SA || true
if [[ ! "$SA" =~ ^[Nn]$ ]]; then
mkdir -p ~/.config/autostart
cat > ~/.config/autostart/steam.desktop <<'H7'
[Desktop Entry]
Type=Application
Name=Steam (background, controller mouse)
Exec=steam -silent
Icon=steam
Terminal=false
X-GNOME-Autostart-enabled=true
H7
echo "Steam autostart (tray) created — enables gamepad-as-mouse on desktop"
else
  echo "skipped"
fi
cat <<'UNIT2' | sudo tee /etc/systemd/system/ps5-session-default.service
[Unit]
Description=Boot default to gaming mode (reset PS5 session token)
DefaultDependencies=no
After=local-fs.target
Before=getty@tty1.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c '/bin/echo gamescope > /home/steam/.config/ps5-next-session'

[Install]
WantedBy=sysinit.target
UNIT2
sudo systemctl daemon-reload
sudo systemctl enable ps5-session-default.service && echo "boot default: gaming mode"
SS=/usr/bin/steamos-session-select
if [ -f "$SS" ]; then
  [ -f "$SS.bak" ] || sudo cp "$SS" "$SS.bak"
  sudo sed -i 's/next="plasma"/next="plasmax11"/' "$SS"
  grep -c 'plasmax11' "$SS" | xargs echo "steamos-session-select: plasmax11 occurrences:"
else
  echo "steamos-session-select not found — skipping patch"
fi

say "PHASE 2 — DualSense pairing (optional)"
if [ -d /sys/class/bluetooth/hci1 ]; then
  echo "SKIPPED for now: phantom hci1 is still active (the udev rule applies from next boot)."
  echo "Pairing on the polluted adapter is unreliable — REBOOT first, then run:"
  echo "  bash ~/ps5-final.sh pair"
else
  echo "Try pairing the DualSense now? [y/n]:"; read -t 60 P || true
  [[ "$P" =~ ^[Yy]$ ]] && do_pairing
fi

say "PHASE 3 — Desktop mode test (optional)"
echo "Switch to desktop (Plasma) now? [y/n]:"; read -t 60 D || true
[[ "$D" =~ ^[Yy]$ ]] && bash ~/switch-to-desktop.sh

say "ALL DONE"
echo "Full log: ~/ps5-final.log"
echo "Pairing only:     ~/ps5-final.sh pair   (or: ~/pair-dualsense.sh)"
echo "Desktop switch:   tile in Big Picture   (or: ~/switch-to-desktop.sh)"
echo "Emergency rescue: ~/rescue-gaming.sh    (from SSH)"
echo "1080p flag (if chosen) activates after the next boot."
