#!/bin/zsh
# Snapshots of every HUD state and of Settings, in light and dark, with seed data, on a fresh test store.
# Usage: tools/snap.sh                     all
#        APP_SNAPSHOT_PAGES=settings tools/snap.sh
set -u
app=~/Applications/VoiceToText.app/Contents/MacOS/VoiceToText
store=/tmp/VoiceToText-test.store
shots=/tmp/VoiceToText-shots
# A crashed run leaves saved window state, and the next launch would wait on a "reopen windows?" alert.
rm -rf ~/Library/Saved\ Application\ State/com.jmavila.voicetotext.savedState
# Seed data only fills an empty store, so start from nothing.
rm -rf $store $store.sock
rm -rf $shots
APP_STORE=$store APP_SEED=1 APP_SNAPSHOT=$shots $app
