#!/bin/sh

rm -rf /Volumes/My\ Shared\ Files/LocalOnly/Bromure\ Agentic\ Coding.app || true
./build.sh bromure-ac &&
 	cp -r ./.build/arm64-apple-macosx/release/Bromure\ Agentic\ Coding.app /Volumes/My\ Shared\ Files/LocalOnly/
