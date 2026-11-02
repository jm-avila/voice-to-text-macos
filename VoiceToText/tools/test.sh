#!/bin/zsh
# Runs `swift test` for a package with only the Command Line Tools installed.
# The default build system (swiftbuild) loads the Swift Testing macro plugin only
# some of the time ("plugin for module 'TestingMacros' not found"). Passing its
# folder makes every run load it. With Xcode, plain `swift test` works too.
# Usage: swift-test.sh <package-dir> [swift test options, like --filter Search]
#        swift-test.sh --help
set -euo pipefail
if [[ $# -lt 1 || $1 == -h || $1 == --help ]]; then
  sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
  exit $(( $# < 1 ))
fi
package=${1:A}; shift
plugins=$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins/testing
args=()
[[ -d "$plugins" ]] && args=(-Xswiftc -plugin-path -Xswiftc "${plugins:A}")
swift test --package-path "$package" --scratch-path ~/Library/Developer/${package:t}/test-build "${args[@]}" "$@" 2>&1 \
  | grep -v "ld: warning: search path"
