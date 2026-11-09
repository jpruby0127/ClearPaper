<p align="right"><a href="README.md">中文</a> · English</p>

<p align="center">
  <img src="docs/screenshots/logo.png" width="120" alt="ClearPaper logo">
</p>

<h1 align="center">ClearPaper</h1>

<p align="center">
  <b>Turn blurry, dark, scan-framed exam-PDFs into print-ready, crisp A4 — in one step.</b><br>
  Native macOS + iOS apps. <b>100% on-device, zero dependencies, no network, no server.</b>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%20%7C%20iOS-000000" alt="platform">
  <img src="https://img.shields.io/badge/language-Swift%20%2F%20Python-orange" alt="language">
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="license">
  <img src="https://img.shields.io/badge/engine-100%25%20on--device-green" alt="on-device">
</p>

---

## ✨ Why this exists

Scans and phone photos of exam papers usually come with problems:

- Page size is absurd (e.g. 28×41 in) → prints get shrunk to 25%
- Black scan borders / page-curl shadows around the edges
- iPhone Notes "white canvas" wasting ~25% of the page
- Photos mixed with text → grey, broken strokes
- Low native resolution → blurry when scaled

**ClearPaper fixes all of that.** It detects the problem, processes per-region, and outputs a standard **210×297 mm A4** PDF — guarded by a **quality gate** that refuses to drop any real ink.

> Verified: physics paper 7 A4 pages, **100%** stroke retention; biology paper 8 A4 pages, 190 mm sheet width, **100%** retention.

## 📸 Results

<p align="center">
  <img src="docs/screenshots/mac-ui.png" width="760" alt="macOS UI">
  <br><sub>macOS 1.3: sidebar + card layout for Process / Settings / Help</sub>
</p>

Same page: reference Python engine (left) vs the Swift on-device engine compiled into the app — **identical output**, proving the phone/desktop runs the same algorithm:

<p align="center">
  <img src="docs/screenshots/compare-physics.png" width="640" alt="physics comparison">
  <br><sub>Physics: Python engine (left) vs Swift on-device engine (right)</sub>
</p>

<p align="center">
  <img src="docs/screenshots/compare-biology.png" width="640" alt="biology comparison">
  <br><sub>Biology: Python engine (left) vs Swift on-device engine (right)</sub>
</p>

Result card on iPhone (fully on-device: import PDF → process → print / share / save):

<p align="center">
  <img src="docs/screenshots/ios-result.png" width="300" alt="iOS result">
</p>

## 🚀 Quick start (no build)

### macOS · drag into Applications

