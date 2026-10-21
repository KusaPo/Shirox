#!/bin/bash
set -euo pipefail
preview_device=$1
preview_derived=$2
preview_output=$3
# Reuse the simulator xcodebuild already booted rather than starting a second iOS VM.
preview_booted=$(xcrun simctl list devices booted -j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next((x["udid"] for items in d["devices"].values() for x in items if "iPhone" in x["name"]), ""))')
if [ -n "$preview_booted" ]; then preview_device=$preview_booted; fi
mkdir -p "$preview_output"
xcrun simctl boot "$preview_device" 2>/dev/null || true
xcrun simctl bootstatus "$preview_device" -b
xcrun simctl status_bar "$preview_device" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
xcrun simctl install "$preview_device" "$preview_derived/Build/Products/Debug-iphonesimulator/Kairo.app"
for preview_style in A B C; do
  xcrun simctl terminate "$preview_device" net.kusapo.kairo 2>/dev/null || true
  xcrun simctl launch "$preview_device" net.kusapo.kairo --design-preview --glass-style "$preview_style" --capture
  sleep 2
  xcrun simctl io "$preview_device" screenshot "$preview_output/$preview_style-home.png"
done
for preview_page in discover downloads; do
  xcrun simctl terminate "$preview_device" net.kusapo.kairo 2>/dev/null || true
  xcrun simctl launch "$preview_device" net.kusapo.kairo --design-preview --glass-style B --glass-page "$preview_page" --capture
  sleep 2
  xcrun simctl io "$preview_device" screenshot "$preview_output/B-$preview_page.png"
done
xcrun simctl terminate "$preview_device" net.kusapo.kairo 2>/dev/null || true
xcrun simctl launch "$preview_device" net.kusapo.kairo --design-preview --glass-style B --light --capture
sleep 2
xcrun simctl io "$preview_device" screenshot "$preview_output/B-light.png"
