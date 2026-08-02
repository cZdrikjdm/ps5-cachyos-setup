# ps5-cachyos-setup

One idempotent setup script for a jailbroken PS5 running the **ps5-linux CachyOS gaming image** (gamescope + Steam Big Picture). Run it once after a re-flash and the console comes back fully configured — including fixes for several bugs that are documented nowhere else.

Tested on a PS5 (7.20 jailbreak), kernel 7.1.3.

**This README is written for beginners.** If you have never touched Linux on a PS5 before, start at Part 0 and follow the parts in order. If you know what you're doing, the [Quick reference](#quick-reference-for-experienced-users) is all you need.

> **Reading the commands:** anything in `<angle brackets>` is a placeholder — replace it with your own value, **without** the brackets. Example: `ssh steam@<ip>` becomes `ssh steam@192.168.178.75`. Everything else is typed exactly as shown.

---

## Bugs this repo fixes for you

Each of these cost us hours or days to find. The script handles all of them:

1. **Internal Bluetooth can't pair anything** — the kernel double-binds the BT chip's USB interfaces, creating a phantom second controller (`hci1`) that poisons the real one. Fixed with a udev rule (upstream fixed the same thing in [ps5-linux-patches PR #19](https://github.com/ps5-linux/ps5-linux-patches/pull/19), but widely distributed images still ship kernels without it).
2. **"Pairing successful" → bond deletes itself 1 second later** — two stacked causes. The DualSense re-pairs ~1.5 s after pairing to upgrade its link key ("repairing"; BlueZ's default policy rejects that round). And the one that made this look random for weeks: the adapter's **pairable bit being off at pair time** — BlueZ then answers the pad's SSP request with `No Bonding (0x01)`, a throwaway key deleted at the drop, and every pad re-knock gets `Pairing Not Allowed (0x18)`. Pairable silently wears off (~30 s default timeout, daemon churn after removing an old bond) and `SetPairable` itself can be rejected with `org.bluez.Error.Busy` while the daemon settles. Fixed with `JustWorksRepairing=always`, `PairableTimeout=0`, and a pairing helper that **sets and verifies** pairable right before `pair` (never assumes it).
3. **Widely-circulated "fixes" that actually break the DualSense** — `disable_ertm=1` and `UserspaceHID=true` (from DualShock-3/4-era guides) kill the HID channel. The script removes these relics and restores the stock, working path.
4. **Steam's "Switch to Desktop" menu entry does nothing useful on this image** — replaced by a proper "Switch to Desktop" tile that cleanly kills stale display servers first.
5. **Desktop has no title bars / no Alt-Tab** — Arch no longer installs an X11 window manager by default; the script installs `plasma-x11-session` + `kwin-x11`.
6. **Losing the pad to the PS5 OS** — using the DualSense on the PlayStation OS overwrites its pairing. The "Pair DualSense" tile re-pairs it from the couch, no PC and no keyboard needed (the pad works as a wired USB controller meanwhile).
7. **Bluetooth dead after a warm reboot** — the NXP IW620 combo chip's BT side wedges on *warm* reboots (`hci0: command ... tx timeout` in dmesg) while Wi-Fi keeps working. The script detects a dead adapter and revives it by reloading `btusb`; a cold boot (re-running the payload) always resets it.
8. **No network after boot (intermittent, cold AND warm)** — NetworkManager is `enabled` but the boot transaction sometimes never pulls it in (zero NM lines in the journal until started by hand; LAN *and* Wi-Fi dead). Fixed two ways: the script re-asserts `enable --now` on every run (fixes the current session), and installs `nm-ensure.service` — a boot watchdog hooked into both multi-user and graphical targets that force-starts NM at every boot. Immediate manual fix on an affected boot: `sudo systemctl start NetworkManager`.

**Also included — machinery and options, not bug fixes:** a boot service that makes every cold boot land deterministically in gaming mode (the session tiles rely on it), and optional 1080p output forcing (`amdgpu.force_1080p=1`) — strictly a remedy for capture-card fallback-EDID problems, off by default, revertible at any time with `~/toggle-1080p.sh` (details in Part 4). The image fixes its output resolution at boot time and Plasma cannot change it afterwards — without the flag, you simply get whatever mode your display negotiated at boot.

---

## Part 0 — What you need

- A **jailbreakable PS5** with a working jailbreak/payload chain for your firmware, and the **ps5-linux CachyOS gaming image** downloaded to your PC. The jailbreak itself and booting Linux are documented by the ps5-linux project — that part is outside this repo's scope. This repo picks up at "Linux boots on my PS5".
- A **USB drive/SSD** for the Linux system (big enough for the image you downloaded — check the `.img` size after decompression and use a larger drive).
- A **PC** (Windows, Linux, or macOS — examples below use Windows PowerShell, which has `ssh` and `scp` built in).
- One **USB-C cable** for the DualSense (used during pairing recovery; also needed on the PS5 OS side of a jailbroken console anyway).
- Optional but recommended: a **USB keyboard**, used once during first setup. After this script runs, everything can be done gamepad-only or over SSH.
- Network: **Ethernet** (plug and play) or Wi-Fi.

---

## Part 1 — Flash the image to the USB drive

1. **Verify your download** (PowerShell, in your Downloads folder):

   ```powershell
   Get-FileHash .\<image-file>.xz -Algorithm SHA256
   ```

   Compare the result against the checksum on the image's release page.

   > ⚠️ **Known upstream quirk (August 2026):** the checksums published on the current "latest" image release **do not match the assets actually being served** — verified with two independent downloads from two different sources (byte-identical files, still mismatching the page; the served image is self-consistent and boots fine, the *published sum* is stale). Issue filed with ps5-linux-image. So if your hash doesn't match the page right now, **don't re-download forever and don't assume your image is broken.** What actually validates the image: balenaEtcher decompresses the `.xz` *while flashing* and aborts loudly on a corrupt archive (a bad file can't silently produce a bad drive), and after the first boot `uname -r` shows the kernel version from the release notes (e.g. `7.1.4`). If upstream fixes the checksums one day and yours *still* mismatches — **then** re-download.

2. **Flash** with [balenaEtcher](https://etcher.balena.io/) or Rufus. Both can flash the `.xz` directly (they decompress on the fly).

   > ⚠️ **Triple-check the target disk.** Everything on the selected drive is erased. Unplug any drives you care about before flashing.

3. Optional time-saver: after flashing, Windows may assign a letter to a small FAT partition from the image (it's the boot partition — it contains `cmdline.txt`). If you can open it, **copy `ps5-final.sh` onto it now** — that saves you the file transfer later (Part 3, method B).

---

## Part 2 — Boot and get your bearings

1. Plug the drive into the PS5, run your usual jailbreak → payload chain, and boot Linux.
2. The image boots into **Steam Big Picture** ("gaming mode"). That's normal — there's no desktop visible yet.
3. Get the console online:
   - **Ethernet:** just plug it in.
   - **Wi-Fi:** in Big Picture: Settings → Network, join your network (works with the gamepad) — **or just let the script do it**: step 1 offers to connect and saves Wi-Fi as a *system-wide* connection (auto-connects at boot). This is the better path: it stores the password in NetworkManager itself, so you don't get the repeated KWallet/password prompts that the desktop's network applet causes (the applet keeps secrets in KDE Wallet; a system connection needs no wallet). If a manual `nmcli` connect ever fails with `Secrets were required, but not provided` — an earlier GUI attempt left a KWallet-backed profile; delete it once (`sudo nmcli connection delete "SSID"`) and reconnect (the script does this automatically).
4. **Find the console's IP address** — you'll need it for SSH. Any of these works:
   - Big Picture → Settings → Network → your connection shows the IP, or
   - your router's client list, or
   - from a terminal on the console (see below): `ip -o -4 addr show scope global | awk '{print $2, $4}'`

### Getting a terminal (pick one)

**Method A — keyboard + virtual console (always works):**
Plug a USB keyboard into the PS5 and press **Ctrl+Alt+F3**. You get a text login prompt. Log in as user `steam` (the password is the one from the image's release notes / the one you set — sudo uses the same password). To return to Big Picture later: **Ctrl+Alt+F1**.

**Method B — SSH from your PC:**

```powershell
ssh steam@<ip>
```

The image ships with the SSH server enabled, so this normally works from the first boot (if it ever refuses, fall back to Method A). The setup script also hardens/enables it permanently, so you'll rarely need the keyboard again.

> **Re-flashed after SSH'ing before?** Your PC will refuse with a scary `REMOTE HOST IDENTIFICATION HAS CHANGED!` warning. That's expected — a fresh install generates new SSH host keys, and your PC still remembers the old install's key for that IP. It is *not* an attack (assuming you just re-flashed). Fix once:
>
> ```powershell
> ssh-keygen -R <ip>
> ssh steam@<ip>   # accept the new fingerprint with "yes"
> ```

---

## Part 3 — Get the script onto the console (pick one)

**Method A — USB stick (most foolproof):**

1. On your PC, copy `ps5-final.sh` to a FAT32/exFAT USB stick. Eject it safely.
2. Plug it into the PS5. In your terminal:

   ```bash
   lsblk -o NAME,SIZE,FSTYPE,LABEL        # find the stick (e.g. sdb1 — check size/label!)
   sudo mkdir -p /mnt/usb
   sudo mount /dev/sdb1 /mnt/usb          # replace sdb1 with what lsblk showed
   cp /mnt/usb/ps5-final.sh ~/
   sync && sudo umount /mnt/usb
   ```

**Method B — via the boot partition (if you pre-copied it in Part 1):**

```bash
sudo mkdir -p /mnt/ps5efi
sudo mount /dev/sda2 /mnt/ps5efi         # the small FAT partition with cmdline.txt
ls /mnt/ps5efi                           # sanity check: you should see cmdline.txt + ps5-final.sh
cp /mnt/ps5efi/ps5-final.sh ~/
sync && sudo umount /mnt/ps5efi
```

**Method C — over the network (if SSH already works), from PowerShell on your PC:**

```powershell
scp .\ps5-final.sh steam@<ip>:~/
```

**Then, no matter the method — verify the transfer:**

```bash
sha256sum ~/ps5-final.sh
# must print exactly:
# 422341cf958288fc01b26edf455923592bff81b336b091577b9ec82007d96863
```

> If the hash doesn't match, the file got corrupted in transit (multi-line pastes into SSH terminals are notorious for this). **Do not run a file whose hash doesn't match** — transfer it again with one of the file-based methods above.

---

## Part 4 — Run the script

```bash
chmod +x ~/ps5-final.sh
bash ~/ps5-final.sh
```

The script logs everything to `~/ps5-final.log`. Core system fixes (Bluetooth stack, Wi-Fi driver, SSH, session machinery, tools) run unconditionally. Opinionated steps ask `[Y/n]` — pressing **Enter** picks the recommended default:

| Prompt | What it means | Recommended |
|---|---|---|
| Set up Wi-Fi | only asked if there's no internet yet — connects via `nmcli`, system-wide | yes if you need it |
| Save Wi-Fi for later | offered when online via Ethernet but Wi-Fi is unconfigured — auto-connect at boot, no KWallet prompts | yes for cable-free use |
| Full system upgrade | `pacman -Syu` — the image is a rolling release; installing new apps onto the old base breaks them (`GLIBC_2.44 not found`). Reboot afterwards | **yes** on a fresh flash |
| Console keymap | keyboard layout for the text console | your layout |
| Force 1080p | capture-card-only remedy — read the note below **before** answering | **no** (default) |
| Screensaver/lock off | console never blanks or locks | yes |
| Firefox | installs the browser | your choice |
| App dependencies | Java 17, rsync/jq/xmlstarlet, fuse2 (AppImages), Ark, Kate | yes |
| Steam autostart | enables gamepad-as-mouse on the desktop | yes |
| SSH public key | optional — paste a pubkey line for password-less SSH from your PC | your choice |
| Pair the DualSense now? | runs the pairing ritual (below) | **yes** |

> Every prompt is printed plainly and has a timeout (60 s questions / 30 s bond-removal / 15 s press-Enter), so the script behaves identically over SSH, on a tty, and from one-shot `ssh host "cmd"` — it can never sit at an invisible prompt looking dead. Bond removal asks `[y/n]` and defaults to the non-destructive *keep*, so pairing a **second** pad never eats the first pad's bond.

### The 1080p flag — read this before answering

This flag throws people off because its name sounds harmless. It isn't complicated, but it **is** global — so know what you're saying yes to:

- The image locks the output resolution **at boot time**; Plasma display settings cannot change it afterwards. With a **directly attached TV or monitor**, the console reads the display's EDID and picks its native mode by itself. A bare 1080p monitor just works — **no flag needed**.
- The flag (`amdgpu.force_1080p=1` in `cmdline.txt`) exists for exactly one situation: a **capture card (Elgato etc.) with nothing plugged into its HDMI OUT port**. With no monitor downstream, the card answers the console with its own *fallback EDID*, which can advertise modes the capture hardware can't actually encode (commonly: 4K input OK, 1080p capture max) → black or "unsupported signal" in OBS or whatever you preview with. The flag forces 1080p so the card can capture it.
- **With a 1080p monitor on the card's OUT port, you don't need the flag** — the console then sees the *monitor's* EDID and negotiates 1080p on its own.
- **The flag applies to every boot and every display until removed.** Hook the console to a normal TV/monitor with the flag set and you get forced 1080p even on a 4K display. That's why the default answer is **no**.
- **Reverting is one command:** `bash ~/toggle-1080p.sh` (toggles the flag in `cmdline.txt`), then reboot. The helper is installed even if you answer no, so you can also enable the flag later without re-running the whole setup. Manual alternative: mount the FAT boot partition (`sudo mkdir -p /mnt/ps5efi && sudo mount /dev/sda2 /mnt/ps5efi`), edit `cmdline.txt`, remove `amdgpu.force_1080p=1` — or edit that partition from Windows while the drive is in your PC.

### The pairing ritual (when the script asks)

> **On a fresh flash, the script may refuse to offer pairing** ("phantom hci1 is still active") — that's intentional, not a bug. The udev rule only kills the phantom interface from the next boot, and pairing on the polluted adapter is unreliable. Just finish the script, **reboot**, then run `bash ~/ps5-final.sh pair`. The same goes if your very first pairing attempt behaves weirdly: reboot and re-pair on the clean adapter.

0. **If the pad is currently connected (solid light bar): hold PS for ~10 s until the light goes dark first.** A connected DualSense *ignores* PS+Create and can never enter pairing mode — this is the #1 cause of failed pairings (the script also disconnects it for you automatically, but dark is the goal). If you answered `y` at the bond-removal question, the script may spend a few seconds on "Adapter pairable confirmed." — it is re-asserting and *verifying* pairable while the daemon settles after the removal (a rejected `SetPairable` here was the root cause of weeks of failed pairings; v23+ refuses to pair until pairable is confirmed on).
1. **Paperclip-reset the DualSense**: press the tiny reset button in the hole on the back of the pad for ~3 seconds.
2. Hold **PS + Create** (Create = the small button above the D-pad) until the light bar **double-blinks**.
3. The script pairs with pairable verified on — so in most runs the first bond is **permanent immediately**: the light bar pulses briefly, then goes **solid within ~15 s**. Done.
4. **Fallback (throwaway path):** if the link drops and `Paired: no` flashes by, that first bond was a throwaway — **normal, do not re-pair**. The pad now re-connects **by itself** (~5 s and ~11 s retries) and lands the permanent bond. Only if the bar is still **dark** after ~20 s: **tap PS once** (if it is still double-blinking, press PS once first to *leave* pairing mode — a tap while it blinks is absorbed). The script watches for the real bond for up to 100 s.

> **Only the pad can reconnect — never the PC side.** `bluetoothctl connect <MAC>` and KDE's Bluetooth **Connect** button both fail with `br-connection-create-socket` on an idle DualSense. That error is **expected behavior, not a bug** — an idle pad doesn't listen for incoming connections. Tapping **PS** makes the pad initiate the connection, and that always works once it's paired. (All of this was verified on the wire with btmon.)

After the script finishes: **reboot** (so the udev rule takes effect from boot). From now on, tapping PS on the pad reconnects it automatically.

> Later, if you ever want to re-run just the pairing: `bash ~/ps5-final.sh pair`

---

## Part 5 — Verify everything works

| Check | Command / action | Expected result |
|---|---|---|
| Phantom BT interface gone | `ls /sys/class/bluetooth/` | only `hci0` (a `hci1` here means the kernel bug is present and the rule didn't load) |
| Pairing policy | `grep -E 'JustWorksRepairing\|PairableTimeout' /etc/bluetooth/main.conf` | `JustWorksRepairing=always` and `PairableTimeout=0` |
| NetworkManager running | `systemctl is-active NetworkManager` | `active` (if `inactive`: `sudo systemctl start NetworkManager` — see bug #8) |
| SSH survives reboot | from your PC: `ssh steam@<ip>` | connects |
| Boot behavior | reboot the console | lands in Big Picture automatically |
| Pad reconnect | after reboot, tap **PS** once | connects by itself, no re-pairing |
| Pad actually works | `cat /proc/bus/input/devices \| grep -A4 -i dualsense` | lists the pad (gamepad, motion, touchpad) |
| Session switch | "Switch to Desktop" tile in Big Picture | desktop appears in ~15 s; Steam's "Switch to Gaming Mode" button brings you back |

The full troubleshooting table (black screens, Wi-Fi quirks, package errors, and more) is in the companion **`PS5-Linux-Cheatsheet.pdf`**.

---

## One-time afterwards: add the tiles to Steam (+ artwork)

The script creates the two `.desktop` entries ("Switch to Desktop" and "Pair DualSense"), but **Big Picture only lists them after you add them as non-Steam games once — and that requires desktop-mode Steam.** So yes: you have to visit the desktop once. Two minutes:

1. From SSH (or a tty): `bash ~/switch-to-desktop.sh` — the desktop appears in ~15 s.
2. Open **Steam** on the desktop → **Games → Add a Non-Steam Game…** → tick **"Switch to Desktop"** and **"Pair DualSense (Bluetooth)"** → *Add Selected Programs*.
3. Back to gaming mode: Steam's **"Switch to Gaming Mode"** button (on this image, that direction works).

Both tiles now live in your Big Picture library, usable with the gamepad.

**Artwork (optional but nice):** the repo's `artwork/` folder ships a matching set for both tiles — capsule (600×900), hero/background (3840×1240), logo (1280×720, transparent), icon (128×128):

| File | Tile |
|---|---|
| `switch-to-desktop-capsule/hero/logo/icon.png` | Switch to Desktop |
| `pair-dualsense-capsule/hero/logo/icon.png` | Pair DualSense |

Copy the folder to the console (`scp -r artwork steam@<ip>:~/` or USB stick), then **on the desktop**, for each tile: Steam → Library → right-click the tile → **Manage → Set custom artwork** (the capsule) / **Set custom hero** (the background) / **Set custom logo** / and via the tile's properties, the icon. Per tile it's four clicks — do it once and Big Picture stops showing grey rectangles.

---

## Daily use notes

- **Using the pad on the PS5 OS steals it.** If you use the DualSense on the PlayStation side (jailbreak menu, games), it forgets Linux. Back in Linux: plug the pad in via USB (it works as a wired controller), run the **"Pair DualSense" tile** (~60 s, follow the pop-ups), unplug when it says SUCCESS. No PC, no keyboard. The pop-ups are timed zenity dialogs (they auto-close — you don't need to click anything); every step also lands in `/tmp/pair-tile.log`, so if a popup ever fails to appear you can `cat /tmp/pair-tile.log` over SSH and just follow the light bar: double-blink = pairing mode, solid = connected.
- **Other pads** (DS4, Switch Pro, …) pair normally from the desktop's Bluetooth settings or with `bluetoothctl` — the repairing quirk is DualSense-specific.
- **Fan + boost:** `~/boost-on.sh` (always enable the fan together with boost — that's what the official PS5 OS does).
- **Re-flashed the image?** Just repeat Parts 3–5. The script is idempotent.
- **"Why does the desktop keep asking for my password?"** Two sources, both fixed by the script: *polkit* (GUI admin actions — step 14 installs a rule letting user `steam` do them without prompts; appropriate for a single-user couch console, not for multi-user machines) and *KDE Wallet* (the secret vault nagging to be unlocked — step 14 disables it; Wi-Fi is stored system-wide, so nothing needs the wallet). Terminal `sudo` still asks, by design.

---

## Quick reference (for experienced users)

```bash
# transfer to the console, then:
chmod +x ~/ps5-final.sh
sha256sum ~/ps5-final.sh   # v24: 422341cf958288fc01b26edf455923592bff81b336b091577b9ec82007d96863
~/ps5-final.sh             # full setup
~/ps5-final.sh pair        # DualSense pairing only
```

What it configures: internet check · console keymap · quiet printk · Bluetooth (udev phantom rule + fossil-hack removal + repairing policy) · SSH · stock BlueZ with kernel HID path · NXP mwifiex Wi-Fi driver + combo firmware · ps5-linux-tools (fan + boost at boot) · helper scripts · optional 1080p forcing · screensaver/lock off · Firefox · KWin X11 · session machinery (boot-default service, session-select patch, tiles, Steam autostart) · app dependencies.

---

## Under the hood: the Bluetooth fix (why this repo exists)

The PS5's internal Bluetooth (Marvell `1286:2059`, attached via xhci) **cannot pair anything** out of the box:

- `btusb` binds **both** USB interfaces `1.0` and `1.2` of the chip, registering **two HCI controllers for one radio**
- The second one (`hci1`) dies on `HCI_Reset` with `-110`; `hci0`'s own init is polluted with "unexpected event" warnings
- In this state, pairing always fails

**Fix:** a udev rule that keeps `btusb` off interface 1.2 (included in the script):

```
ACTION=="add", SUBSYSTEM=="usb", ATTRS{idVendor}=="1286", ATTRS{idProduct}=="2059", ATTR{bInterfaceNumber}=="02", ATTR{authorized}="0"
```

Two widely-circulated "fixes" turned out to be **actively harmful** and are *not* used:

- `disable_ertm=1` (a DualShock-3/4 era tip) — kills the DualSense's L2CAP HID channel; the link drops two seconds after pairing ("Connection terminated by local host")
- `UserspaceHID=true` — no input device is ever created; the pad connects but does nothing

With only the udev rule, **stock BlueZ + kernel `hid-playstation`** is all you need: pairing, connection, input, touchpad, motion sensors — everything works.

**The second layer — the pairing dance (packet-verified):** even with a healthy adapter, the DualSense re-pairs ~1.5 s after the first pairing to upgrade its link key ("repairing" — in the trace: a second `IO Capability Request` + `User Confirmation`, auto-accepted, ending in `Encryption Key Refresh`). If the adapter already left pairable mode or BlueZ's repairing policy rejects it (the default does, unless an agent confirms), the bond self-destructs one second after "Pairing successful". The fix: `JustWorksRepairing=always` in `/etc/bluetooth/main.conf` + keeping the adapter pairable through the whole pairing (the helper enforces both). The one-second drop right after pairing is **normal** — the stored link key works from then on.

**The third layer — connecting is the pad's job (also packet-verified):** an idle DualSense does not answer host-initiated connections. `bluetoothctl connect`, KDE's Connect button, any host-side attempt → `br-connection-create-socket`. The working path is pad-initiated: tap **PS**, the pad pages the console, BlueZ accepts because the device is bonded+trusted, and the kernel registers `js0`/`event*` via `hid-playstation`. One boot-time quirk: the kernel's `hidp` module loads lazily, so the *very first* pad connect after a boot could drop once before the module was ready — the setup preloads `hidp` at boot (`/etc/modules-load.d/hidp.conf`) to kill that quirk.

**The fourth layer — pairable is the make-or-break bit (btmon A/B, fail vs. success, same session, same chip, same pad):** whether the host-initiated bond survives is decided by a single adapter flag at the moment of `pair`. Adapter **pairable on** (MGMT settings `0x00400ad1`): BlueZ answers the pad's SSP request with `Dedicated Bonding (0x03)` — a **permanent** bond on the first try, no dance at all. Adapter **pairable off** (`0x00400ac1`): BlueZ answers `No Bonding (0x01)` — a **throwaway** link key the daemon deletes at the drop (`MGMT Unpair Device`), after which every re-knock from the pad is rejected `Pairing Not Allowed (0x18)`. Both paths issue byte-identical `Pair Device` commands; the answer differs only by that flag. What made this look random for weeks: pairable silently wears off (BlueZ's pairable timeout; daemon churn after disconnecting/removing an old bond) and `SetPairable` can be rejected outright — `Failed to set pairable on: org.bluez.Error.Busy` — while the daemon settles. The fix: `PairableTimeout=0` in `/etc/bluetooth/main.conf`, and the pairing helpers **set and verify** pairable in a retry loop immediately before `pair` (they never assume it), then re-assert it after the pair session exits so the pad's re-knock window stays open. The old tap-PS dance remains as a fallback for the throwaway path.

**The fifth layer — the combo chip wedges on warm reboots:** the NXP IW620's Bluetooth side hangs after a *warm* reboot (`hci0: command 0x2039 tx timeout` in dmesg; Wi-Fi, on the same chip via PCIe, is unaffected). A cold boot — power off, re-run the payload — always resets it. The script first tries a driver-level revive (`modprobe -r btusb && modprobe btusb`), which brings the adapter back without a cold boot in practice, and only then tells you to cold-boot.

**Boot-time networking quirk:** NetworkManager is `enabled` yet the boot transaction intermittently never pulls it in (zero NM lines in the journal; LAN *and* Wi-Fi dead — observed on cold AND warm boots). The script runs `systemctl enable --now NetworkManager` at the start of every run and installs `nm-ensure.service`, a oneshot watchdog (`WantedBy=multi-user.target graphical.target`) that force-starts NM at every boot. If you ever boot to no network before that: `sudo systemctl start NetworkManager` fixes it instantly.

**Upstream status:** independently of this work, the same root cause was fixed in [ps5-linux-patches PR #19](https://github.com/ps5-linux/ps5-linux-patches/pull/19) (merged 2026-06-23) via a `BTUSB_IFNUM_0` quirk — the driver-level equivalent of this udev rule. Kernels built from patches **older than 2026-06-23** still double-bind (some later images shipped such kernels despite newer patch labels — check `cat /proc/version`); on those, this script's rule is the fix. On newer kernels it's a harmless no-op. The script detects and prints which situation it found.

## Session model

Boot always lands in **gaming mode** (gamescope + Big Picture) via `ps5-session-default.service`, which resets the session token at every boot. Switching:

| Direction | Method |
|---|---|
| gaming → desktop | "Switch to Desktop" tile in Big Picture (soft switch, kills stale display servers first) |
| desktop → gaming | Steam's own "Switch to Gaming Mode" button |
| emergency | `~/rescue-gaming.sh` over SSH — or just power-cycle, boot is gaming anyway |

Notes for this image: Steam's menu entry "Switch to Desktop" never calls the session script on this image (use the tile); the DP→HDMI bridge chip occasionally black-screens a soft switch (intermittent — just retry); desktop mode needs `plasma-x11-session` + `kwin-x11` because Arch no longer installs an X11 window manager by default (no title bars / no Alt-Tab without it).

## Helper scripts installed

| Script | Purpose |
|---|---|
| `~/pair-dualsense.sh` | standalone DualSense pairing over SSH (~20 s, poll-based) |
| `~/pair-dualsense-tile.sh` + "Pair DualSense" desktop entry | non-interactive re-pairing with timed zenity pop-ups (visible in gaming mode) + `/tmp/pair-tile.log` fallback — no SSH/keyboard needed (the pad works wired via USB meanwhile); for after the pad was used on another host |
| `~/switch-to-desktop.sh` | the tile backend |
| `~/rescue-gaming.sh` | emergency return to gaming mode |
| `~/boost-on.sh` | fan + CPU/GPU boost |
| `~/toggle-1080p.sh` | toggles the optional 1080p boot flag in `cmdline.txt` (active from next boot) — the easy revert |

## What it deliberately does NOT do

Game files, Wi-Fi credentials, and Steam controller layouts are user data — the script installs the dependencies and machinery, you bring the content.

## Disclaimer

Provided as-is, without warranty. Jailbreaking and running Linux on your console is your own responsibility. Pair only controllers you own.

## License

MIT
