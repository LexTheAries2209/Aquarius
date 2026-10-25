#!/usr/bin/env python3
"""Read-only check that Sparkle clients can verify the public Aquarius appcast."""

import argparse
import json
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import time


def run(*args):
    return subprocess.run(args, check=True, text=True, capture_output=True, timeout=90)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, type=pathlib.Path, help="Verified current Aquarius.app")
    parser.add_argument("--sparkle-root", required=True, type=pathlib.Path)
    parser.add_argument("--previous-build", required=True,
                        help="Actual CFBundleVersion of the last published App; use 1 for V1.2.1.")
    parser.add_argument("--feed-url", help="Optional HTTPS staging feed URL.")
    args = parser.parse_args()

    app = args.app.resolve()
    sparkle = args.sparkle_root.resolve()
    framework = sparkle / "Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
    if not framework.is_dir():
        framework = sparkle / "Sparkle.framework"
    if not framework.is_dir():
        parser.error("--sparkle-root must contain Sparkle.framework or Sparkle.xcframework.")
    with (app / "Contents/Info.plist").open("rb") as stream:
        release_info = plistlib.load(stream)
    if release_info.get("CFBundleIdentifier") != "lex.Aquarius":
        parser.error("--app must be the built Aquarius release App.")

    cache = pathlib.Path.home() / "Library/Caches/AquariusUpdateFixtures"
    cache.mkdir(parents=True, exist_ok=True)
    root = pathlib.Path(tempfile.mkdtemp(prefix="published-feed-", dir=cache))
    executable = root / "SparkleFeedProbe"
    source = pathlib.Path(__file__).resolve().parents[1] / "script/fixtures/SparkleFeedProbe.swift"
    run(
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-F", str(framework.parent), "-framework", "Sparkle",
        "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
        str(source), "-o", str(executable)
    )

    results = []
    builds = [("previous", args.previous_build), ("current", release_info["CFBundleVersion"])]
    for label, build in builds:
        probe = root / label / "AquariusFeedProbe.app"
        contents = probe / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        (contents / "Frameworks").mkdir()
        shutil.copy2(executable, contents / "MacOS/SparkleFeedProbe")
        shutil.copytree(framework, contents / "Frameworks/Sparkle.framework", symlinks=True)
        output = root / f"{label}.json"
        info = {
            "CFBundleIdentifier": f"lex.Aquarius.FeedProbe.{root.name}.{label}",
            "CFBundleName": "Aquarius Feed Probe",
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "SparkleFeedProbe",
            "CFBundleVersion": build,
            "CFBundleShortVersionString": release_info["CFBundleShortVersionString"],
            "SUFeedURL": args.feed_url or release_info["SUFeedURL"],
            "SUPublicEDKey": release_info["SUPublicEDKey"],
            "SURequireSignedFeed": True,
            "SUVerifyUpdateBeforeExtraction": True,
            "SUSignedFeedFailureExpirationInterval": 0,
            "SUEnableAutomaticChecks": False,
            "SUAutomaticallyUpdate": False,
            "SUEnableSystemProfiling": False,
            "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
            "AquariusProbeOutputPath": str(output),
        }
        with (contents / "Info.plist").open("wb") as stream:
            plistlib.dump(info, stream)
        run("codesign", "--force", "--sign", "-", str(probe))
        run("open", "-n", "--stdout", str(root / f"{label}.stdout.log"),
            "--stderr", str(root / f"{label}.stderr.log"), str(probe))

        deadline = time.monotonic() + 40
        while time.monotonic() < deadline and not output.exists():
            time.sleep(0.2)
        if not output.exists():
            executable_path = str(contents / "MacOS/SparkleFeedProbe")
            processes = run("ps", "-axo", "pid=,command=").stdout
            for line in processes.splitlines():
                pid, _, command = line.strip().partition(" ")
                if command.strip() == executable_path:
                    run("kill", "-TERM", pid)
            raise RuntimeError(f"Feed probe timed out; retained logs at {root}")

        result = json.loads(output.read_text())
        results.append({"hostBuild": build, **result})
        if label == "previous":
            if result.get("result") != "available":
                raise AssertionError(f"Previous build did not discover the update: {result}")
            if result.get("build") != release_info["CFBundleVersion"]:
                raise AssertionError(f"Feed version does not match the archive: {result}")
            if result.get("version") != release_info["CFBundleShortVersionString"]:
                raise AssertionError(f"Feed marketing version does not match the archive: {result}")
        elif result.get("result") != "upToDate":
            raise AssertionError(f"Current build should find no newer update: {result}")

    print(json.dumps({"results": results, "artifacts": str(root)}, indent=2))


if __name__ == "__main__":
    main()
