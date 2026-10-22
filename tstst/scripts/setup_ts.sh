#!/bin/sh
# Fetches microsoft/TypeScript (tsc/ = tsgo sources and baselines) at the pinned
# commit next to this checkout: ../TypeScript
set -e
PIN=fed0bf24149fb1ed36039212648bafdafc1ea10e
cd "$(dirname "$0")/../.."
if [ ! -d TypeScript/.git ]; then
  git clone -q --filter=blob:none --no-checkout https://github.com/microsoft/TypeScript.git TypeScript
fi
cd TypeScript
if [ "$(git rev-parse HEAD 2>/dev/null)" != "$PIN" ]; then
  git sparse-checkout set tsc
  git fetch -q --depth 1 origin $PIN
  git checkout -q $PIN
fi
git rev-parse --short HEAD
