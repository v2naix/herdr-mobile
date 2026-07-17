#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PROJECT="$ROOT/ios/prototypes/TerminalReaderPrototype/TerminalReaderPrototype.xcodeproj"

if [ ! -d /Applications/Xcode.app ]; then
  echo 'Xcode.app is required in /Applications.' >&2
  exit 1
fi

open -a /Applications/Xcode.app "$PROJECT"
