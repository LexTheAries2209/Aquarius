#!/usr/bin/env python3
"""Create and verify an Aquarius Sparkle update ZIP and signed appcast."""

import argparse
import pathlib
import plistlib
import re
import subprocess
import urllib.parse
import xml.etree.ElementTree as ET


def run(*args):
    return subprocess.run(args, check=True, text=True, capture_output=True, timeout=90)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, type=pathlib.Path)
    parser.add_argument("--sparkle-bin", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--download-url-prefix", required=True)
    parser.add_argument("--release-notes", required=True, type=pathlib.Path)
    parser.add_argument("--previous-build", default="0005")
    parser.add_argument("--key-account", default="lex.Aquarius")
    args = parser.parse_args()

    app = args.app.resolve()
    tools = args.sparkle_bin.resolve()
    output = args.output.resolve()
    notes = args.release_notes.resolve()
    prefix = urllib.parse.urlparse(args.download_url_prefix)
    if prefix.scheme != "https" or not prefix.netloc or prefix.username or prefix.password \
            or prefix.query or prefix.fragment or not args.download_url_prefix.endswith("/"):
        parser.error("--download-url-prefix must be a clean HTTPS URL ending in '/'.")
    if app.name != "Aquarius.app":
        parser.error("The update bundle must retain the stable name Aquarius.app.")
    if not notes.is_file():
        parser.error("The bilingual release notes file does not exist.")
    if not (tools / "generate_keys").is_file() or not (tools / "generate_appcast").is_file() \
            or not (tools / "sign_update").is_file():
        parser.error("--sparkle-bin must point to Sparkle's bin directory.")
    if not re.fullmatch(r"[0-9]{4}", args.previous_build):
        parser.error("--previous-build must be a four-digit global release build.")
    if output.exists():
        parser.error("The output directory already exists; refusing to overwrite signed release artifacts.")

    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    version = info.get("CFBundleShortVersionString", "")
    build = info.get("CFBundleVersion", "")
    if info.get("CFBundleIdentifier") != "lex.Aquarius":
        parser.error("Unexpected app bundle identifier.")
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        parser.error("A complete semantic marketing version is required.")
    if not re.fullmatch(r"[0-9]{4}", build) or int(build) == 0:
        parser.error("CFBundleVersion must be a nonzero four-digit global release build.")
    if int(build) <= int(args.previous_build):
        parser.error("The new build must be greater than the actual previous published build.")
    if not info.get("SURequireSignedFeed") or not info.get("SUVerifyUpdateBeforeExtraction"):
        parser.error("Signed feeds and verification before extraction must both be enabled.")
    if not (app / "Contents/Frameworks/Sparkle.framework").exists():
        parser.error("The archived App does not embed Sparkle.framework.")

    run("codesign", "--verify", "--deep", "--strict", str(app))
    expected_key = run(
        str(tools / "generate_keys"), "--account", args.key_account, "-p"
    ).stdout.strip()
    if info.get("SUPublicEDKey") != expected_key:
        parser.error("The existing keychain account's public key does not match the App. No key was changed.")

    output.mkdir(parents=True, exist_ok=False)
    archive = output / f"Aquarius-v{version}-macOS.zip"
    subprocess.run(
        ["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive)],
        check=True, timeout=180
    )
    archive.with_suffix(".md").write_bytes(notes.read_bytes())

    run(
        str(tools / "generate_appcast"),
        "--account", args.key_account,
        "--maximum-deltas", "0",
        "--embed-release-notes",
        "--download-url-prefix", args.download_url_prefix,
        "--link", "https://github.com/LexTheAries2209/Aquarius/releases",
        str(output),
    )

    feed = output / "appcast.xml"
    run(str(tools / "sign_update"), "--account", args.key_account, "--verify", str(feed))
    namespace = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
    item = ET.parse(feed).find("./channel/item")
    if item is None or item.findtext("sparkle:version", namespaces=namespace) != build:
        raise ValueError("The signed feed's sparkle:version does not match CFBundleVersion.")
    enclosure = item.find("enclosure")
    if enclosure is None or int(enclosure.attrib["length"]) != archive.stat().st_size:
        raise ValueError("The appcast archive length does not match the immutable ZIP.")
    signature = enclosure.attrib["{" + namespace["sparkle"] + "}edSignature"]
    run(str(tools / "sign_update"), "--account", args.key_account, "--verify", str(archive), signature)
    print(f"Verified signed Aquarius build {build} ({version}) in {output}")
    print("Upload the immutable ZIP first and appcast.xml last. No publication was performed.")


if __name__ == "__main__":
    main()
