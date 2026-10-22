// Evaluates the Main type of a program compiled by go2types with the real
// TypeScript checker (tsc's JavaScript API) and writes the output (the string
// literal Main evaluates to, one byte per character) to stdout.
//
// usage: node scripts/tsc_eval.mjs [--ts typescript.js] [--stack MB] [--heap MB] [--entry Main] [--input text] [--show] prog.ts
//
// --show prints the entry type as tsc writes it (any type, not just string
// literals), one line per entry; --entry may be given several times.
//
// The checker runs in a worker thread whose stack is --stack MB (default
// 4000): parsing and instantiating deeply nested conditional types recurses
// once per nesting level. tsc's artificial limits (instantiation depth and
// count, conditional tail recursion count) are removed by scripts/tsc_patch.mjs,
// which writes the --ts file this script loads.
import { Worker, isMainThread, workerData, parentPort } from "node:worker_threads";
import { createRequire } from "node:module";
import { writeFileSync, rmSync } from "node:fs";
import path from "node:path";

if (isMainThread) {
  const o = { ts: "typescript", stack: 4000, heap: 16000, entries: [], input: null, file: null, show: false };
  const a = process.argv.slice(2);
  for (let i = 0; i < a.length; i++) {
    if (a[i] === "--ts") o.ts = path.resolve(a[++i]);
    else if (a[i] === "--stack") o.stack = +a[++i];
    else if (a[i] === "--heap") o.heap = +a[++i];
    else if (a[i] === "--entry") o.entries.push(a[++i]);
    else if (a[i] === "--show") o.show = true;
    else if (a[i] === "--input") o.input = a[++i];
    else o.file = path.resolve(a[i]);
  }
  if (!o.entries.length) o.entries.push("Main");
  if (!o.file) {
    console.error("usage: node scripts/tsc_eval.mjs [--ts typescript.js] [--stack MB] [--heap MB] [--entry Main] [--input text] prog.ts");
    process.exit(2);
  }
  const w = new Worker(new URL(import.meta.url), {
    workerData: o,
    resourceLimits: { stackSizeMb: o.stack, maxOldGenerationSizeMb: o.heap },
  });
  let code = 1;
  w.on("message", m => {
    if (m.out !== undefined) process.stdout.write(Buffer.from(m.out, "latin1"));
    if (m.code !== undefined) code = m.code;
  });
  w.on("error", e => { console.error("tsc_eval: worker failed:", e && e.stack || e); code = 3; });
  w.on("exit", () => process.exit(code));
} else {
  const o = workerData;
  const require = createRequire(import.meta.url);
  const ts = require(o.ts);
  const t0 = Date.now();
  // the entry: an alias of Main applied to the input
  const entryFile = o.file.replace(/\.ts$/, "") + ".tsc_entry.ts";
  const mod = "./" + path.basename(o.file).replace(/\.ts$/, "");
  const arg = o.input === null ? "" : `<${JSON.stringify(o.input)}>`;
  const names = o.entries.map((e, i) => `TststResult${i}`);
  writeFileSync(entryFile, `import type { ${[...new Set(o.entries.map(e => e.replace(/<.*/s, "")))].join(", ")} } from ${JSON.stringify(mod)};\n` +
    o.entries.map((e, i) => `export type ${names[i]} = ${e}${arg};\n`).join(""));
  const prog = ts.createProgram([entryFile], {
    strict: true, noEmit: true, target: ts.ScriptTarget.ESNext, skipLibCheck: true, types: [],
  });
  const sf = prog.getSourceFile(entryFile);
  const t1 = Date.now();
  // checking the entry file evaluates the aliases; errors raised while
  // instantiating are reported there
  const diags = prog.getSemanticDiagnostics(sf);
  const checker = prog.getTypeChecker();
  const decls = [];
  ts.forEachChild(sf, n => { if (ts.isTypeAliasDeclaration(n)) decls.push(n); });
  const types = decls.map(d => checker.getTypeAtLocation(d.name));
  const t2 = Date.now();
  rmSync(entryFile, { force: true });
  for (const d of diags) console.error("tsc_eval: error: " + ts.flattenDiagnosticMessageText(d.messageText, " ").slice(0, 500));
  const stats = `tsc ${ts.version}: parse+bind ${t1 - t0} ms, check ${t2 - t1} ms, ${checker.getInstantiationCount()} instantiations, ${checker.getTypeCount()} types`;
  console.error("tsc_eval: " + stats);
  if (o.show) {
    const out = types.map((t, i) => `${o.entries[i]} = ${checker.typeToString(t, undefined, ts.TypeFormatFlags.NoTruncation)}\n`).join("");
    parentPort.postMessage({ out: Buffer.from(out, "utf8").toString("latin1"), code: diags.length ? 1 : 0 });
  } else if (types[0].flags & ts.TypeFlags.StringLiteral) {
    parentPort.postMessage({ out: types[0].value, code: diags.length ? 1 : 0 });
  } else {
    const s = checker.typeToString(types[0], undefined, ts.TypeFormatFlags.NoTruncation);
    console.error(`tsc_eval: ${o.entries[0]} is not a string literal: ${s.slice(0, 1000)}`);
    parentPort.postMessage({ code: 1 });
  }
}
