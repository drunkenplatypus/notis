#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME=$(basename "$0")
PLIST_PATH="Info.plist"
MODE="patch"
DRY_RUN=0

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [patch|minor|major|build] [--plist PATH] [--dry-run]

Modes:
  patch   Increment patch version (x.y.z -> x.y.(z+1)) and reset build to 1 (default)
  minor   Increment minor version (x.y.z -> x.(y+1).0) and reset build to 1
  major   Increment major version (x.y.z -> (x+1).0.0) and reset build to 1
  build   Increment build number only

Examples:
  ./$SCRIPT_NAME
  ./$SCRIPT_NAME minor
  ./$SCRIPT_NAME build --dry-run
  ./$SCRIPT_NAME patch --plist Info.plist
EOF
}

if [[ $# -gt 0 ]]; then
    case "$1" in
        patch|minor|major|build)
            MODE="$1"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
    esac
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --plist)
            if [[ $# -lt 2 ]]; then
                echo "Missing value for --plist" >&2
                usage
                exit 1
            fi
            PLIST_PATH="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ ! -f "$PLIST_PATH" ]]; then
    echo "Plist not found: $PLIST_PATH" >&2
    exit 1
fi

plist_get() {
    local key="$1"
    /usr/libexec/PlistBuddy -c "Print :$key" "$PLIST_PATH" 2>/dev/null || true
}

plist_set() {
    local key="$1"
    local value="$2"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        return
    fi

    if /usr/libexec/PlistBuddy -c "Print :$key" "$PLIST_PATH" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Set :$key $value" "$PLIST_PATH"
    else
        /usr/libexec/PlistBuddy -c "Add :$key string $value" "$PLIST_PATH"
    fi
}

short_version=$(plist_get "CFBundleShortVersionString")
build_version=$(plist_get "CFBundleVersion")

if [[ -z "$short_version" ]]; then
    short_version="1.0.0"
fi

if [[ -z "$build_version" ]]; then
    build_version="1"
fi

if ! [[ "$build_version" =~ ^[0-9]+$ ]]; then
    echo "CFBundleVersion must be numeric. Found: $build_version" >&2
    exit 1
fi

IFS='.' read -r -a parts <<< "$short_version"
major="${parts[0]:-1}"
minor="${parts[1]:-0}"
patch="${parts[2]:-0}"

for part in "$major" "$minor" "$patch"; do
    if ! [[ "$part" =~ ^[0-9]+$ ]]; then
        echo "CFBundleShortVersionString must be numeric (e.g. 1.2.3). Found: $short_version" >&2
        exit 1
    fi
done

new_major="$major"
new_minor="$minor"
new_patch="$patch"
new_build="$build_version"
new_short_version="$short_version"

case "$MODE" in
    patch)
        new_patch=$((patch + 1))
        new_build=1
        new_short_version="$new_major.$new_minor.$new_patch"
        ;;
    minor)
        new_minor=$((minor + 1))
        new_patch=0
        new_build=1
        new_short_version="$new_major.$new_minor.$new_patch"
        ;;
    major)
        new_major=$((major + 1))
        new_minor=0
        new_patch=0
        new_build=1
        new_short_version="$new_major.$new_minor.$new_patch"
        ;;
    build)
        new_build=$((build_version + 1))
        ;;
esac

plist_set "CFBundleShortVersionString" "$new_short_version"
plist_set "CFBundleVersion" "$new_build"

echo "Updated $PLIST_PATH"
echo "  CFBundleShortVersionString: $short_version -> $new_short_version"
echo "  CFBundleVersion: $build_version -> $new_build"

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "(dry-run: no file changes were written)"
fi
