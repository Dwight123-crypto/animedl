# AnimeDL

An iPhone app for searching animepahe, queueing episode downloads, and watching them. The downloading is done by [animepahe-dl](https://github.com/KevCui/animepahe-dl), running on your Mac.

```
iPhone app (SwiftUI)  ──HTTP──▶  server/server.py on your Mac  ──▶  animepahe-dl.sh functions
  search · pick episodes            search/episodes API              curl-impersonate + yt-dlp
  queue · stream · save offline     download queue, file serving     → server/downloads/<Show>/<n>.mp4
```

- `server/animepahe-dl/`: the upstream repo, unmodified. Update it with `git -C server/animepahe-dl pull`.
- `server/pahe-job.sh`: sources `animepahe-dl.sh` and downloads one episode without the `fzf` prompts.
- `server/server.py`: a stdlib-only Python HTTP API. It needs a token, and it serves video files with range support.
- `ios/`: the SwiftUI app (iOS 17+). The Xcode project is generated from `project.yml`.

## 1. Mac server

Install the tools that animepahe-dl needs:

```sh
brew install jq fzf ffmpeg
pip install "yt-dlp[default,curl-cffi]"   # already installed on this Mac
```

**curl-impersonate**: download the macOS build from https://github.com/lexiforest/curl-impersonate/releases. Put the `curl-impersonate` binary somewhere on your `PATH` (for example `/opt/homebrew/bin`), then run `xattr -d com.apple.quarantine /path/to/curl-impersonate` so macOS lets it run.

Start the server:

```sh
./server/run.sh
```

It prints the **URL** and **token** to enter in the app. It keeps the Mac awake while it runs. If macOS asks whether Python can accept incoming connections, allow it.

**Cloudflare:** animepahe sits behind Cloudflare. The server reads the `cf_clearance` cookie straight from Chrome on your Mac (`server/chrome_cf.py`, using yt-dlp's cookie decryption) and works out the matching user-agent. It does this at startup, before each download, and whenever Cloudflare blocks a request.
- The first time, macOS asks to let Python use **Chrome Safe Storage**. Click **Always Allow**.
- Visit https://animepahe.pw in Chrome on the Mac at least once.
- If searches still fail, open the site in Chrome again, pass the check, then tap **Settings → Refresh from Chrome** in the app.

## 2. On the iPhone: web app (no cable, no Xcode)

The server also serves the app as a web page (`server/web/`).
1. Start the server. It prints a **Phone** link like `http://192.168.1.6:8765/#token=…`.
2. Open that link in **Safari** on your iPhone, on the same Wi-Fi as the Mac.
3. Tap **Share → Add to Home Screen**. AnimeDL then opens full-screen from its own icon.
   Home Screen apps don't share storage with Safari, so the first time you open it from the icon, paste the token once.

The web app has Search, Queue, Library and Settings, like the native app.
- **Play** streams an episode from the Mac.
- **Save** downloads it to the Files app for offline viewing.

If Cloudflare blocks a request, the server reopens animepahe in Chrome in the background, picks up the fresh cookie and retries. This happens automatically.

## 3. iPhone app (native, optional)

1. Install **Xcode** from the Mac App Store. Open it once so it installs the iOS components.
2. Generate the project:
   ```sh
   brew install xcodegen
   cd ios && xcodegen && open AnimeDL.xcodeproj
   ```
3. In Xcode, go to **Settings → Accounts**, add your Apple ID, then select the AnimeDL target → **Signing & Capabilities** → choose your *Personal Team*.
   If Xcode says the bundle ID is taken, change `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`, then run `xcodegen` again.
4. Plug in your iPhone and turn on **Developer Mode** (Settings → Privacy & Security). Select the phone in Xcode and press **Run**.
5. On the phone, trust the developer profile: Settings → General → VPN & Device Management.

With a free Apple ID, the app stops opening after 7 days. Plug the phone in and press Run again to reinstall it. Your settings and saved episodes are kept.

### iPhone app without Xcode (GitHub Actions)

Every push that changes `ios/` runs [.github/workflows/build-ios.yml](.github/workflows/build-ios.yml) on a GitHub macOS runner. It builds an **unsigned** `AnimeDL.ipa`. You can also start a build by hand from the Actions tab, or with `gh workflow run build-ios.yml`.

1. Download the IPA from the latest run:
   ```sh
   gh run download --name AnimeDL-ipa --dir ~/Downloads
   ```
2. Install it with your free Apple ID using [Sideloadly](https://sideloadly.io) or [AltStore](https://altstore.io) on the Mac, with the iPhone plugged in. They sign the IPA for you.
   AltStore can also re-sign the app over Wi-Fi before the 7-day limit, as long as AltServer is running on the Mac.
3. On the iPhone, turn on Developer Mode (Settings → Privacy & Security) if you're asked to.

## Using it

- **Settings**: enter the server URL and token, then tap *Test Connection*. It shows any missing tools and whether the Cloudflare cookie is set.
- **Search**: find a show, select episodes, choose resolution and audio, then tap *Download*. The Mac downloads them one at a time.
- **Queue**: shows live progress. Swipe a job to cancel, remove or retry it.
- **Library → On Mac**: tap an episode to stream it, tap ↓ to save it to the phone, or swipe to delete it from the Mac.
- **Library → On iPhone**: episodes saved for offline viewing. They also appear in the Files app under *On My iPhone → AnimeDL*.

**Away from home:** install [Tailscale](https://tailscale.com) on the Mac and the iPhone, then use the Mac's Tailscale address (`http://100.x.y.z:8765`) as the server URL. Don't forward the port on your router.

## Notes

- If the resolution or audio you chose isn't available, animepahe-dl falls back to 1080p.
- To use a different downloads folder, start the server with `ANIMEDL_DIR=~/Movies/Anime ./server/run.sh`.
- The queue is kept in memory, so restarting the server clears it. Files that were already downloaded stay in the library.
- Upstream, animepahe-dl sends the kwik player's obfuscated JavaScript to glot.io to run it. That still happens here, from the Mac.