1. Download **`ScanClean-macOS-1.3.1.dmg`** from [Releases](https://github.com/jpruby0127/ClearPaper/releases);
2. Open the DMG and drag "试卷清晰化" into Applications;
3. If blocked on first launch: right-click the app → Open → Open.

The app bundles its own engine — **no Python, venv, or config needed** on the friend's Mac. Drop a PDF onto the window (or the Dock icon, multiple at once). Output defaults to `Documents/试卷清晰版`; change it via **File › 选择输出文件夹…**.

> **New: multi-file merge.** Merge several PDFs into one in the order you added them — either **full** (straight concatenation) or **duplex-safe** (a blank page after each document so two papers never share a sheet when printing double-sided). Drag rows to reorder.

### iPhone / iPad · self-sign once, keep forever

1. Download **`ScanClean-iOS-1.2.1-unsigned.ipa`** from [Releases](https://github.com/jpruby0127/ClearPaper/releases);
2. On your computer install [Sideloadly](https://sideloadly.io/) (or AltStore), connect the iPhone, pick this IPA, sign with your Apple ID;
3. On the phone: Settings → General → VPN & Device Management → trust the developer;
4. In WeChat, open a paper → "Open in another app" → choose 试卷清晰化; or tap "导入试卷 PDF" in the app.

> Free personal signatures last **7 days**; re-sign once when expired. Files stay on the device.

### Windows · portable, no install

1. Download **`ScanClean-Windows-portable.zip`** from [Releases](https://github.com/jpruby0127/ClearPaper/releases);
2. Extract the whole `ScanClean` folder (not just a single file);
3. Drag PDFs onto `ScanClean.bat` (several at once); results land next to each source as `<name>-清晰版.pdf`.

Python and all dependencies are bundled — **no registry, no network, delete the folder to uninstall**. If SmartScreen blocks the first run, click "More info → Run anyway". Windows 10/11 64-bit.

## 🧠 What it detects & fixes

| Detected issue | Fix |
|---|---|
| Absurd MediaBox (e.g. 28×41 in) | Rebuild to standard A4 (no more 25% shrink) |
| Scan borders / edge shadows | Connected-component + edge-strip removal (keeps underline blanks) |
| iPhone Notes white canvas | Crop back to paper, recover wasted 25% |
| Photo + text mixed | Per-region: deepen text, keep photo tones |
| Low resolution | Uniform placement per batch; resample to ~300 DPI if below 230 |
| Landscape pages | Output A4 landscape (297×210 mm); mixed portrait/landscape matched per page, no clipping |

Gamma is not hard-coded: it steps up until real strokes are genuinely black (stroke-brightness median ≤105).

### Quality gate (runs on every output)

- Compare at four thresholds — **no real ink may be clipped**
- **Stroke retention ≥97%** (connected-component level, not fooled by JPEG noise)
- Page must be **210×297 mm**
- Page count matches the source

Two hard-won fixes are already in: flat-field correction switched from additive to **multiplicative white-point normalization** (faint strokes no longer pushed to white); unsharp mask replaced by **darken-only sharpening** (stroke loss dropped from 7.9% to 0–1%).

## 🛠 Build from source

Clone and build either app — **no third-party dependencies** (Swift stdlib + system frameworks only).

```bash
git clone https://github.com/jpruby0127/ClearPaper.git
cd ClearPaper
```

### macOS app

```bash
cd macos
./build_app.sh                 # non-sandbox + hardened runtime → ~/Applications/试卷清晰化.app
# SANDBOX=1 ./build_app.sh     # App Store sandbox build
# SIGN_ID="Your Cert" ./build_app.sh
```

### iOS app (unsigned IPA for self-signing)

```bash
cd ios
./build_ios.sh ../ScanClean-iOS-unsigned.ipa
```

Run it in the simulator:

```bash
./build_sim.sh shot.png        # build, install, launch, optional screenshot
```

> Needs Xcode command-line tools + iOS SDK (`xcode-select --install`). Icons are committed, so the build needs no Python.

## 🐍 Python reference engine (optional)

The macOS/iOS apps use the **compiled-in Swift engine** (distributable, zero-dep). `python/` holds the **same algorithm as a reference implementation** for study, batch jobs, or servers:

```bash
cd python
pip install -r requirements.txt
./bin/scanpdf some-paper.pdf     # outputs <name>-清晰版.pdf
./bin/scanpdf --check
```

## 🗺 Roadmap

- [ ] Multi-page stitching / duplex paper merge
- [ ] Custom output paper (B5 / Letter) and DPI
- [ ] Desktop folder-watch daemon
- [ ] Optional OCR text layer (keeps original image)
- [ ] Windows / Linux CLI builds

Issues and PRs welcome — let's make this a real open-source gem together.

## 📦 Releases

| Version | Platform | Artifact | Notes |
|---|---|---|---|
| v1.3.1 | macOS | `ScanClean-macOS-1.3.1.dmg` | New sidebar UI; multi-file merge + landscape A4 fix |
| v1.2.1 | iOS | `ScanClean-iOS-1.2.1-unsigned.ipa` | Native app, fully on-device, self-sign to install |
| v1.0.1 | Windows | `ScanClean-Windows-portable.zip` | Portable, bundled Python + deps, drag-and-drop |

> Current distribution uses a local **Apple Development** certificate: the Mac DMG opens on the same account; for others, re-sign with a **Developer ID** and notarize via `notarytool` (command ready, no code change). iOS free signatures last 7 days.

## 📄 License

[MIT](LICENSE) — use it, fork it, ship it; just keep the attribution.

---

<p align="center">An offline exam-paper clarifier in Swift · your data never leaves the device · open and print</p>
