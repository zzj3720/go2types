// Evaluates the Main type of a program compiled by go2types with a type
// checker's command line (tsgo, tsrs: no API to ask for a type): the entry
// assigns Main to a variable of type 0, and the error message names the type,
// a string literal (written in full: --noErrorTruncation). Writes the output
// (one byte per character) to stdout.
//
// The command line checks every file of the program, and checking the
// declarations of go2types code and lib/pure (softfloat.ts alone is 6 MB of
// generic aliases) costs far more than evaluating Main; so the program and the
// files it imports are copied as .d.ts files (--skipLibCheck skips them) into
// a staging directory, and only the entry is checked.
//
// usage: node scripts/cli_eval.mjs --checker path [--entry Main] [--input text | --input-file f] [--timeout s] [-- extra flags] prog.ts
// (--input-file: the file's bytes, as the program's input string of chars 0-255)
import { spawnSync } from "node:child_process";
import { writeFileSync, readFileSync, mkdirSync, rmSync, existsSync } from "node:fs";
import path from "node:path";

const o = { checker: null, entry: "Main", input: null, file: null, timeout: 3600, extra: [] };
const a = process.argv.slice(2);
for (let i = 0; i < a.length; i++) {
  if (a[i] === "--checker") o.checker = path.resolve(a[++i]);
  else if (a[i] === "--entry") o.entry = a[++i];
  else if (a[i] === "--input") o.input = a[++i];
  else if (a[i] === "--input-file") o.input = readFileSync(a[++i], "latin1");
  else if (a[i] === "--timeout") o.timeout = +a[++i];
  else if (a[i] === "--") { o.extra = a.slice(i + 1, -1); o.file = path.resolve(a[a.length - 1]); break; }
  else o.file = path.resolve(a[i]);
}
if (!o.checker || !o.file) {
  console.error("usage: node scripts/cli_eval.mjs --checker path [--entry Main] [--input text | --input-file f] [--timeout s] [-- extra flags] prog.ts");
  process.exit(2);
}
const root = process.cwd();
const stage = path.join(path.dirname(o.file), path.basename(o.file, ".ts") + ".stage");
rmSync(stage, { recursive: true, force: true });
// copy the program and what it imports (transitively) as declaration files
const todo = [o.file], seen = new Set();
while (todo.length) {
  const f = todo.pop();
  if (seen.has(f)) continue;
  seen.add(f);
  const rel = path.relative(root, f);
  if (rel.startsWith("..")) throw new Error(`cli_eval: ${f} is outside ${root}`);
  const src = readFileSync(f, "utf8");
  const dst = path.join(stage, rel.replace(/\.ts$/, ".d.ts"));
  mkdirSync(path.dirname(dst), { recursive: true });
  writeFileSync(dst, src);
  for (const m of src.matchAll(/\bfrom\s+"(\.[^"]*)"/g)) {
    const p = path.resolve(path.dirname(f), m[1]);
    todo.push(existsSync(p + ".ts") ? p + ".ts" : p);
  }
}
const entryFile = path.join(stage, "entry.ts");
let mod = "./" + path.relative(root, o.file).replace(/\.ts$/, "");
const arg = o.input === null ? "" : `<${JSON.stringify(o.input)}>`;
writeFileSync(entryFile, `import type { ${o.entry} } from ${JSON.stringify(mod)};\n` +
  `export const tststResult: 0 = null as unknown as ${o.entry}${arg};\n`);
const t0 = Date.now();
const r = spawnSync(o.checker, ["--noEmit", "--strict", "--noErrorTruncation", "--pretty", "false", "--target", "esnext",
  "--module", "esnext", "--moduleResolution", "bundler", "--skipLibCheck", "--types", "", "--diagnostics", ...o.extra, entryFile],
  { maxBuffer: 1 << 30, encoding: "utf8", timeout: o.timeout * 1000, killSignal: "SIGKILL", cwd: stage });
const t = Date.now() - t0;
const out = (r.stdout || "") + (r.stderr || "");
const m = /error TS2322: Type '("(?:[^"\\]|\\.)*")' is not assignable to type '0'\./.exec(out);
const errs = out.split("\n").filter(l => /error TS\d+/.test(l));
const stats = out.split("\n").filter(l => /^(Instantiation count|Types|Check time|Total time|Memory used):/.test(l))
  .map(l => l.replace(/\s+/g, " ").trim()).join(", ");
const name = path.basename(o.checker);
if (!m || errs.length !== 1) {
  console.error(`cli_eval: ${name}: no single string literal result (exit ${r.status}${r.signal ? ", " + r.signal : ""}, ${t} ms)`);
  console.error(out.slice(0, 3000));
  process.exit(1);
}
rmSync(stage, { recursive: true, force: true });
const s = new Function(`return ${m[1]};`)();
console.error(`cli_eval: ${name}: check ${t} ms; ${stats}`);
process.stdout.write(Buffer.from(s, "latin1"));
