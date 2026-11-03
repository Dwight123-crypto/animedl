"""Print animepahe's cf_clearance cookie and Chrome's user-agent as JSON.

Run with yt-dlp's own Python (server.py does this), so yt-dlp's cookie code
handles the Keychain lookup and decryption. The first run makes macOS ask for
access to "Chrome Safe Storage"; click Always Allow.
"""

import json
import re
import subprocess
import sys
from pathlib import Path

from yt_dlp.cookies import extract_cookies_from_browser

DOMAIN = "animepahe.pw"
CHROME_APP = "/Applications/Google Chrome.app"
CHROME_DATA = Path.home() / "Library/Application Support/Google/Chrome"


class QuietLogger:
    def debug(self, *a, **k): pass
    def info(self, *a, **k): pass
    def warning(self, *a, **k): pass
    def error(self, msg, *a, **k): print(msg, file=sys.stderr)


def chrome_major_version():
    # Prefer the running Chrome: after an update Chrome keeps running the old
    # version until relaunched, and the cookie belongs to that one.
    ps = subprocess.run(["ps", "-axo", "command"], capture_output=True, text=True).stdout
    m = re.search(r"Google Chrome Framework\.framework/Versions/(\d+)\.", ps)
    if m:
        return m.group(1)
    v = subprocess.run(["defaults", "read", f"{CHROME_APP}/Contents/Info", "CFBundleShortVersionString"],
                       capture_output=True, text=True).stdout.strip()
    return v.split(".")[0]


def main():
    profiles = [p.name for p in CHROME_DATA.iterdir()
                if p.name == "Default" or p.name.startswith("Profile ")] if CHROME_DATA.exists() else []
    best = None
    for profile in profiles:
        try:
            jar = extract_cookies_from_browser("chrome", profile=profile, logger=QuietLogger())
        except Exception as e:
            print(f"{profile}: {e}", file=sys.stderr)
            continue
        for c in jar:
            if c.name == "cf_clearance" and c.domain.lstrip(".").endswith(DOMAIN):
                # Newest cookie = latest expiry (they're issued for a fixed lifetime).
                if best is None or (c.expires or 0) > (best[1].expires or 0):
                    best = (profile, c)
    if not best:
        sys.exit(f"No cf_clearance cookie for {DOMAIN} in Chrome. Open https://{DOMAIN} in Chrome first.")

    ua = (f"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
          f"(KHTML, like Gecko) Chrome/{chrome_major_version()}.0.0.0 Safari/537.36")
    print(json.dumps({"cf": best[1].value, "ua": ua, "profile": best[0]}))


if __name__ == "__main__":
    main()
