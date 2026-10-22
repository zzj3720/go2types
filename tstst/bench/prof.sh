#!/bin/sh
# Where a real checker spends its time on a go2types example: the type aliases
# (self and inclusive, sampled every ms) and a CPU profile of the first SECS
# seconds, from the instrumented tsgo (TSTST_INSTR=1 sh scripts/tsgo_build.sh out/tsgo-instr).
# usage: [SECS=n] [TOP=n] [LIBDIR=..] sh bench/prof.sh prog   (SECS below the run's length)
cd "$(dirname "$0")/.."
p=$1; d=go2types/testdata/$p; [ -d $d ] || d=go2types/tscdata/$p
mkdir -p out/ex
(cd go2types && go run . ${G2T_FLAGS:--split 8} -o ../out/ex/$p.ts -lib ${LIBDIR:-../../lib/pure} ./${d#go2types/} 2>/dev/null)
rm -rf out/ex/st && mkdir -p out/ex/st
node -e '
const fs=require("fs"),path=require("path");const root=process.cwd();const p=process.argv[1];const todo=[path.resolve("out/ex/"+p+".ts")],seen=new Set();
while(todo.length){const f=todo.pop();if(seen.has(f))continue;seen.add(f);const src=fs.readFileSync(f,"utf8");const dst=path.join("out/ex/st",path.relative(root,f).replace(/\.ts$/,".d.ts"));fs.mkdirSync(path.dirname(dst),{recursive:true});fs.writeFileSync(dst,src);for(const m of src.matchAll(/\bfrom\s+"(\.[^"]*)"/g)){const q=path.resolve(path.dirname(f),m[1]);todo.push(fs.existsSync(q+".ts")?q+".ts":q);}}
fs.writeFileSync("out/ex/st/entry.ts","import type { Main } from \"./out/ex/"+p+"\";\nexport const r: 0 = null as unknown as Main;\n");' $p
cd out/ex/st
S=${SECS:-30}
/usr/bin/time -l perl -e '$t = shift; $p = fork; exec @ARGV if !$p; $SIG{ALRM} = sub { kill 9, $p }; alarm $t; waitpid $p, 0; exit($? & 127 ? 128 + ($? & 127) : $? >> 8)' $((S + 5)) env TSTST_ALIASPROF=$PWD/../ap_$p.txt TSTST_CPUPROFILE=$PWD/../cpu_$p.pprof TSTST_PROFSECS=$S ../../tsgo-instr/tsgo --singleThreaded --noEmit --strict --noErrorTruncation --pretty false --target esnext --module esnext --moduleResolution bundler --skipLibCheck --types "" --diagnostics entry.ts > ../run_$p.txt 2>&1
grep -E 'error TS|^(Instantiation|Types|Check time|Memory)|real|maximum resident' ../run_$p.txt | cut -c1-200 | head -12
head -${TOP:-40} ../ap_$p.txt; grep -A${TOP:-40} '== inclusive' ../ap_$p.txt
cd ../..; go tool pprof -top -nodecount=25 tsgo-instr/tsgo ex/cpu_$p.pprof 2>/dev/null | tail -26
