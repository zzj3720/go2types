// Benchmarks of hand-written type-level programs: every parameterless alias
// of a file is evaluated by the compiled program (`dump`), checked against
// tsc like scripts/difftest.mjs, and timed against tsc's checker.
//
//   node bench/run.mjs [--tstc ./tstc] [--rt rt] [--runs 3] [--tsc] [--tsgo path] [--label x] files...
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import ts from "typescript";

const args = process.argv.slice(2);
const opt = { tstc: "./tstc", rt: "rt", runs: 3, tsc: false, tsgo: "", label: "cur", flags: [], timeout: 60000 };
const files = [];
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (a === "--tstc") opt.tstc = args[++i];
  else if (a === "--rt") opt.rt = args[++i];
  else if (a === "--runs") opt.runs = +args[++i];
  else if (a === "--tsc") opt.tsc = true;
  else if (a === "--tsgo") opt.tsgo = args[++i];
  else if (a === "--label") opt.label = args[++i];
  else if (a === "--timeout") opt.timeout = +args[++i] * 1000;
  else if (a === "--ref") opt.ref = args[++i];
  else if (a === "--flag") opt.flags.push(args[++i]);
  else files.push(a);
}

const now = () => Number(process.hrtime.bigint()) / 1e6;
function timed(f) { const t = now(); const r = f(); return [r, now() - t]; }
const outDir = path.join("out", "bench", opt.label);
fs.mkdirSync(outDir, { recursive: true });

function tscCheck(file, lines) {
  const src = fs.readFileSync(file, "utf8");
  let check = src + "\n// ---- generated checks ----\n";
  check += "type __Equal<X, Y> = (<T>() => T extends X ? 1 : 2) extends (<T>() => T extends Y ? 1 : 2) ? true : false;\n";
  check += "type __Assert<T extends true> = T;\n";
  const names = [];
  for (const line of lines) {
    const i = line.indexOf(" = ");
    names.push([line.slice(0, i), line.slice(i + 3)]);
    check += `type __chk_${line.slice(0, i)} = __Assert<__Equal<${line.slice(0, i)}, ${line.slice(i + 3)}>>;\n`;
  }
  const tmp = path.join(outDir, "chk_" + path.basename(file));
  fs.writeFileSync(tmp, check);
  const prog = ts.createProgram([tmp], { strict: true, noEmit: true, target: ts.ScriptTarget.ESNext, skipLibCheck: true });
  const diags = ts.getPreEmitDiagnostics(prog);
  const bad = [];
  for (const d of diags) {
    if (!d.file) { bad.push(ts.flattenDiagnosticMessageText(d.messageText, " ").slice(0, 200)); continue; }
    const { line } = d.file.getLineAndCharacterOfPosition(d.start);
    const text = d.file.text.split("\n")[line];
    const m = /type __chk_(\w+)/.exec(text);
    bad.push(`${m ? m[1] : "line " + (line + 1)}: ${ts.flattenDiagnosticMessageText(d.messageText, " ").slice(0, 200)}`);
  }
  return { tmp, names, bad };
}

// the checker's time on the file of checks (best of n)
function tscTime(cmd, cmdArgs, n) {
  let best = Infinity;
  for (let i = 0; i < n; i++) {
    let out;
    try {
      out = execFileSync(cmd, cmdArgs, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], maxBuffer: 1 << 26 });
    } catch (e) { out = (e.stdout || "").toString(); }
    const m = /Check time:\s+([\d.]+)s/.exec(out);
    if (!m) return NaN;
    best = Math.min(best, parseFloat(m[1]) * 1000);
  }
  return best;
}

const rows = [];
for (const file of files) {
  const name = path.basename(file, ".ts");
  const exe = path.join(outDir, name);
  const row = { name };
  try {
    [, row.build] = timed(() => execFileSync(opt.tstc, ["build", file, "-o", exe, "--rt", opt.rt, ...opt.flags], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }));
  } catch (e) {
    row.error = "build: " + (e.stderr || e.message).toString().slice(0, 500);
    rows.push(row); console.log(JSON.stringify(row)); continue;
  }
  // the intermediates of the build
  for (const f of fs.readdirSync(outDir))
    if (f.startsWith(name + ".") && (f.endsWith(".ll") || f.endsWith(".ll.o") || f.endsWith(".bc"))) fs.rmSync(path.join(outDir, f));
  let out = "";
  row.run = Infinity;
  try {
    for (let i = 0; i < opt.runs; i++) {
      const [o, t] = timed(() => execFileSync(exe, ["dump"], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], maxBuffer: 1 << 28, timeout: opt.timeout, killSignal: "SIGKILL" }));
      out = o;
      row.run = Math.min(row.run, t);
    }
  } catch (e) {
    row.error = "run: " + (e.stderr || e.message).toString().slice(0, 500);
    rows.push(row); console.log(JSON.stringify(row)); continue;
  }
  const lines = out.split("\n").filter(Boolean);
  fs.writeFileSync(exe + ".out", out);
  row.aliases = lines.length;
  if (opt.ref) {
    // the outputs of another run (another compiler) of the same file
    const rf = path.join("out", "bench", opt.ref, name + ".out");
    if (!fs.existsSync(rf)) row.vsref = "no ref";
    else {
      const rl = fs.readFileSync(rf, "utf8").split("\n").filter(Boolean);
      const diff = lines.filter((l, i) => l !== rl[i]).length + Math.abs(lines.length - rl.length);
      row.vsref = diff ? `DIFF ${diff}` : "same";
    }
  }
  if (opt.tsc) {
    const { tmp, bad } = tscCheck(file, lines);
    row.bad = bad;
    const tscArgs = ["--noEmit", "--strict", "--target", "esnext", "--skipLibCheck", "--extendedDiagnostics", tmp];
    row.tsc = tscTime(process.execPath, [path.join("node_modules", "typescript", "lib", "tsc.js"), ...tscArgs], 2);
    if (opt.tsgo) row.tsgo = tscTime(opt.tsgo, tscArgs, 2);
  }
  rows.push(row);
  console.log(JSON.stringify(row));
}
fs.writeFileSync(path.join(outDir, "results.json"), JSON.stringify(rows, null, 1));
const f = x => (x === undefined ? "-" : Number.isNaN(x) ? "?" : x.toFixed(1));
console.log("| program | aliases | tstc build ms | tstc run ms |" + (opt.tsc ? " tsc check ms |" + (opt.tsgo ? " tsgo check ms |" : "") + " vs tsc |" : "") + (opt.ref ? ` vs ${opt.ref} |` : ""));
for (const r of rows) {
  if (r.error) { console.log(`| ${r.name} | ERROR ${r.error.split("\n")[0]} |`); continue; }
  let s = `| ${r.name} | ${r.aliases} | ${f(r.build)} | ${f(r.run)} |`;
  if (opt.tsc) s += ` ${f(r.tsc)} |` + (opt.tsgo ? ` ${f(r.tsgo)} |` : "") + ` ${r.bad.length ? "MISMATCH " + r.bad.length : "same"} |`;
  if (opt.ref) s += ` ${r.vsref} |`;
  console.log(s);
}
for (const r of rows) for (const b of r.bad || []) console.log(`  ${r.name}: ${b}`);
