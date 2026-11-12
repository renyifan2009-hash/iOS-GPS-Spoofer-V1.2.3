# Test phone-only GPS control

Use the iPhone app from release 2.6.0 or later (1.3, build 6), or one built from `main`. The 2.5.0 iPhone app (1.2, build 5) doesn't have these changes. The app is unsigned until your sideloading tool signs it.

## Compatibility status

| iOS | Connection attempted | Evidence still needed |
|---|---|---|
| 17.0–17.3 | Remote Pairing only | Pairing export, local tunnel, image mount and GPS commands on a physical device. This path is experimental; removing an app gate does not make the OS implement a missing service. |
| 17.4–18.x | Remote Pairing; lockdown/CoreDeviceProxy fallback when reachable | Physical device tests, including reboot and cellular. |
| 26.x and newer | Remote Pairing; only use fallback if the service answers | Exact OS/build tests. Some versions restrict local developer connections. |

No row is certified across every minor release or future version. Tests using fake device operations prove control ordering, not Apple's protocol behavior.

## One-time preparation

1. Install/sign the iPhone app with your existing sideloading tool. Enable Developer Mode.
2. Export/import this iPhone's pairing file. It must contain a Remote Pairing identity for the Remote Pairing path; a lockdown-only file is insufficient on 17.0–17.3 or where lockdown is unavailable. Keep it private.
3. Turn on LocalDevVPN and allow Local Network access. Grant location permission to the app for its background session.
4. For a restart test, obtain matching Apple developer-image files. Copy the extracted DDI folder to Files on the phone. Choose **This iPhone → Set Up → Choose Developer Image Folder**. Select the directory containing `BuildManifest.plist` and the payloads named by that manifest. A personalized bundle normally contains `Image.dmg` and `Image.dmg.trustcache`; a Cryptex bundle needs all four Cryptex payloads from its Restore directory. An outer DMG or ZIP is not an extracted folder.
5. The app checks payload hashes and retains a copy locally. Validation does not guarantee device compatibility: Apple still decides whether personalization succeeds. Updating iOS may require replacing the image. Internet may be needed to request Apple's personalization ticket.

## Acceptance checks

Record the model, exact iOS version/build, app build, developer-image build, outcome and error step. Do not attach a raw pairing file or an unredacted device log to an issue.

| Test | Procedure | Required observation |
|---|---|---|
| Computer off | Power down the Mac. Select **This iPhone**, then Start Here. | Maps on the phone reports the chosen position. No command is sent to the Mac. |
| Move and stop | Move Here, then Stop. | Maps moves and then returns to its real location. If Stop is unconfirmed, the app says so. |
| Local joystick | Pick Joystick and start. Hold a direction, then lift. | Position moves locally; motion stops when released. Repeat after locking/backgrounding the app: the joystick must stand still. |
| Route | Add stops; drive once, loop and ping-pong. Try straight legs and Follow roads. | Selected speed and waits apply; closed loops do not jump from end to start. Directions failure shows an error instead of silently crossing terrain. |
| Pause | Pause for 30 seconds, then Resume. | Position/progress stays still while paused, then continues. |
| Stop race | Tap Stop while the VPN probe/connection/route planning is pending. | No later task reactivates a stopped session. |
| Timer | Set an automatic stop; test while foregrounded and locked. | Stop occurs at the deadline while the app is executing. Check the actual position in Maps, not just the countdown. iOS can suspend/terminate the app. |
| Connection loss | Turn LocalDevVPN off during a hold, then back on. | The hold is checked within about 25 seconds. Reconnect succeeds or a real error replaces the active state. Motion never catches up by making a huge jump. |
| Cellular | Turn Wi-Fi off with the Mac powered off and tap Start Here. Then turn on Airplane Mode with LocalDevVPN still connected and start again. | On cellular data alone, Start fails with the message that iOS doesn't let LocalDevVPN reach the developer services over cellular, and the pill says Needs Wi‑Fi or Airplane Mode (see below). In Airplane Mode it starts. Road planning/image personalization may require internet. |
| Reboot | Restart the phone, keep the Mac off, reconnect LocalDevVPN, Start Here. | The stored image is personalized/mounted and a fresh tunnel opens Instruments. Any failure identifies the image/tunnel/service step. |
| Force quit | Force-quit while spoofing; relaunch and inspect Maps. | Record actual OS behavior. The app does not promise continued execution after force quit. |

