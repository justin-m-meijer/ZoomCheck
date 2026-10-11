# ZoomCheck

How often do you really use your iPhone's telephoto lens? ZoomCheck reads your Photos library on the Mac and shows how many of your photos were taken above a given zoom level, so you can judge whether a phone with less zoom (say, one that tops out at 2x) would cost you shots you care about.

Everything runs locally. Nothing leaves your Mac.

## What it shows

- Your iPhone photos split into 0.5x, 1x, 2x up to the target zoom, and above the target zoom
- Above the target, a split between **real telephoto shots** (what you'd lose) and **main-camera crops** (the other phone can do those too)
- Breakdown per iPhone model
- Optional filters: region (rough bounding box, or a custom one) and date range, e.g. a single trip
- One click to put the "lost" photos in a Photos album, which syncs to your iPhone via iCloud

## Download

Get the latest `ZoomCheck-vX.Y.Z.zip` from [Releases](../../releases), unzip it and move ZoomCheck to Applications. It runs on Apple silicon and Intel Macs.

If a release is marked as not notarized, macOS blocks the first launch. Open ZoomCheck once, then go to System Settings → Privacy & Security and click **Open Anyway**.

## Requirements

- macOS 14 Sonoma or later
- Xcode or the Xcode Command Line Tools (`xcode-select --install`)
- Photos library on the Mac with iCloud Photos (originals do **not** need to be downloaded)

## Build from source

```bash
git clone <repo-url> ZoomCheck
cd ZoomCheck
./scripts/build-app.sh
open build/ZoomCheck.app
```

On first launch ZoomCheck will say it has no access. Click **Open Full Disk Access settings**, turn on ZoomCheck (add it with **+** if it's not listed), quit ZoomCheck with ⌘Q and open it again.

The app is ad-hoc signed. After every rebuild macOS may treat it as a new app, and you'll need to toggle Full Disk Access off and on again.

For development, `swift run` also works when your terminal app has Full Disk Access. Creating an album only works from the `.app` bundle, because PhotoKit requires the usage description in `Info.plist`.

## How it works

The zoom level of a photo isn't stored as "2x". iPhones record two focal lengths in EXIF:

| Field | Meaning |
|---|---|
| `FocalLength` | Real focal length of the lens that took the photo |
| `FocalLengthIn35mmFilm` | 35mm equivalent, which goes up with every zoom step, including crops |

On recent Pro models, 2x is a crop of the 48 MP main sensor: same lens, same real focal length as 1x, only the 35mm value doubles (24 → 48 mm). Photos keeps both values in its own database (`ZEXTENDEDATTRIBUTES`), so ZoomCheck can read them without downloading any originals from iCloud.

- **Zoom level** = 35mm value ÷ 24 mm, with a 15% margin so older 52 mm "2x" lenses count as 2x
- **Crop vs. telephoto**: for each iPhone model ZoomCheck finds the real focal length of its 1x shots (the main camera). A photo above the target whose real focal length matches that is a crop; otherwise it came from a telephoto lens.

ZoomCheck copies `Photos.sqlite` (plus its `-wal`/`-shm` files) to a temporary folder, reads the copy and deletes it. The live library is never opened for writing. Album creation goes through Apple's PhotoKit API.

## Limitations

- Reads Apple's private, undocumented database schema. A macOS update can change it. ZoomCheck checks the columns it needs on every load and shows which ones are missing instead of giving wrong numbers.
- iPhone photos only (`Make = Apple`). Dedicated cameras with zoom lenses don't have a fixed "1x".
- Region filters are rectangles and overlap slightly with neighbouring countries. Photos without location are excluded when a region is set, and the app tells you how many.
- Not suitable for the Mac App Store: the sandbox doesn't allow reading the Photos database directly.

## License

MIT. See [LICENSE](LICENSE).
