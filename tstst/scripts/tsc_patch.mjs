// Writes a copy of tsc (node_modules/typescript/lib) without the checker's
// artificial limits, for running go2types programs (scripts/tsc_run.sh).
// The semantics of every type operation are unchanged; only the guards that
// give up on large computations are removed:
//
//   1. getConditionalType: `tailCount === 1000` (tail-recursive conditional
//      types evaluated in a loop give up after 1000 rounds: TS2589)
//   2. instantiateTypeWithAlias: `instantiationDepth === 100 ||
//      instantiationCount >= 5e6` (nested instantiations deeper than 100, or
//      more than 5 million per checked node: TS2589)
//   3. recursiveTypeRelatedTo: `sourceDepth === 100 || targetDepth === 100`
//      (relating values nested more than 100 deep counts as unrelated)
//   4. relationCount (16 million relations per check, then "excessive
//      complexity", counted as unrelated)
//   5. isDeeplyNestedType: maxDepth 3 (relating types with the same recursion
//      identity nested 3 deep answers "maybe", i.e. related, without looking);
//      go2types values are finite literal types, so the cutoff is unneeded
//      and could make different deep tuples compare as related; only with
//      --no-nesting-cutoff (lib.d.ts's recursive types rely on it elsewhere)
//
// usage: node scripts/tsc_patch.mjs <out dir> [--no-nesting-cutoff]   (writes <out dir>/lib/typescript.js)
import { readFileSync, writeFileSync, cpSync, mkdirSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";

const out = path.resolve(process.argv[2] || "out/tsc-patched");
const noCutoff = process.argv.includes("--no-nesting-cutoff");
const require = createRequire(import.meta.url);
const src = path.dirname(require.resolve("typescript/lib/typescript.js"));
mkdirSync(out, { recursive: true });
cpSync(src, path.join(out, "lib"), { recursive: true });
// tsc's lib is CommonJS (this repository's package.json says "module")
writeFileSync(path.join(out, "package.json"), '{ "type": "commonjs" }\n');
const file = path.join(out, "lib", "typescript.js");
let js = readFileSync(file, "utf8");
const patches = [
  ["tailCount === 1e3", "false /* tstst: no tail recursion limit */"],
  ["instantiationDepth === 100 || instantiationCount >= 5e6", "false /* tstst: no instantiation limit */"],
  ["sourceDepth === 100 || targetDepth === 100", "false /* tstst: no relation depth limit */"],
  ["let relationCount = 16e6 - relation.size >> 3;", "let relationCount = Infinity; /* tstst: no relation complexity limit */"],
];
if (noCutoff) patches.push(
  ["function isDeeplyNestedType(type, stack, depth, maxDepth = 3) {", "function isDeeplyNestedType(type, stack, depth, maxDepth = 3) { return false; /* tstst: no nesting cutoff */"]);
for (const [from, to] of patches) {
  const n = js.split(from).length - 1;
  if (n !== 1) {
    console.error(`tsc_patch: expected one occurrence of ${JSON.stringify(from)}, found ${n}`);
    process.exit(1);
  }
  js = js.replace(from, to);
}
writeFileSync(file, js);
console.error(`tsc_patch: ${patches.length} patches -> ${file}`);
