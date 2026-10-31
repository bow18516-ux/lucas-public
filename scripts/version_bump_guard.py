#!/usr/bin/env python3
"""Publish gate: marketing must not go backwards; build must strictly increase.

Compares a proposed (marketing, build) against the newest item in a Sparkle
appcast (by sparkle:version). Used by scripts/release.sh so nobody has to
eyeball the feed before every ship.

Usage:
  version_bump_guard.py --marketing 0.5.6 --build 202610311200 \\
      [--feed URL | --xml-file PATH | --xml-stdin]

  version_bump_guard.py --self-test

Exit 0 on pass, 1 on fail / usage error. Offline fixtures via --xml-file.
"""
from __future__ import annotations

import argparse
import re
import sys
import urllib.error
import urllib.request
from typing import Optional, Tuple


ITEM_RE = re.compile(r"<item>(.*?)</item>", re.S)
BUILD_RE = re.compile(r"<sparkle:version>(\d+)</sparkle:version>")
SHORT_RE = re.compile(r"<sparkle:shortVersionString>([^<]+)</sparkle:shortVersionString>")


def parse_semver(text: str) -> Tuple[int, ...]:
    parts = []
    for chunk in text.strip().split("."):
        if not chunk:
            parts.append(0)
            continue
        # Allow accidental "0.5.5-hotfix" → treat numeric prefix only.
        m = re.match(r"(\d+)", chunk)
        if not m:
            raise ValueError(f"invalid version segment in {text!r}")
        parts.append(int(m.group(1)))
    if not parts:
        raise ValueError(f"empty version {text!r}")
    return tuple(parts)


def cmp_semver(a: str, b: str) -> int:
    aa, bb = list(parse_semver(a)), list(parse_semver(b))
    n = max(len(aa), len(bb))
    aa.extend([0] * (n - len(aa)))
    bb.extend([0] * (n - len(bb)))
    if aa < bb:
        return -1
    if aa > bb:
        return 1
    return 0


def newest_from_appcast(xml: str) -> Optional[Tuple[str, int]]:
    best: Optional[Tuple[str, int]] = None
    for body in ITEM_RE.findall(xml):
        bm = BUILD_RE.search(body)
        if not bm:
            continue
        build = int(bm.group(1))
        sm = SHORT_RE.search(body)
        short = sm.group(1).strip() if sm else str(build)
        if best is None or build > best[1]:
            best = (short, build)
    return best


def evaluate(proposed_marketing: str, proposed_build: int, live_marketing: str, live_build: int) -> Tuple[bool, str]:
    reasons = []
    if cmp_semver(proposed_marketing, live_marketing) < 0:
        reasons.append(
            f"marketing {proposed_marketing} < live {live_marketing} "
            f"(must not go backwards)"
        )
    if proposed_build <= live_build:
        reasons.append(
            f"build {proposed_build} <= live {live_build} "
            f"(must strictly increase)"
        )
    if reasons:
        return False, "; ".join(reasons)
    note = ""
    if cmp_semver(proposed_marketing, live_marketing) == 0:
        note = f" (same marketing {proposed_marketing}; hotfix/build-only bump OK)"
    return True, (
        f"OK: {proposed_marketing} ({proposed_build}) > live "
        f"{live_marketing} ({live_build}){note}"
    )


def load_xml(feed: Optional[str], xml_file: Optional[str], xml_stdin: bool) -> str:
    if xml_stdin:
        return sys.stdin.read()
    if xml_file:
        with open(xml_file, "r", encoding="utf-8") as fh:
            return fh.read()
    if not feed:
        raise SystemExit("need --feed, --xml-file, or --xml-stdin")
    req = urllib.request.Request(
        feed,
        headers={"User-Agent": "Lucas-version-bump-guard/1.0", "Cache-Control": "no-cache"},
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        return resp.read().decode("utf-8", errors="replace")


def self_test() -> int:
    fixtures = [
        # (marketing, build, live_m, live_b, expect_ok)
        ("0.5.6", 202610311200, "0.5.5", 202610310945, True),
        ("0.5.5", 202610311200, "0.5.5", 202610310945, True),  # hotfix
        ("0.5.5", 202610310945, "0.5.5", 202610310945, False),  # same build
        ("0.5.5", 202610310400, "0.5.5", 202610310945, False),  # build regress
        ("0.5.3", 202610311200, "0.5.5", 202610310945, False),  # marketing regress
        ("0.5.10", 1, "0.5.9", 0, True),  # numeric, not lexicographic
        ("0.5.9", 1, "0.5.10", 0, False),
    ]
    failed = 0
    for m, b, lm, lb, expect in fixtures:
        ok, msg = evaluate(m, b, lm, lb)
        if ok != expect:
            print(f"FAIL case {m}/{b} vs {lm}/{lb}: expected {expect}, got {ok}: {msg}")
            failed += 1
        else:
            print(f"PASS {m}/{b} vs {lm}/{lb}: {msg}")

    sample = """
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel>
        <item>
          <sparkle:version>202610310945</sparkle:version>
          <sparkle:shortVersionString>0.5.5</sparkle:shortVersionString>
        </item>
        <item>
          <sparkle:version>202610301010</sparkle:version>
          <sparkle:shortVersionString>0.5.3</sparkle:shortVersionString>
        </item>
      </channel>
    </rss>
    """
    newest = newest_from_appcast(sample)
    if newest != ("0.5.5", 202610310945):
        print(f"FAIL newest_from_appcast: {newest}")
        failed += 1
    else:
        print(f"PASS newest_from_appcast: {newest}")

    # shorts.last trap: oldest marketing must NOT win
    if newest and newest[0] == "0.5.3":
        print("FAIL would have picked shorts.last 0.5.3")
        failed += 1

    if failed:
        print(f"self-test: {failed} failed")
        return 1
    print("self-test: OK")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--marketing", help="proposed CFBundleShortVersionString")
    parser.add_argument("--build", type=int, help="proposed CFBundleVersion")
    parser.add_argument("--feed", help="live appcast URL")
    parser.add_argument("--xml-file", help="offline appcast path")
    parser.add_argument("--xml-stdin", action="store_true", help="read appcast from stdin")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)

    if args.self_test:
        return self_test()

    if not args.marketing or args.build is None:
        parser.error("--marketing and --build are required (unless --self-test)")

    try:
        xml = load_xml(args.feed, args.xml_file, args.xml_stdin)
    except urllib.error.URLError as exc:
        print(f"FAIL: cannot fetch appcast: {exc}", file=sys.stderr)
        return 1
    except OSError as exc:
        print(f"FAIL: cannot read appcast: {exc}", file=sys.stderr)
        return 1

    newest = newest_from_appcast(xml)
    if newest is None:
        print("FAIL: appcast has no usable item", file=sys.stderr)
        return 1

    live_m, live_b = newest
    ok, msg = evaluate(args.marketing, args.build, live_m, live_b)
    print(msg)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
