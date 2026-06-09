#!/bin/bash

# ============================================================
# Mac Browser Manager (compatible with macOS default bash 3.2)
# - Show current default browser
# - List all installed browsers
# - Set default browser by name
# ============================================================

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

KNOWN_BROWSERS=(
    "Safari"
    "Google Chrome"
    "Firefox"
    "Microsoft Edge"
    "Brave Browser"
    "Opera"
    "Vivaldi"
    "Arc"
    "Chromium"
    "DuckDuckGo"
    "Tor Browser"
    "Waterfox"
    "Orion"
)

# ── Get bundle ID for an app by reading its Info.plist ────────
get_bundle_id() {
    local app_name="$1"
    for dir in "/Applications" "$HOME/Applications"; do
        local plist="$dir/$app_name.app/Contents/Info.plist"
        if [ -f "$plist" ]; then
            /usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$plist" 2>/dev/null
            return
        fi
    done
}

# ── Find all installed browsers ───────────────────────────────
find_browsers() {
    for browser in "${KNOWN_BROWSERS[@]}"; do
        for dir in "/Applications" "$HOME/Applications"; do
            if [ -d "$dir/$browser.app" ]; then
                echo "$browser"
                break
            fi
        done
    done
}

# ── Get current default browser bundle ID ────────────────────
get_default_browser_bundle_id() {
    local plist="$HOME/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist"
    [ -f "$plist" ] || { echo "com.apple.Safari"; return; }

    python3 - "$plist" <<'EOF'
import plistlib, sys

with open(sys.argv[1], 'rb') as f:
    data = plistlib.load(f)

for h in data.get('LSHandlers', []):
    if h.get('LSHandlerURLScheme') in ('https', 'http'):
        bid = h.get('LSHandlerRoleAll', '')
        if bid:
            print(bid)
            sys.exit(0)

print('com.apple.Safari')
EOF
}

# ── Resolve bundle ID → friendly app name (case-insensitive) ──
bundle_id_to_friendly_name() {
    local target_bid
    target_bid=$(echo "$1" | tr '[:upper:]' '[:lower:]')

    for dir in "/Applications" "$HOME/Applications"; do
        for app in "$dir"/*.app; do
            [ -d "$app" ] || continue
            local plist="$app/Contents/Info.plist"
            local bid
            bid=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$plist" 2>/dev/null)
            local bid_lower
            bid_lower=$(echo "$bid" | tr '[:upper:]' '[:lower:]')
            if [ "$bid_lower" = "$target_bid" ]; then
                local name
                name=$(/usr/libexec/PlistBuddy -c "Print CFBundleDisplayName" "$plist" 2>/dev/null)
                [ -z "$name" ] && name=$(/usr/libexec/PlistBuddy -c "Print CFBundleName" "$plist" 2>/dev/null)
                [ -z "$name" ] && name=$(basename "$app" .app)
                echo "$name"
                return
            fi
        done
    done

    echo "$1"
}

# ── Set default browser via inline Swift ──────────────────────
set_default_browser() {
    local bundle_id="$1"

    if ! command -v swift &>/dev/null; then
        echo -e "${RED}Swift not found. Install Xcode Command Line Tools:${NC}"
        echo "  xcode-select --install"
        exit 1
    fi

    swift - "$bundle_id" <<'SWIFT'
import Foundation
import ApplicationServices

let bundleID = CommandLine.arguments[1] as CFString
LSSetDefaultHandlerForURLScheme("http" as CFString, bundleID)
LSSetDefaultHandlerForURLScheme("https" as CFString, bundleID)
LSSetDefaultHandlerForURLScheme("x-web-search" as CFString, bundleID)
print("Done")
SWIFT
}

# ════════════════════════════════════════════════════════════
# MAIN
# ════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}${BLUE}╔══════════════════════════════╗${NC}"
echo -e "${BOLD}${BLUE}║    🌐  Mac Browser Manager   ║${NC}"
echo -e "${BOLD}${BLUE}╚══════════════════════════════╝${NC}"
echo ""

# ── 1. Current default ────────────────────────────────────────
echo -e "${YELLOW}${BOLD}▸ Current Default Browser${NC}"
default_bid=$(get_default_browser_bundle_id)
default_name=$(bundle_id_to_friendly_name "$default_bid")
echo -e "  ${GREEN}${default_name}${NC}"
echo ""

# ── 2. Installed browsers ─────────────────────────────────────
echo -e "${YELLOW}${BOLD}▸ Installed Browsers${NC}"

browsers=()
while IFS= read -r line; do
    browsers+=("$line")
done < <(find_browsers)

if [ ${#browsers[@]} -eq 0 ]; then
    echo -e "  ${RED}No known browsers found in /Applications or ~/Applications.${NC}"
    exit 1
fi

bundle_ids=()
i=0
while [ $i -lt ${#browsers[@]} ]; do
    bid=$(get_bundle_id "${browsers[$i]}")
    bundle_ids[$i]="$bid"
    marker=""
    # Case-insensitive compare for current default marker
    bid_lower=$(echo "$bid" | tr '[:upper:]' '[:lower:]')
    default_bid_lower=$(echo "$default_bid" | tr '[:upper:]' '[:lower:]')
    [ "$bid_lower" = "$default_bid_lower" ] && marker=" ${GREEN}<-- current default${NC}"
    echo -e "  • ${BOLD}${browsers[$i]}${NC}${marker}"
    i=$((i+1))
done
echo ""

# ── 3. Set new default by name ────────────────────────────────
echo -e "${YELLOW}${BOLD}▸ Set Default Browser${NC}"
echo -n "  Type browser name (or 'q' to quit): "
read -r choice
echo ""

if [[ "$choice" == "q" || "$choice" == "Q" ]]; then
    echo -e "  ${BLUE}Exiting. No changes made.${NC}"
    exit 0
fi

# Fuzzy case-insensitive match against installed browser names
choice_lower=$(echo "$choice" | tr '[:upper:]' '[:lower:]')
matched_name=""
matched_bid=""
i=0
while [ $i -lt ${#browsers[@]} ]; do
    name_lower=$(echo "${browsers[$i]}" | tr '[:upper:]' '[:lower:]')
    if [[ "$name_lower" == *"$choice_lower"* ]]; then
        matched_name="${browsers[$i]}"
        matched_bid="${bundle_ids[$i]}"
        break
    fi
    i=$((i+1))
done

if [ -z "$matched_name" ]; then
    echo -e "  ${RED}No installed browser matched \"${choice}\". Please check the name and try again.${NC}"
    exit 1
fi

# Check if already default (case-insensitive)
matched_bid_lower=$(echo "$matched_bid" | tr '[:upper:]' '[:lower:]')
if [ "$matched_bid_lower" = "$default_bid_lower" ]; then
    echo -e "  ${GREEN}${matched_name}${NC} is already your default browser. Nothing to do."
    exit 0
fi

echo -e "  Setting ${GREEN}${BOLD}${matched_name}${NC} as default browser..."
set_default_browser "$matched_bid"
echo ""
echo -e "  ${GREEN}✔ Done!${NC} ${matched_name} is now your default browser."
echo -e "  ${BLUE}(A system dialog may appear — click 'Use ${matched_name}' to confirm)${NC}"
echo ""
