# Lidbend

A macOS menu-bar app that bends your live desktop as you close the lid, in the
spirit of the fold transition on the new dual-screen iPhone.

The desktop is captured with ScreenCaptureKit, leaned away from its bottom edge
in Metal, and driven by the real hinge-angle sensor in Apple silicon MacBooks.
As the lid comes down the desktop tilts back, blurs and shades toward the top
while the base stays crisp; when you open it again the effect unwinds and
clears.

## Website

The landing page lives in `docs/` as a single self-contained `index.html`, so
GitHub Pages can serve it straight from the repository: Settings › Pages ›
Deploy from a branch › `main` and `/docs`. It carries the same scroll-driven
lid demo as the app's preview, a screenshot of the settings window, and the
donation addresses below.

## Support

Lidbend is free and open source. If it made you smile, a coin helps keep it
maintained:

| Coin | Address |
| --- | --- |
| Bitcoin (BTC) | `bc1qy46kag7z0muc4xjptq4x07m53qmqyczwpsm59t` |
| Ethereum (ETH) | `0x9972519894861132cbc98D869C174E2235D165c2` |

## Requirements

- macOS 14 or later
- Apple silicon MacBook with a lid-angle sensor (there is a manual angle slider
  as a fallback, so it still runs on other Macs)
- Screen Recording permission
- Swift toolchain (Xcode or the Command Line Tools — the shaders are compiled at
  runtime, so the offline `metal` compiler is not needed)

## Install

Grab `Lidbend-x.y.zip` from the [latest release](https://github.com/behkha/lidbend/releases/latest),
unzip it and drag `Lidbend.app` to Applications.

The app is ad-hoc signed and not notarized, so macOS blocks the first launch.
Open it once, dismiss the warning, then go to System Settings › Privacy &
Security and choose **Open Anyway**. Or clear the quarantine flag instead:

```bash
xattr -dr com.apple.quarantine /Applications/Lidbend.app
```

## Build and run

```bash
./build.sh --run
```

That produces `dist/Lidbend.app` and launches it. `./build.sh --debug` builds the
debug configuration instead, and `./build.sh --package` zips the app into
`dist/Lidbend-<version>.zip` for a release.

Releases are built by GitHub Actions: push a `v*` tag and
`.github/workflows/release.yml` builds, packages and publishes it.

## Screen Recording permission

Lidbend never raises the consent dialog on its own. If permission is missing the
settings window says so and offers **Allow…**, which prompts once, and
**System Settings**, which opens the right pane. macOS caches the answer for the
lifetime of the process, so after granting it in System Settings you generally
have to quit and reopen Lidbend before capture starts.

### Making the grant survive rebuilds

Consent is bound to the app's code signature. An ad-hoc signature is identified
by its cdhash, which changes every time you rebuild — so macOS sees a brand-new
app and asks again. Signing with a stable local certificate fixes that:

```bash
./build.sh --setup-signing
```

That generates a self-signed code-signing certificate called `Lidbend Local`,
imports it into your login keychain, and marks it trusted for code signing —
macOS will ask for your password for the trust step. It runs once. Every later
`./build.sh` picks the certificate up automatically, and the Screen Recording
grant then holds across rebuilds.

Without it the build still works; you will just be re-granting permission after
every rebuild.

## How it behaves

Lidbend keys off *closing motion*, not an absolute angle. A reference angle
tracks the hinge quickly as you open the lid and drifts down slowly, so the angle
you normally work at is treated as "open" and the effect only engages once the
lid drops **Sensitivity** degrees below it. The bend reaches full strength at
**Full bend at**.

The overlay is click-through, is excluded from its own capture, sits on the
built-in display only, and hides itself if frames stop arriving — so a stall
cannot leave your screen covered.

## Settings

The settings window has three pages in a sidebar, System Settings style.

**Appearance** shows a live preview framed as a MacBook, an angle slider with a
**Follow lid** switch, and the three styles as cards.

| Control | Effect |
| --- | --- |
| Angle / Follow lid | Follow the hinge sensor, or switch it off and drag the angle yourself |
| Style | `Silk` warm sheen, `Shade` deep shadow, `Frost` cool diffusion |
| Perspective | Camera distance; higher is a wider, more dramatic lens |
| Variable blur | Strength of the progressive blur that builds toward the top |
| Shadow | Shading strength in the far corners and along the top |
| Intensity | Peak lean angle at a fully closed lid |
| Softness | Radius of the bend arc — low values read as a hard crease |
| Bend line | `Lid` hinges at the bottom edge, `Duo` folds across the middle, `Custom` anywhere |

**General** holds the on/off switches (effect, sound, launch at login), the
trigger controls (**Sensitivity**, **Full bend at**, **Smoothing**) and a
status readout of the hinge, resting angle, bend and Screen Recording state.
**About** has the version, a reset button and Quit.

## Layout

| File | Role |
| --- | --- |
| `LidAngleSensor.swift` | Reads the hinge angle over HID (usage page `0x20`, usage `0x8A`) |
| `DesktopCapture.swift` | ScreenCaptureKit stream into a Metal texture |
| `ShaderSource.swift` | Metal source for the background, blur and bend passes |
| `BendRenderer.swift` | Geometry, uniforms and the render passes |
| `OverlayController.swift` | The full-screen click-through overlay window |
| `AppController.swift` | Angle tracking, engagement, capture lifecycle |
| `MenuBarController.swift` | Status item and settings window |
| `SettingsView.swift` | Sidebar settings window: General, Appearance, About |
| `PreviewView.swift` | Live Metal preview and the MacBook frame around it |
| `PlaceholderScene.swift` | Stand-in desktop for the style cards and permission-less previews |

## Notes on the effect

The panel bends over a circular arc of radius `softness` and then continues
straight, which keeps the surface smooth instead of creasing. Clip-space `w`
carries the depth, so the GPU does the perspective divide and texture sampling
stays perspective-correct across the whole panel. The bend line stays anchored
on screen, so the base of the desktop never moves and only the top recedes.

Sharpness falls off toward the top rather than uniformly: the desktop is
blurred into a three-level pyramid, each level half the size and blurred on top
of the last, and the fragment shader stacks the three copies in bands that
reach progressively less far down the panel. A shade of dark pools in the far
corners plus a wash from the top edge gives the lean its depth, and the top
edge itself is feathered to transparent over a band that grows with the bend.

Motion runs through one smoothstep curve for tilt, blur, shade and feather, on
top of a critically damped spring that smooths the whole-degree hinge readings.
The spring is stepped at 120 Hz and the overlay renders at the display's own
refresh rate, so ProMotion panels get a fresh value on every frame.
