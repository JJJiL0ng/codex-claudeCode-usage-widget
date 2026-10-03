#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h}
app_dir="$project_dir/dist/AI Agent Usage.app"
contents="$app_dir/Contents"

mkdir -p "$contents/MacOS" "$contents/Resources"
cp "$project_dir/Info.plist" "$contents/Info.plist"
cp "$project_dir"/Resources/*.png "$contents/Resources/"
swiftc \
  -Osize \
  -swift-version 5 \
  -target "$(uname -m)-apple-macosx13.0" \
  -framework AppKit \
  -framework ServiceManagement \
  -framework IOKit \
  "$project_dir/Sources/AIAgentUsage.swift" \
  -o "$contents/MacOS/AIAgentUsage"
strip -x "$contents/MacOS/AIAgentUsage"
codesign --force --sign - --timestamp=none "$app_dir"
"$contents/MacOS/AIAgentUsage" --self-test
echo "$app_dir"
