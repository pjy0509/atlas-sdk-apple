#!/bin/sh
# Cuts a release on a Mac with Xcode and CocoaPods:
#
#   sh tools/release.sh            # version from the podspec
#
# Needs a CocoaPods trunk session (pod trunk register, once per machine) and
# push rights on the remote.
#
# Order differs from the other SDKs on purpose. Swift Package Manager resolves
# by git tag and CocoaPods lints the podspec against that same tag, so the tag
# has to exist on the remote before trunk will take the pod. The gate runs
# first all the same, and nothing is tagged until it passes.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

VERSION="$(sed -n "s/.*s\.version *= *'\([^']*\)'.*/\1/p" AppAtlasSDK.podspec | head -n1)"
[ -n "$VERSION" ] || { echo "no version in AppAtlasSDK.podspec" >&2; exit 1; }

# Everything that would go into the release must already be committed: the
# tag names the commit, and trunk builds the pod from it.
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "working tree is dirty; commit first" >&2; exit 1; }
[ -z "$(git log --oneline "@{upstream}..HEAD" 2>/dev/null)" ] || { echo "push main first; the tag must name a commit the remote has" >&2; exit 1; }

# The guide's install lines name a version. A release that does not match them
# ships instructions nobody can follow, which is how 0.1.0 stayed the only tag
# while the guide asked for 0.3.0.
for FILE in README.md README.ko.md README.zh.md; do
    OTHERS="$(awk '/^## (Install|설치|安装)/{on=1;next} /^## /{on=0} on' "$FILE" \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -u | grep -vx "$VERSION" || true)"
    [ -z "$OTHERS" ] || { echo "$FILE installs $(echo "$OTHERS" | tr '\n' ' '), not $VERSION" >&2; exit 1; }
done
echo "== the guide installs $VERSION"

echo "== gate"
sh check-core.sh

echo "== tag"
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
    echo "v$VERSION is already tagged locally"
else
    git tag -a "v$VERSION" -m "v$VERSION"
fi

git push origin "v$VERSION"
echo "== SPM can resolve $VERSION now"

echo "== trunk"
pod trunk push AppAtlasSDK.podspec --allow-warnings

echo "== $VERSION is out: git tag v$VERSION and pod AppAtlasSDK $VERSION"
