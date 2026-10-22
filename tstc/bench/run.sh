#!/bin/sh
# node bench/run.mjs with the tools' PATH (see scripts/ci.sh)
export PATH="$HOME/.moon/bin:$HOME/go/bin:$PATH"
exec node bench/run.mjs --flag --llvm --flag ${LLVM_BIN:-/opt/homebrew/opt/llvm@22/bin} --flag -j --flag 3 "$@"
