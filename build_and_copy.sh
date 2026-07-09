#!/bin/sh

rm -rf /Volumes/My\ Shared\ Files/LocalOnly/Bromure\ Agentic\ Coding.app || true
if [ "$1" == "cp" ];
then
 	cp -r ./.build/arm64-apple-macosx/release/Bromure\ Agentic\ Coding.app /Volumes/My\ Shared\ Files/LocalOnly/
	exit 0
fi
 ./build.sh bromure-ac &&
 	cp -r ./.build/arm64-apple-macosx/release/Bromure\ Agentic\ Coding.app /Volumes/My\ Shared\ Files/LocalOnly/
