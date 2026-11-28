# Landing page media

Every picture on `docs/index.html` is the AnyWhere iPhone app itself, captured in the iOS 27 Simulator
(iPhone 18 Pro) against a local `iosgpsspoof serve` with `Tests/Fixtures/fake-pymobiledevice3`, so the
app shows real screens with "Simulating · MacBook Pro". The maps inside them are Apple Maps.

| File | What it shows | Taken from |
|---|---|---|
| `hero-tokyo.webp` | Teleport, simulating at Tokyo Tower | frame of the teleport demo recording (2026-11-25) |
| `hero-eiffel.webp`, `hero-goldengate.webp`, `hero-sydney.webp` | Teleport, simulating at each place | Simulator screenshots (2026-11-25) |
| `hero-ready.webp` | Teleport, ready, nothing simulated | Simulator screenshot (2026-11-25) |
| `plate-teleport.webp` | Search suggestions for "Tokyo Tower" | frame of the teleport demo recording |
| `route.mp4`, `route-poster.webp` | A 3-stop route in Tokyo driving, 4× speed | the route demo recording, 0:36–1:38 |
| `route-build.webp` | The same route built: 3 stops, 0.5 mi, about 1 min | frame of the route demo recording |
| `plate-joystick.webp` | Joystick tab, simulating at the Sydney Opera House | Simulator screenshot (2026-11-25) |
| `setup-code.webp` | This iPhone ▸ Set Up, Get from My Mac with the code 421 943 | frame of the setup demo recording |
| `paywall.webp` | AnyWhere Pro plans | Simulator, launched with `-SpoofRemoteShow paywall` |
| `ground-satellite.webp` | Satellite map around Apple Park (background only) | Simulator screenshot with `-mapHybrid YES` |

Crops are 1206 px wide screens cut with ffmpeg and encoded with `cwebp -q 76`; the route loop is
H.264, 720×720, CRF 30, no audio.
