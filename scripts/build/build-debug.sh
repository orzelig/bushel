#!/bin/sh

swift build --product lume
codesign --force --entitlement resources/lume.entitlements --sign - .build/debug/lume
