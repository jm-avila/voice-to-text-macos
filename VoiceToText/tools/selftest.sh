#!/bin/zsh
# Runs the in-app self-test against a fresh store in /tmp. Exit code 0 when every check passed.
# Fakes stand in for the mic and OpenAI: nothing is recorded, sent, or pasted.
set -u
rm -rf ~/Library/Saved\ Application\ State/com.jmavila.voicetotext.savedState
store=/tmp/VoiceToText-self.store
rm -rf $store $store.sock
APP_STORE=$store ~/Applications/VoiceToText.app/Contents/MacOS/VoiceToText --selftest
