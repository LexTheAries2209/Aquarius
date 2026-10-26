#!/usr/bin/env python3
"""Exercise Aquarius's guarded update path with locally signed Sparkle fixtures."""

import argparse
import functools
import http.server
import json
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import threading
import time
import xml.etree.ElementTree as ET


def run(*args, timeout=90, **kwargs):
    return subprocess.run(args, check=True, text=True, timeout=timeout, **kwargs)


def stop_fixture(app_path):
    executable = str(app_path / "Contents/MacOS/AquariusUpdateFixture")
    processes = run("ps", "-axo", "pid=,command=", capture_output=True).stdout
    for line in processes.splitlines():
        pid, _, command = line.strip().partition(" ")
        if command.strip() == executable:
            run("kill", "-TERM", pid)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sparkle-root", required=True, type=pathlib.Path,
                        help="Sparkle artifact root containing bin/ and Sparkle.xcframework/.")
    parser.add_argument("--scenario", choices=[
        "update", "cancel-install", "quit-before-ready", "download-conflict",
        "ready-conflict", "feed-signature", "archive-signature", "missing-feed"
    ], default="update")
    args = parser.parse_args()

    repo = pathlib.Path(__file__).resolve().parents[1]
    sparkle_root = args.sparkle_root.resolve()
    framework = sparkle_root / "Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
    if not framework.is_dir() and (sparkle_root / "Sparkle.framework").is_dir():
        framework = sparkle_root / "Sparkle.framework"
    framework_search_path = framework.parent
    tools = sparkle_root / "bin"
    if not framework.is_dir() or not (tools / "generate_appcast").is_file():
        parser.error("--sparkle-root does not contain the pinned Sparkle framework and tools.")

    cache = pathlib.Path.home() / "Library/Caches/AquariusUpdateFixtures"
    cache.mkdir(parents=True, exist_ok=True)
    root = pathlib.Path(tempfile.mkdtemp(prefix=f"sparkle-{args.scenario}-", dir=cache))
    key_path = root / "fixture-ed25519-key"
    public_key = run(
        "xcrun", "swift", str(repo / "script/fixtures/GenerateTestUpdateKey.swift"), str(key_path),
        capture_output=True
    ).stdout.strip()

    executable = root / "AquariusUpdateFixture"
    run(
        "xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor",
        "-target", "arm64-apple-macos14.0",
        "-F", str(framework_search_path), "-framework", "Sparkle",
        "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
        str(repo / "script/fixtures/SparkleUpdateFixture.swift"),
        str(repo / "Aquarius/AppUpdateConfiguration.swift"),
        str(repo / "Aquarius/AppUpdateSafety.swift"),
        str(repo / "Aquarius/AppUpdater.swift"),
        str(repo / "Aquarius/GuardedUpdateUserDriver.swift"),
        "-o", str(executable),
    )

    feed_root = root / "feed"
    feed_root.mkdir()
    requests = []

    class FeedHandler(http.server.SimpleHTTPRequestHandler):
        def do_GET(self):
            requests.append(self.path)
            super().do_GET()

        def log_message(self, format, *values):
            return

    handler = functools.partial(FeedHandler, directory=str(feed_root))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    base_url = f"http://127.0.0.1:{server.server_port}/"
    threading.Thread(target=server.serve_forever, daemon=True).start()

    def make_app(parent, build, version, scenario):
        app = parent / "Aquarius.app"
        contents = app / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        (contents / "Frameworks").mkdir()
        shutil.copy2(executable, contents / "MacOS/AquariusUpdateFixture")
        shutil.copytree(framework, contents / "Frameworks/Sparkle.framework", symlinks=True)
        output = root / "result.json"
        info = {
            "CFBundleIdentifier": f"lex.Aquarius.UpdateFixture.{root.name}",
            "CFBundleName": "Aquarius",
            "CFBundleDisplayName": "Aquarius",
            "CFBundleExecutable": "AquariusUpdateFixture",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": build,
            "CFBundleShortVersionString": version,
            "LSMinimumSystemVersion": "14.0",
            "CFBundleLocalizations": ["en", "zh-Hans"],
            "SUFeedURL": base_url + "appcast.xml",
            "SUPublicEDKey": public_key,
            "SUBundleName": "Aquarius",
            "SURequireSignedFeed": True,
            "SUVerifyUpdateBeforeExtraction": True,
            "SUSignedFeedFailureExpirationInterval": 0,
            "SUEnableAutomaticChecks": False,
            "SUAutomaticallyUpdate": False,
            "SUAllowsAutomaticUpdates": False,
            "SUEnableSystemProfiling": False,
            "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
            "AquariusFixtureRoot": str(root),
            "AquariusFixtureScenario": scenario,
            "AquariusProbeOutputPath": str(output),
        }
        with (contents / "Info.plist").open("wb") as stream:
            plistlib.dump(info, stream)
        run("codesign", "--force", "--sign", "-", str(app))
        run("codesign", "--verify", "--deep", "--strict", str(app))
        return app

    installed = make_app(root / "installed", "0006", "1.3.0", args.scenario)
    update = make_app(root / "new", "0007", "1.3.1", args.scenario)
    archive = feed_root / "Aquarius-v1.3.1-macOS.zip"
    run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(update), str(archive), timeout=180)
    run(
        str(tools / "generate_appcast"), "--ed-key-file", str(key_path),
        "--maximum-deltas", "0", "--download-url-prefix", base_url, str(feed_root)
    )
    feed = feed_root / "appcast.xml"
    run(str(tools / "sign_update"), "--ed-key-file", str(key_path), "--verify", str(feed))
    feed_build = ET.parse(feed).findtext(
        "./channel/item/{http://www.andymatuschak.org/xml-namespaces/sparkle}version"
    )
    if feed_build != "0007":
        raise RuntimeError(f"Appcast lost the padded Sparkle build: {feed_build!r}")

    if args.scenario == "feed-signature":
        feed.write_bytes(feed.read_bytes().replace(b"<title>", b"<title>tampered ", 1))
    elif args.scenario == "archive-signature":
        with archive.open("r+b") as stream:
            stream.seek(128)
            value = stream.read(1)
            stream.seek(128)
            stream.write(bytes([value[0] ^ 1]))
    elif args.scenario == "missing-feed":
        shutil.move(feed, feed_root / "unpublished-appcast.xml")

    stdout = root / "stdout.log"
    stderr = root / "stderr.log"
    launch = ["open", "-n", "--stdout", str(stdout), "--stderr", str(stderr), str(installed)]
    try:
        run(*launch)
        result_path = root / "result.json"
        deadline = time.monotonic() + 75
        while time.monotonic() < deadline and not result_path.exists():
            time.sleep(0.2)
        if not result_path.exists():
            stop_fixture(installed)
            raise RuntimeError(f"Fixture timed out; logs and artifacts retained at {root}")

        result = json.loads(result_path.read_text())
        print(json.dumps({
            "scenario": args.scenario,
            "artifacts": str(root),
            "feedRequests": requests,
            **result,
        }, indent=2))

        installed_info_path = installed / "Contents/Info.plist"
        with installed_info_path.open("rb") as stream:
            installed_build = plistlib.load(stream)["CFBundleVersion"]
        if args.scenario == "update":
            if result.get("result") != "updated" or installed_build != "0007":
                raise AssertionError(f"Signed update did not install: {result}, build={installed_build}")
            if not result.get("preferencesRetained") or not result.get("historyRetained"):
                raise AssertionError(f"Fixture state did not survive replacement: {result}")
            if not any(path.endswith(".zip") for path in requests):
                raise AssertionError(f"The update archive was not requested: {requests}")
        elif args.scenario in ("cancel-install", "quit-before-ready"):
            if result.get("result") != "cancelled" or installed_build != "0006":
                raise AssertionError(f"Cancelled/quit update replaced the old app: {result}, build={installed_build}")
            if result.get("preparedInstallation") or result.get("installationReserved"):
                raise AssertionError(f"Cancelled update remained armed: {result}")
        elif args.scenario in ("download-conflict", "ready-conflict"):
            if result.get("result") != "blocked" or installed_build != "0006":
                raise AssertionError(f"Media-work conflict did not block the update: {result}, build={installed_build}")
            if result.get("preparedInstallation") or result.get("installationReserved"):
                raise AssertionError(f"Conflicting update remained armed: {result}")
        else:
            if result.get("result") not in ("failed", "error") or installed_build != "0006":
                raise AssertionError(f"Invalid or missing feed did not fail closed: {result}, build={installed_build}")
            if not any("appcast.xml" in path for path in requests):
                raise AssertionError(f"Fixture did not request the feed: {requests}")
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
