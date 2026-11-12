# iPhone Remote

**Computer-off control:** choose **This iPhone** for the local teleport, joystick, route and timer backend. See [PHONE-ONLY.md](PHONE-ONLY.md); published build 4 lacks the new standalone controls.

Control the simulated location entirely from your iPhone. Your Mac stays in a
bag, a car or another room and keeps the location alive; the **AnyWhere**
app on the iPhone picks places and tells it to start, move or stop.

AnyWhere also has an **iPhone-only mode (beta)**: after a one-time setup
with the Mac, it sets the location by itself, with no Mac, on Wi-Fi or
cellular. The switch at the top of its bottom card picks **Mac** or **This
iPhone**. That mode has its own guide: [PHONE-ONLY.md](PHONE-ONLY.md).

## The constraint, stated plainly

iOS has **no public API that lets an installed app change the location the
whole system reports** (Maps, Find My, other apps). Location simulation is a
*developer* service that iOS only exposes to a connected computer, which is how
Xcode's *Simulate Location* works and how this project works. So:

- the **Mac** holds the developer connection to the iPhone (USB, or Wi-Fi after
  pairing) and sets the location through `pymobiledevice3`, exactly as before;
- the **iPhone app is a remote control**. In this mode it never touches the
  location itself.

The iPhone-only mode uses the same developer service, not a public API: with
the iPhone's pairing file and a loopback VPN, the app makes the developer
connection to its own iPhone, the way a Mac would.

No jailbreak, private entitlement, or system modification is used or needed.

```
 iPhone (AnyWhere app) ──HTTP/JSON, local network──▶ Mac helper ──developer service──▶ same iPhone
        pick a place                                      SpooferCore                    reports that place
```

## What you get

