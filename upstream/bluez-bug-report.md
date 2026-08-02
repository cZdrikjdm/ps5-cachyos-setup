# BlueZ bug report: pairing silently degrades to "No Bonding" when adapter is not pairable at Pair() time — throwaway link key deleted at drop, remote re-pair then rejected 0x18; SetPairable intermittently fails with org.bluez.Error.Busy

**Component:** bluetoothd / adapter pairing state machine
**Version observed:** BlueZ 5.87 (bluetoothctl 1.23), kernel 7.1.3–7.1.4 (x86-64, Marvell/NXP IW620 BT via btusb)
**Remote device:** Sony DualSense (BR/EDR, SSP, requests Dedicated/General Bonding)
**Reproducibility:** 100% when adapter is not pairable at Pair() time; 0% when it is (same boot, same adapter, same remote, minutes apart)

## Summary

Whether a `Device1.Pair()` produces a **permanent** bond or a **throwaway** link key depends entirely on the adapter's *pairable* flag at that instant — but nothing in the API surface tells the caller this, and three compounding behaviors make the failure look random:

1. **Pairable silently turns itself off.** With a default configuration (no explicit `PairableTimeout`), pairable set via D-Bus was repeatedly observed gone again ~30–60 s later, and also gone after daemon churn caused by disconnecting/removing a previous bond.
2. **`SetPairable` can be rejected with `org.bluez.Error.Busy`** while the daemon is settling after a disconnect/remove — so even re-asserting pairable immediately before `Pair()` is not reliable unless the caller *verifies* the property afterwards.
3. When pairable is off, `Pair()` still "succeeds" from the caller's perspective (`Pairing successful`), but the SSP exchange negotiated **No Bonding (0x01)**: the daemon stores a temporary link key, actively deletes it at the inevitable first disconnect (`MGMT Unpair Device`), and — with pairable still off — answers the remote's own re-pair attempts with **IO Capability Request Negative Reply, Reason: Pairing Not Allowed (0x18)** until the remote gives up.

## Expected behavior

A client-initiated `Pair()` is an explicit bonding request. Either the daemon should negotiate a bonding-capable authentication requirement for it regardless of the pairable flag (pairable should gate *incoming* pairing, not an explicit outgoing `Pair()`), or it should fail loudly / document that `Pair()` requires pairable to be set — instead of returning success while producing a bond it deletes seconds later.

## Actual behavior (btmon-verified, A/B on the same boot)

**Run A — pairable OFF at Pair() time (fails):**

```
@ MGMT Command: Set Bondable (0x0009)  Bondable: Disabled (0x00)   -> Current settings: 0x00400ac1   (Powered, SSP, BR/EDR, LE, SecureConn, LL Privacy — NO Bondable)
@ MGMT Command: Pair Device (0x0019)   Capability: KeyboardDisplay (0x04)
> HCI Event:  IO Capability Request (0x31)
< HCI Command: IO Capability Request Reply  Authentication: No Bonding - MITM required (0x01)
> HCI Event:  Simple Pairing Complete: Success
> HCI Event:  Link Key Notification
... ~5 s later, link drops ...
@ MGMT Command: Unpair Device          (daemon deletes the key it just made)
# remote re-connects by itself (~+5 s, +11 s, +17 s); each time:
> HCI Event:  Link Key Request -> Negative Reply (key already deleted)
> HCI Event:  IO Capability Response (remote offers General Bonding 0x04)
< HCI Command: IO Capability Request Negative Reply  Reason: Pairing Not Allowed (0x18)
> HCI Event:  Simple Pairing Complete: Authentication Failure (0x05) -> Disconnect
```

**Run B — pairable ON at Pair() time (works), minutes later, same everything:**

```
@ MGMT Command: Set Bondable (0x0009)  Bondable: Enabled (0x01)    -> Current settings: 0x00400ad1   (… Bondable present)
@ MGMT Command: Pair Device (0x0019)   Capability: KeyboardDisplay (0x04)   # byte-identical to Run A
> HCI Event:  IO Capability Request (0x31)
< HCI Command: IO Capability Request Reply  Authentication: Dedicated Bonding - MITM required (0x03)
> HCI Event:  Simple Pairing Complete: Success
> HCI Event:  Link Key Notification
# link drops seconds later as with Run A — but NO Unpair Device is ever sent;
# the remote re-connects and the bond is permanent. Zero 0x18 events.
```

The `Pair Device` MGMT commands in both runs are **byte-identical**. The only difference is the bondable bit in the adapter settings at that moment.

**The `SetPairable` rejection (bluetoothctl output from a failing run):**

```
[bluetoothctl]> pairable on
Failed to set pairable on: org.bluez.Error.Busy
hci0 new_settings: powered ssp br/edr le secure-conn ll-privacy     <- bondable absent
[bluetoothctl]> pair D0:BC:C1:38:B2:7D
Attempting to pair with D0:BC:C1:38:B2:7D
...
Pairing successful        <- caller believes all is well; bond is a throwaway per the trace above
```

This run had issued `pairable on` ~40 s earlier (before a disconnect+remove of the remote's previous bond and a 10 s scan). By `Pair()` time, pairable was off again despite no client ever requesting that.

## Impact

Any agent-driven pairing flow that (a) sets pairable more than ~30 s before pairing, or (b) pairs after removing a stale bond, or (c) calls `SetPairable` while the daemon is busy — i.e., most real-world re-pairing flows — intermittently produces bonds that self-destruct, with the failure surfaced seconds later and attributed by users to their hardware. Interactive `bluetoothctl pair` succeeds or fails depending on how fast the operator types, which made this extraordinarily hard to pin down (it looked like a timing/hardware issue for weeks).

## Workaround (validated)

- `PairableTimeout=0` in `/etc/bluetooth/main.conf`
- Set pairable **and verify** (`SetPairable` then read the property; retry while `org.bluez.Error.Busy`) immediately before calling `Pair()`; re-assert after the pairing session ends so remote-initiated re-pairs aren't rejected 0x18.
- With pairable confirmed on, the first bond is permanent (`Dedicated Bonding (0x03)`) and none of the fallback machinery is needed.

## Suggestions (as questions)

1. Should an explicit `Device1.Pair()` really negotiate `No Bonding`? The caller is, by definition, requesting a bond. Answering `Dedicated/General Bonding` for an agent-initiated `Pair()` would make pairable a gate for *incoming* pairing only, which matches user expectations.
2. If (1) is working as intended, could `Pair()` at least return a distinct error/warning when the result will be a throwaway key, instead of reporting success?
3. `SetPairable` → `org.bluez.Error.Busy` during post-disconnect settling: could this be queued/retried internally rather than rejected?
4. A short grace window before `MGMT Unpair Device` on a just-created No-Bonding key (or re-using it when the same remote immediately attempts General Bonding) would turn the failure mode into a success.

Full decoded btmon traces of both runs available on request.
