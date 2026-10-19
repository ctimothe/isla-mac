#!/usr/bin/python3 -I
# Writes the local update feed's release.json: the answer Isla reads in place
# of GitHub's releases/latest when it follows the feed (UpdateSource.localFeed).
# Called by publish-dev-update.sh; its own file so a test can run exactly the
# writer the script runs (UpdateSourceTests.testTheReleaseThePublishScriptWritesIsOffered).
#
#   dev-feed-release.py OUT FEED VERSION BUILD COMMIT DMG_SIZE SIG_SIZE NOTES
#
# Every field is held to the rules a GitHub answer is held to. The page must be
# under Isla's own GitHub releases (UpdateCheck.isTrustedReleasePage, G-027):
# the first version of the publish script named the commit's page instead, and
# the check refused every release the feed had. A dev build is not on GitHub,
# so the page does not exist there; Update Now installs it in place, and the
# page is only what the card's download link would open if this copy could
# not update itself.
import json
import sys
from pathlib import Path

out, feed, version, build, commit, size, sig_size, notes = sys.argv[1:9]
image = f"Isla-{version}.dmg"


def file_url(name):
    # Percent-encoded, so a folder with a space or a "#" in its path is a
    # file URL Isla reads as that path, not a fragment or nothing.
    return Path(feed, name).as_uri()


release = {
    "tag_name": f"v{version}",
    "html_url": f"https://github.com/ctimothe/isla-mac/releases/tag/v{version}",
    "draft": False,
    "prerelease": False,
    "body": notes,
    "assets": [
        {"name": image, "size": int(size), "browser_download_url": file_url(image)},
        {"name": f"{image}.sig", "size": int(sig_size), "browser_download_url": file_url(f"{image}.sig")},
    ],
    # Read back by the publish script only (Isla's decoder ignores them): the
    # build and commit the next publish counts from.
    "isla_build": int(build),
    "isla_commit": commit,
}
with open(out, "w") as f:
    json.dump(release, f, indent=2)
    f.write("\n")