- **Mac helper**: `iosgpsspoof serve` (headless, can run as a login item), or
  **Settings ▸ iPhone Remote** in the Mac app (you see the phone's commands on
  the Mac's map).
- **iPhone app**: Apple Maps, search ("Apple Park", any address, coordinates),
  tap anywhere to drop a pin, favorites and recents, Start / Move Here / Stop,
  live status (Mac reachable, iPhone linked, what's being simulated), and an
  animated first-run introduction. Liquid Glass design on iOS 26 and later;
  it still runs on iOS 17.
- **Joystick**: a thumb pad that steers the Mac's location at walking, cycling
  or driving pace (or a custom top speed up to 75 mph / 120 km/h, in your
  region's unit). Up on the pad can
  mean north or up on the screen as the map is turned. VoiceOver gets
  Move north/east/south/west actions instead of dragging.
- **Trip planner**: tap the start, any rest stops and the destination on the
  map. **Leave** sets how long to wait at the start before setting off ("leave
  in 30 min"). **Stops** lets you drag to reorder, reverse the trip, and tap a
  stop's time to type how long to rest there: "45", "20 min", "1h 15m",
  "1:30" or "half an hour" (a number on its own is minutes, up to 24 hours),
  or tap a quick pick. Pins on the map show each wait. Choose walking or
  driving, once / loop / there and back, follow roads, rush-hour slowdowns and
  a top speed (in mph or km/h by region), then **Drive Route**. Routes can be
  saved by name or picked from the last few driven. They live on the iPhone
  only.
- **While a route runs**: how far along it is, the current speed, or why it
  is standing still ("Leaving in 29:41", "Resting at stop 2 · 12:03 left",
  "Red light · 0:26"), with **Pause**, **Resume** and **Stop**. Pausing freezes
  a wait's countdown too.
- **Stop after**: a timer (15 minutes up to 4 hours) that puts the real
  location back by itself, set from the iPhone.
- **A newer-release notice**: AnyWhere doesn't update itself, so at most
  once a day it asks GitHub whether a newer release is out and, if so, shows a
  small notice with a button to the releases page. It sends nothing about you
  or the iPhone, and no answer simply shows nothing. See
  [PHONE-ONLY.md](PHONE-ONLY.md#keeping-the-two-apps-in-step).
- **Discovery** over Bonjour (`_iosgpsspoof._tcp`), with a type-an-address
  fallback.
- **Pairing** with a one-time 6-digit code. The token lives in the iPhone's
  Keychain; the Mac stores only its SHA-256.
- **Local network only**: the Mac refuses connections from anything but
  private, link-local or loopback addresses.
- **Self-healing**: if the iPhone unplugs or the tunnel drops, the session
  waits and re-applies the last location; if it gives up, the helper retries
  every 15 s for as long as you want the location held. The Mac doesn't
  idle-sleep while a location is held.

## Folder structure

```
Package.swift                         # adds RemoteAPI, SpooferRemote, PhoneOnlyCore, tests
Sources/
  RemoteAPI/RemoteAPI.swift           # wire types, shared by Mac and iPhone
  PhoneOnlyCore/                      # rules shared with the iPhone app: pairing file, tunnel, Killswitch, JoystickInput, SavedRoute
  SpooferRemote/
    MacRemoteServer.swift             # NWListener HTTP server, routing, local-only filter
    PairingManager.swift              # codes, tokens (hashed), lockout
    BonjourService.swift              # advertising, local addresses, IP checks
    SessionRemoteController.swift     # drives SpooferCore's SpoofSession headlessly
    JoystickMotion.swift              # heading + speed -> next position, with the dead-man timeout
  iosgpsspoof/Serve.swift             # `iosgpsspoof serve` + LaunchAgent
  iosgpsspoofer-gui/RemoteHost.swift  # Mac app: Settings ▸ iPhone Remote
Tests/SpooferRemoteTests/             # parser, pairing, routing, IP filter tests
iPhoneRemote/
  project.yml                         # XcodeGen spec; stamps the repo VERSION into BuildVersion.swift at build time
  SpoofRemote/                        # the app's source folder; its product is AnyWhere.app
    SpoofRemoteApp.swift              # @main
    ContentView.swift                 # map + status + controls
    MapSearchView.swift               # MKLocalSearchCompleter / MKLocalSearch
    ConnectionManager.swift           # Bonjour, pairing, HTTP, polling
    LocationController.swift          # selection, favorites, recents, geocoding
    JoystickCard.swift                # the thumb pad and its model
    RouteCard.swift                   # build a route / a route driving
    RouteSheets.swift                 # edit the stops, saved and recent routes
    RouteDraft.swift                  # the route being built
    RouteLibrary.swift                # saved and recent routes (on the iPhone)
    AutoStopRow.swift                 # the stop-after timer
    PairingView.swift                 # find Mac, 6-digit code, manual address
    IntroView.swift                   # animated introduction
    Glass.swift                       # Liquid Glass helpers + fallbacks
    KeychainStore.swift               # token storage
    UpdateChecker.swift               # once-a-day check with GitHub for a newer release
    UpdateNoticeView.swift            # the "a newer version is out" notice
    BuildVersion.swift                # the repo VERSION, stamped in at build time
    OnDevice/                         # the iPhone-only mode (see PHONE-ONLY.md)
    Info.plist                        # Local Network / Bonjour / ATS / background / file keys
    Assets.xcassets                   # app icon, accent colour
  scripts/fetch-idevice.sh            # downloads idevice for the iPhone-only mode
  Vendor/                             # where it goes (not in git)
```

## Which SpooferCore code the server calls

Fixed-point spoofing already existed, so the server reuses it instead of
duplicating it.

**Headless helper (`iosgpsspoof serve`)**: `SessionRemoteController`:

| Remote command | SpooferCore call |
|---|---|
| first `POST /start` | `Pymobiledevice3.selectDevice(udid:connection:)` → `SpoofSession(pmd:device:transport:engine:python:callbackQueue:)` → `SpoofSession.start(at:)` |
| `POST /location` or `/start` while running | `SpoofSession.move(to:)` (one message with the live engine) |
| `POST /stop` | `SpoofSession.stop()` (restores the real location) |
| `POST /route` | `RouteRunner` over the roads the iPhone sent (`RoadRoute`; straight lines without them), after `OverpassLoader` looks up their lights, signs and limits (`planning`, 20 s at most), played through `SpoofSession.move(to:)` |
| `POST /joystick` | a 4 Hz timer that applies the latest heading and speed with `SpoofSession.move(to:)`; lets go after 1.5 s of silence |
| `POST /pause` | the route's clock stops and resumes (`routePausedAt`) |
| `POST /autostop` | the `Killswitch` rule, armed for N minutes |
| Ctrl-C / `launchctl` stop | `SpoofSession.stopBlocking()` |
| `GET /status` | state from `onStateChange` / `onPosition` / `onEngineChange`, and `Pymobiledevice3.listDevices()` every 5 s |
| engine choice at startup | `LiveHelper.probe(python:)` with `Pymobiledevice3.pythonInterpreter` |

Reconnects: `SpoofSession` already waits for a device that disappeared
(`.reconnecting`) and relaunches a dropped channel with back-off. On top of
that, when it reports `.failed` the controller calls `start(at:)` again after
15 s while the iPhone still wants the location.

**Mac app (Settings ▸ iPhone Remote)**: `AppRemoteBridge` calls the same
methods as the Teleport button: `AppModel.teleport(to:name:)` (which uses
`obtainSession()` → `SpoofSession.start(at:)`, or `move(to:)` if a session is
running) and `AppModel.stop()` (→ `SpoofSession.stop()`). A route sent from
the iPhone goes through `AppModel.startRemoteRoute(_:)`, which fills in the
Route panel the same way you would (waypoints, travel mode, speed, traffic)
and presses **Start Route**, so what the iPhone starts is what the Mac shows.
The joystick steers the Mac app's own joystick engine, and the stop-after
timer is the app's own **Stop Automatically After** setting, scoped to the
current session.

## The API

Plain HTTP/1.1 + JSON on port **47653**. Every request except `GET /info` and
`POST /pair` needs `Authorization: Bearer <token>`.

```http
POST /pair        {"code": "482913", "clientName": "iPhone", "clientID": "…"}
               →  {"token": "…", "server": {"serverID": "…", "name": "MacBook Air", "version": 1}}

POST /location    {"latitude": 37.3349, "longitude": -122.0090, "name": "Apple Park"}
POST /start       (same body, optional: without one it starts at the last location)
POST /stop
POST /route       {"waypoints": [{"latitude": 37.33, "longitude": -122.01, "wait": 60}, …], "followRoads": true,
                   "travelMode": "driving", "loopMode": "once", "speed": 13.9, "realistic": true,
                   "timeOfDayTraffic": false, "name": "Commute",
                   "followSpeedLimits": true,                                   (version 3)
                   "legs": [{"coordinates": [37.33, -122.01, 37.331, -122.012, …], (version 3: lat, lon, lat, lon…)
                             "meters": 2140, "expectedSeconds": 190}, null, …]}
POST /joystick    {"heading": 90, "speed": 1.4}        (degrees clockwise from north, metres per second)
POST /pause       {"paused": true}
POST /autostop    {"minutes": 30}                      (0 turns it off)
GET  /status
POST /unpair
GET  /info        → {"serverID": "…", "name": "MacBook Air", "version": 1}
```

`/status` (and every command) returns:

```json
{
  "connected": true,
  "spoofing": true,
  "latitude": 37.3349,
  "longitude": -122.009,
  "placeName": "Apple Park",
  "phase": "active",
  "device": {"name": "iPhone", "model": "iPhone 15 Pro", "iosVersion": "18.1", "connection": "usb"},
  "engine": "Live",
  "serverName": "MacBook Air"
}
```

`phase` is `idle`, `starting`, `active`, `reconnecting`, `stopping` or
`failed`.

While a route or the joystick is running, `/status` also has `activity`
(`hold`, `planning`, `route` or `joystick`), `speed` (m/s), `heading`
(degrees), `routeProgress` (0 to 1), `routePaused`, `autoStopAt` (when the
stop-after timer fires, in seconds since 1970) and, while a route stands still,
`routeWait`: `{"reason": "stop", "stop": 0, "remaining": 1781}`. `reason` is
`stop` (one of your stops; `stop` counts the start as 0), `light`, `sign`,
`yield`, `crossing`, `break`, `turnaround` or `arrived`; `remaining` is seconds
left (none when arrived). `apiVersion` is the protocol version the Mac speaks
(2 since waits before leaving, 3 since routes carry their roads; a Mac before
2 leaves it out). These are all
optional: a Mac from before they existed leaves them out, and the iPhone app
copes. If you set a wait before leaving and the Mac is older than protocol 2,
the iPhone says so under **Leave**, because that Mac drives off right away. The headless
`iosgpsspoof serve` doesn't send `routeWait` yet; its routes still wait,
with realistic trips on or off.

**Waits.** A waypoint's `wait` is seconds to stand still there, up to 86,400 (a
day); longer is a 400. A wait on the **first** waypoint means "leave after":
the route holds the start for that long before it sets off (a loop or a
there-and-back also waits there each time it comes back round). A wait on the
last waypoint of a one-way route does nothing, since the route stays there.
The Mac honours waits whether or not "Drive like a real person" is on.
Changing a stop's wait while the trip is waiting there counts from when it
stopped: shorten it below what has passed (or remove it) and it leaves now. An
edit to the route itself, applied while it waits, keeps the time already
waited.

**The joystick is a dead-man switch.** The iPhone keeps sending `/joystick`
about three times a second while the thumb is down. If nothing arrives for
1.5 seconds (the iPhone locked, went to the background or lost the
connection), the Mac eases to a stop by itself and stays where it is. Lifting
the thumb sends one "stand still". The joystick and stop-after calls
answer 409 until a location is being held, and pause until a route is running; the joystick needs the live
engine, so on the classic engine it answers 409 with the reason.

`POST /route` plans the legs on the Mac (it can take a while with roads on; the
status says `planning`) and returns as soon as the route is accepted.

**Roads and speed limits (protocol 3).** With roads on, an iPhone talking to a
Mac on protocol 3 or later asks its own Apple Maps for each leg first and sends
them as `legs`: `legs[i]` runs from waypoint `i` to `i + 1`, and a loop whose
last stop isn't its first has one more leg back to the start. Each leg's
`coordinates` are latitude, longitude pairs (six decimals), starting at the
stop it leaves and ending at the one it reaches; `null` is a leg Apple Maps had
no road for. The Mac drives those roads: the Mac app takes them instead of
asking Apple Maps again (and asks for a `null` leg itself), and `iosgpsspoof
serve`, which has no Apple Maps, drives them as sent (a `null` leg is straight).
Legs that don't fit the stops (a wrong count, an end more than 150 m from its
stop, more than 60,000 points in all) are ignored, never an error. Because of
them `/route` takes bodies up to 4 MB; every other call stays at 64 KB, and an
older Mac turns a body over 64 KB away, so the iPhone sends legs only to a Mac
that reports `apiVersion` 3 or later.

`followSpeedLimits` (driving like a person on roads) drives each road at about
its OpenStreetMap limit, times the driver's habit, even above `speed`, which
then only counts where no limit is known. Where OpenStreetMap has no limit, or
its public servers are busy (they answer 502 when full), each leg's
`expectedSeconds` from Apple Maps stands in, the same as on the iPhone on its
own. Without it, `speed` stays the top speed and limits only slow the route,
as before. The iPhone shows **Drive at the speed limit** for a Mac only once
it reports protocol 3. The Mac app applies it only while its own
**Drive like a real person** is on. A bad
route (fewer than two points, a point off the planet, a negative wait or one
longer than a day) is a 400. A Mac from before routes existed answers 501, and the iPhone app says to
update the Mac app. Errors are a non-2xx status with `{"error": "message"}`: 400 bad
input, 401 not paired, 403 wrong code, 409 can't do that now (no iPhone,
still stopping), 429 too many wrong codes.

Try it from the Mac itself:

```bash
curl -s localhost:47653/info
TOKEN=$(curl -s -X POST localhost:47653/pair -d '{"code":"482913","clientName":"curl","clientID":"curl"}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
curl -s -X POST localhost:47653/start -H "Authorization: Bearer $TOKEN" -d '{"latitude":37.3349,"longitude":-122.009,"name":"Apple Park"}'
curl -s localhost:47653/status -H "Authorization: Bearer $TOKEN"
curl -s -X POST localhost:47653/stop -H "Authorization: Bearer $TOKEN"
```

## Set up the Mac

Install the Mac app first (see the [README](../README.md#install)). The
command-line tool is inside it:

```bash
alias iosgpsspoof='"/Applications/AnyWhere.app/Contents/MacOS/iosgpsspoof"'
iosgpsspoof serve
```

It prints the Mac's name, the **pairing code** and the addresses the iPhone
can use. Leave it running. Ctrl-C stops it and restores the real location.

- **Start at login** (user LaunchAgent, no admin rights):
  `iosgpsspoof serve --install-agent`. New pairing codes go to
  `~/Library/Logs/iosgpsspoof-remote.log`. Remove it with `--uninstall-agent`.
- **Or use the Mac app**: Settings ▸ iPhone Remote ▸ turn it on. The code,
  addresses and paired iPhones are shown there. Run either the app's remote
  or `serve`, not both (they share the port).
- Options: `--port`, `--name`, `--engine automatic|live|classic`, `--udid`,
  `--connection usb|network|any`, `--transport automatic|userspace|native|tunneld`,
  `--forget-paired`, `--verbose`.
- If macOS asks whether `iosgpsspoof` may accept incoming network
  connections, click **Allow**.

## Build the iPhone app

You need Xcode 16 or later (Xcode 26 or later for the Liquid Glass look) and
an Apple ID. A free one is enough to run on your own iPhone.

### Option A: XcodeGen

```bash
brew install xcodegen
iPhoneRemote/scripts/fetch-idevice.sh
cd iPhoneRemote
xcodegen
open SpoofRemote.xcodeproj
```

`fetch-idevice.sh` downloads [idevice](https://github.com/jkcoxson/idevice), the
library the iPhone-only mode uses (about 210 MB, once). It checks the download
against a pinned SHA-256 and puts it in `iPhoneRemote/Vendor/`.

Select the **SpoofRemote** target (it builds AnyWhere.app) ▸ *Signing & Capabilities* ▸ choose your
**Team**, pick your iPhone as the run destination, and press **⌘R**.

### Option B: by hand in Xcode

1. **File ▸ New ▸ Project ▸ iOS ▸ App**. Product Name `SpoofRemote`,
   Interface **SwiftUI**, Language **Swift**. Save it inside `iPhoneRemote/`.
2. Delete the template's `ContentView.swift`, `SpoofRemoteApp.swift` and
   `Assets.xcassets` (Move to Trash).
3. Drag everything in `iPhoneRemote/SpoofRemote/` into the project navigator
   (*Copy items if needed* off, *Create groups*, target **SpoofRemote** ticked).
4. **File ▸ Add Package Dependencies… ▸ Add Local…**, choose the repository
   folder (the one with `Package.swift`), and add the **RemoteAPI** and
   **PhoneOnlyCore** libraries to the SpoofRemote target.
5. Run `iPhoneRemote/scripts/fetch-idevice.sh`, then drag
   `iPhoneRemote/Vendor/IDevice.xcframework` into the project and add it to
   the target under *Frameworks, Libraries, and Embedded Content* with
   **Do Not Embed** (it's a static library).
6. Target ▸ **Build Settings**:
   - *Info.plist File* = `SpoofRemote/Info.plist` (keep *Generate Info.plist
     File* = Yes; Xcode merges the two)
   - *iOS Deployment Target* = 17.0
   - *Swift Language Version* = Swift 6
   - On Xcode 26: *Default Actor Isolation* = **nonisolated** (the template
     sets MainActor; the code is written for nonisolated)
7. Target ▸ *Signing & Capabilities* ▸ your Team. Run on the iPhone (⌘R).

### Info.plist keys

Already in `iPhoneRemote/SpoofRemote/Info.plist`; add them on the *Info* tab
if you skip step 6:

| Key | Value | Why |
|---|---|---|
| `NSLocalNetworkUsageDescription` | "SpoofRemote finds your Mac on this network…" | iOS asks before an app talks to the local network |
| `NSBonjourServices` | `_iosgpsspoof._tcp`, `_remotepairing._tcp` | required to browse for the Mac, and (iPhone-only mode) to look up the port of this iPhone's own pairing service |
| `NSAppTransportSecurity` ▸ `NSAllowsLocalNetworking` | YES | plain HTTP to local addresses |
| `NSLocationWhenInUseUsageDescription` | "Shows where iOS reports this iPhone to be…" | the optional blue dot that confirms the simulated location, and the iPhone-only mode's background session |
| `UIBackgroundModes` | `location` | the iPhone-only mode stays awake while it holds a location |
| `CFBundleDocumentTypes`, `UTExportedTypeDeclarations` | `com.iosgpsspoof.mobiledevicepairing` (`.mobiledevicepairing`) | pairing files from the Mac open in AnyWhere |

The Mac app's bundle (`package-dmg.sh`) also declares
`NSLocalNetworkUsageDescription` and `NSBonjourServices`.

## Use it

1. Start the Mac helper once and leave the Mac awake (plugged in, lid open,
   or clamshell mode with power and an external display).
2. Open **AnyWhere**. The introduction ends with **Find My Mac**; allow
   **Local Network** access when iOS asks.
3. Tap your Mac and enter the 6-digit code. You only do this once.
4. Search for a place or tap the map, then **Start Here**.
5. The Mac receives the coordinates and holds them; the status pill turns
   green ("Simulating"). Open Maps to see it.
6. Pick somewhere else and tap **Move Here**, or **Stop** to restore the real
   location, without touching the Mac.
7. Switch the bottom card to **Joystick** to steer from the held place: pick a
   pace, drag the pad, let go to stand still.
8. Switch it to **Route**, tap two or more places on the map, adjust the
   options and tap **Drive Route**. The card then shows the progress with
   **Pause** and **Stop**. **Stops** reorders, deletes, sets waits and
   reverses; **Save** keeps the route under a name; **Saved** lists saved and
   recent routes.
9. Use the timer in the card's corner to stop by itself after a while.

The Mac keeps the connection to the iPhone, so the joystick and routes need
the Mac awake and reachable. They don't need the iPhone app to stay open for a
route (a route carries on by itself on the Mac), but the joystick does: it
only moves while the app is open and a thumb is on the pad.

## Test: iPhone → Personal Hotspot → Mac → USB back to the iPhone

The setup where the Mac has no other network and gets internet from the
iPhone it's spoofing:

1. iPhone: **Settings ▸ Personal Hotspot ▸ Allow Others to Join** on.
2. Connect the iPhone to the Mac with a cable and tap **Trust** if asked.
   The Mac gets a network interface from the iPhone (*System Settings ▸
   Network* shows "iPhone USB") with an address like `172.20.10.2`. Turn the
   Mac's Wi-Fi off if you want to be sure it uses only the hotspot.
3. On the Mac: `.build/release/iosgpsspoof doctor` should list the iPhone,
   then run `.build/release/iosgpsspoof serve`. The banner shows
   `172.20.10.x  iPhone Personal Hotspot` under *Reachable at*.
4. In AnyWhere: **Find My Mac**. If the Mac doesn't appear (Bonjour across
   the hotspot isn't guaranteed), tap **Enter an address instead** and type
   the `172.20.10.x` address, port `47653`, and the code.
5. **Start Here**. The Mac log shows `holding … on <iPhone>`; Maps on the
   iPhone jumps to the place.
6. Unplug the cable for a moment: the status shows *Reconnecting*, and when
   you plug it back in the location is re-applied by itself.
7. **Stop**: the real location returns.

The same flow works with both devices on ordinary Wi-Fi, where Bonjour finds
the Mac automatically.

## Security notes

- Only devices on the local network can connect; the server never listens
  for, or forwards, internet traffic, and nothing is exposed through your
  router unless you forward port 47653 yourself (don't).
- Commands need a token, obtained only with the code currently shown on the
  Mac. Codes are single-use; 5 wrong codes lock pairing for 5 minutes and
  burn the code.
- Unpair from the iPhone (Your Mac ▸ Unpair), from the Mac app (Settings ▸
  iPhone Remote), or all at once with `iosgpsspoof serve --forget-paired`.
- Traffic is plain HTTP inside your local network (the token is sent with
  each request). Use networks you trust.

## Troubleshooting

| Symptom | Fix |
|---|---|
| "Can't reach the Mac" | Is `serve` (or the app setting) running? Same network? Firewall asked to allow `iosgpsspoof`? Try the address shown in the banner. |
| Mac not listed | Allow Local Network for AnyWhere (Settings ▸ Privacy & Security ▸ Local Network), or connect by address. |
| "The Mac can't see this iPhone" | Plug it in, unlock it, tap Trust. `iosgpsspoof doctor` should list it. |
| "port 47653 is already in use" | Another helper (or the Mac app's iPhone Remote) is running. Stop one, or use `--port`. |
| "Update the Mac app to use this" | The Mac is running a release from before routes, the joystick or the timer existed. Install the newest AnyWhere on the Mac. |
| The joystick says it needs a live session | Start a location first (tap **Start Here**), and use the live engine (the Mac's Settings ▸ Engine). |
| Starts, then *Retrying* | See the Mac's log; usually Developer Mode is off or the developer disk image needs internet once. |
