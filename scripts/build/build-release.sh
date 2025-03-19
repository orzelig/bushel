#!/bin/sh

pushd ../../

swift build -c release --product lume
codesign --force --entitlement ./resources/lume.entitlements --sign - .build/release/lume

mkdir -p ./.release
cp -f .build/release/lume ./.release/lume

# Create symbolic link in /usr/local/bin
sudo mkdir -p /usr/local/bin
sudo ln -sf "$(pwd)/.release/lume" /usr/local/bin/lume

popd