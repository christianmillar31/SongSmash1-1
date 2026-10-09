#!/usr/bin/env python3
"""Mint the Apple Music developer token the app loads from GitHub Pages.

Signs a JWT with the Media Services (MusicKit) private key, valid for Apple's
maximum of about six months, and writes it to docs/music-token.txt. Merge that
file to main and GitHub Pages serves it at
https://christianmillar31.github.io/SongSmash1-1/music-token.txt; installed
apps pick it up on their next launch, no app update needed.

The app stops trusting a token a day before it expires, then falls back to the
smaller iTunes catalog — so re-run this well before the expiry it prints.

    python3 native/tools/mint-music-token.py KEY_ID

Expects the key at ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8.
Needs: pip install pyjwt cryptography
"""
import pathlib
import sys
import time
from datetime import datetime, timezone

import jwt

TEAM_ID = "F7MGX6469C"
LIFETIME = 15_777_000  # Apple's cap for developer tokens: six months
REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
OUTPUT = REPO_ROOT / "docs" / "music-token.txt"


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    key_id = sys.argv[1]
    key_path = pathlib.Path.home() / ".appstoreconnect" / "private_keys" / f"AuthKey_{key_id}.p8"
    now = int(time.time())
    token = jwt.encode(
        {"iss": TEAM_ID, "iat": now, "exp": now + LIFETIME},
        key_path.read_text(),
        algorithm="ES256",
        headers={"kid": key_id},
    )
    OUTPUT.write_text(token + "\n")
    expires = datetime.fromtimestamp(now + LIFETIME, tz=timezone.utc)
    print(f"Wrote {OUTPUT.relative_to(REPO_ROOT)} — expires {expires:%Y-%m-%d}. Renew before then.")


if __name__ == "__main__":
    main()