## Automated checks

- Swift package tests cover route geometry, waits, repeats, invalid/oversized inputs, image digests and unsafe paths, protocol choice and failure wording.
- Hosted iOS unit tests replace device operations and background holding with fakes. They test Stop during VPN preflight, inputs arriving during a slow Stop, invalid coordinates, unconfirmed Stop, local joystick release, route pause/stop, hold liveness and the local deadline.
- CI runs those hosted tests in an iOS simulator and builds the unsigned physical-device app. Neither executes real RSD/DVT nor proves image mounting.

## Primary references

- [Pinned idevice image-mounter FFI](https://github.com/jkcoxson/idevice/blob/v0.1.68/ffi/src/mobile_image_mounter.rs)
- [Pinned idevice Cryptex FFI](https://github.com/jkcoxson/idevice/blob/v0.1.68/ffi/src/cryptexd.rs)
- [StikDebug compatibility](https://github.com/StikDebug/StikDebug#compatibility) — upstream lists 17.4+, not all iOS versions. Our 17.0–17.3 attempt remains unverified.
- [Apple background location guidance](https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background) — background authorization/session management does not guarantee perpetual execution.

## Cellular transition regression

Reported on iOS 26.6: cellular enabled blocks Start; starting with cellular disabled and enabling it afterwards loses control after approximately 40 seconds. LocalDevVPN reports connected with Device IP 10.7.0.1/32 and Tunnel IP 10.7.1.1/32. The device address matches the app; this is not evidence the VPN is off.

Build 6 lets a Network.framework waiting probe recover until its deadline, rechecks initial negative reachability once, and makes at most two additional transport-only connection attempts with fresh port discovery and a two-second delay. Pairing and developer-image failures are not automatically retried. Stop invalidates pending recovery. The UI reports developer reachability rather than claiming to know another app's VPN state.

The native idevice sockets remain ordinary TCP sockets. Recovery cannot repair a persistent iOS/LocalDevVPN routing or permission problem.

**Cause (found November 2026):** iOS refuses connections to the iPhone's developer services that come in through LocalDevVPN while cellular data is the only network. LocalDevVPN still shows Connected. A report on iOS 26.6.1 and 27.0 saw 10.7.0.1 refuse the connection (ECONNREFUSED) with Wi‑Fi off ([jkcoxson/LocalDevVPN#31](https://github.com/jkcoxson/LocalDevVPN/issues/31)). LocalDevVPN's maintainers closed that issue saying it is enforced by Apple and they can't get around it. StikDebug's [integration guide](https://github.com/StikDebug/StikJIT/blob/main/INTEGRATION.md) gives the same workaround this app now gives: without Wi‑Fi, connect LocalDevVPN, then turn on Airplane Mode. No app-side fix is known.

Since iPhone build 7, AnyWhere watches the network (`NWPathMonitor`). When nothing answers and cellular is the only network, the pill says **Needs Wi‑Fi or Airplane Mode** and the error says to join Wi‑Fi, or to keep LocalDevVPN connected and turn on Airplane Mode. It no longer opens LocalDevVPN by itself then, since LocalDevVPN is usually connected already. Whether a hold started on Wi‑Fi or in Airplane Mode survives a later switch to cellular is still unverified: the earlier report above saw it end after about 40 seconds.

Test with AnyWhere foreground and unlocked, cellular enabled before Start, then repeat cellular off/on transitions. Record VPN status, time until failure, exact iOS build, and error detail. Check Settings > Cellular > AnyWhere is enabled as well as Local Network permission. Confirm actual position in a separate location display. Test for 10 minutes first, then extend to the two-hour endurance plan.
