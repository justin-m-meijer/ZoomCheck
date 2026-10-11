# Releasing

Every push to `main` builds a universal app on GitHub Actions and attaches it as a workflow artifact.

To publish a GitHub Release, either:

- go to Actions → **Build** → **Run workflow**, enter a version such as `0.2.0`, and run it (the workflow creates the `v0.2.0` tag and the release), or
- push a tag yourself: `git tag v0.2.0 && git push origin v0.2.0`

## Signing and notarization (optional, recommended)

Without these secrets, releases are ad-hoc signed and macOS blocks the first launch. With them, the app is signed with your Developer ID, notarized by Apple and opens normally. A properly signed app also keeps its Full Disk Access permission across updates.

Requires a paid Apple Developer Program membership.

| Secret | How to get it |
|---|---|
| `MACOS_CERTIFICATE` | Create a **Developer ID Application** certificate (Xcode → Settings → Accounts → Manage Certificates → + ). Export it from Keychain Access as `.p12`, then `base64 -i cert.p12 \| pbcopy` |
| `MACOS_CERTIFICATE_PASSWORD` | The password you set when exporting the `.p12` |
| `NOTARY_KEY` | App Store Connect → Users and Access → Integrations → App Store Connect API → generate a key with the **Developer** role. Download the `.p8`, then `base64 -i AuthKey_XXXX.p8 \| pbcopy` |
| `NOTARY_KEY_ID` | The Key ID shown next to that key |
| `NOTARY_ISSUER_ID` | The Issuer ID shown at the top of that page |

Add them under the repository's Settings → Secrets and variables → Actions.
