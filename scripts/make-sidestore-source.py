#!/usr/bin/env python3
"""Write AnyWhere's SideStore / AltStore source (source.json) for one release.

SideStore reads this file to offer AnyWhere, install new versions and keep the app refreshed on the
iPhone, with no computer. Each GitHub Release publishes it next to AnyWhere.ipa, so the stable address
https://github.com/<repo>/releases/latest/download/source.json always describes the newest one.

Format: https://faq.altstore.io/developers/make-a-source (SideStore reads the same format).

    scripts/make-sidestore-source.py --tag v2.6.0 --ipa artifacts/AnyWhere-ipa/AnyWhere.ipa > source.json

The version and build come from iPhoneRemote/project.yml unless given. The privacy strings are read
from the IPA's own Info.plist: AltStore refuses an app whose permissions differ from its source.
"""
import argparse
import datetime
import json
import os
import plistlib
import re
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def project_setting(name):
    with open(os.path.join(ROOT, "iPhoneRemote", "project.yml"), encoding="utf-8") as f:
        match = re.search(rf'^\s*{name}:\s*"?([^"\n]+)"?\s*$', f.read(), re.M)
    return match.group(1).strip() if match else None


def privacy_strings(ipa):
    """The usage strings of the app inside the IPA itself, so the source can't disagree with it."""
    with zipfile.ZipFile(ipa) as archive:
        name = next(n for n in archive.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n))
        info = plistlib.loads(archive.read(name))
    return {key: value for key, value in sorted(info.items())
            if key.startswith("NS") and key.endswith("UsageDescription")}


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--tag", required=True, help="release tag, for example v2.6.0")
    parser.add_argument("--ipa", required=True, help="the release's AnyWhere.ipa (for its size)")
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "renyifan2009-hash/iOS-GPS-Spoofer-V1.2.3"))
    parser.add_argument("--version", default=project_setting("MARKETING_VERSION"))
    parser.add_argument("--build", default=project_setting("CURRENT_PROJECT_VERSION"))
    parser.add_argument("--date", default=datetime.date.today().isoformat())
    args = parser.parse_args()

    raw = f"https://raw.githubusercontent.com/{args.repo}/main"
    download = f"https://github.com/{args.repo}/releases/download/{args.tag}/AnyWhere.ipa"
    source = {
        "name": "AnyWhere",
        "identifier": "com.iosgpsspoof.source",
        "subtitle": "Change your iPhone's location, privately.",
        "description": "AnyWhere sets your iPhone's GPS location: teleport, drive a route with stops, or steer "
                       "with a joystick. Add this source in SideStore to get updates and keep AnyWhere "
                       "refreshed on the iPhone, with no computer.",
        "iconURL": f"{raw}/brand/AnyWhere-ios-1024.png",
        "website": f"https://github.com/{args.repo}",
        "tintColor": "#5E8B85",
        "nsfw": False,
        "featuredApps": ["com.iosgpsspoof.remote"],
        "apps": [{
            "name": "AnyWhere",
            "bundleIdentifier": "com.iosgpsspoof.remote",
            "developerName": "AnyWhere",
            "subtitle": "Change your iPhone's location, privately.",
            "localizedDescription": "Teleport anywhere, drive a route on real roads with rest stops, or steer "
                                    "with a joystick. The iPhone-only mode needs a pairing file and LocalDevVPN.",
            "iconURL": f"{raw}/brand/AnyWhere-ios-1024.png",
            "tintColor": "#5E8B85",
            "category": "utilities",
            "screenshots": [f"{raw}/img/iphone-joystick.png", f"{raw}/img/iphone-route.png"],
            "versions": [{
                "version": args.version,
                "buildVersion": args.build,
                "date": args.date,
                "localizedDescription": f"AnyWhere {args.version}. See the release notes on GitHub.",
                "downloadURL": download,
                "size": os.path.getsize(args.ipa),
                "minOSVersion": "17.0",
            }],
            "appPermissions": {"entitlements": [], "privacy": privacy_strings(args.ipa)},
        }],
        "news": [],
    }
    json.dump(source, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
