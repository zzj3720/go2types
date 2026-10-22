// Conformance of tstc with tsgo: what tstc runs, tsgo computes the same.
//
// For programs tsgo accepts, tstc must compute the value tsgo does for every
// parameterless alias (tsgo checks Equal<Alias, tstc's value>). For programs
// tsgo rejects, tstc must reject them too (tstc build fails). The only
// differences allowed are the checkers' artificial limits: whether a program
// is valid is decided by the stock tsgo (TSGO_CHECK), whose limit errors
// (LIMITS) do not count; values are computed by a tsgo without the limits
// (TSGO: scripts/tsgo_build.sh of tstst). No program is left out.
//
// usage: node scripts/conform.mjs [--seed S] [--n N] [--batch B] [--depth D]
//          [--invalid N] [--files a.ts ...] [--keep]
//   --n N        N random valid programs (seeds S..S+N-1), B per tstc build
//   --invalid N  N random programs with a rule bent (one build each)
//   --files      these files instead (each a program)
//   --jobs K     K processes, each a share of the batches (default: half the
//                cores the 15-minute load average leaves)
// env: TSGO (the tsgo without limits), TSGO_CHECK (the stock tsgo; both
// required), TSTC_FLAGS
// Prints one line per finding and a summary; exits 1 on a conformance failure:
//   MISMATCH     tstc's value differs from tsgo's
//   ACCEPTS      tsgo reports an error, tstc builds and runs the program
// and lists (without failing) what tstc does not support yet:
//   REJECTS      tstc rejects a program tsgo accepts
//   DIES         a tstc program fails at run time on a program tsgo accepts
// Reproducers go to out/conform/<kind>-<id>.ts.
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { program } from "./conform/gen.mjs";

const argv = process.argv.slice(2);
const opt = (k, d) => {
  const i = argv.indexOf(k);
  return i >= 0 ? argv[i + 1] : d;
};
const seed0 = Number(opt("--seed", 1));
const nValid = Number(opt("--n", 0));
const nInvalid = Number(opt("--invalid", 0));
const batch = Number(opt("--batch", 100));
const depth = Number(opt("--depth", 3));
const fi = argv.indexOf("--files");
const files = fi >= 0 ? argv.slice(fi + 1).filter(a => !a.startsWith("--")) : [];
const TSGO = process.env.TSGO;
const TSGO_CHECK = process.env.TSGO_CHECK;
if (!TSGO || !TSGO_CHECK) {
  console.error("conform: set TSGO to a tsgo without the checkers' limits (tstst scripts/tsgo_build.sh) and TSGO_CHECK to the stock tsgo");
  process.exit(2);
}
// the checkers' artificial limits: instantiation depth and count, union
// size, relation depth and complexity (the patched tsgo has none of them;
// it cannot check generic declarations, which without the limits instantiate
// forever, so validity is the stock tsgo's)
const LIMITS = new Set(["TS2589", "TS2590", "TS2321", "TS2859"]);
const FLAGS = (process.env.TSTC_FLAGS || `-O f --llvm ${process.env.LLVM_BIN || "/opt/homebrew/opt/llvm@22/bin"} -j 4`).split(" ").filter(Boolean);
const OUT = path.resolve("out/conform");
fs.mkdirSync(OUT, { recursive: true });

const counts = { checked: 0, programs: 0, MISMATCH: 0, ACCEPTS: 0, REJECTS: 0, DIES: 0, BOTH_REJECT: 0, TSGO_FAILED: 0 };
const failing = new Set(["MISMATCH", "ACCEPTS"]);

function run(cmd, args, timeout) {
  // (SIGKILL: tsgo outlives a SIGTERM)
  const r = spawnSync(cmd, args, { encoding: "utf8", timeout: timeout * 1000, killSignal: "SIGKILL", maxBuffer: 1 << 30 });
  return { code: r.status, out: r.stdout || "", err: (r.stderr || "") + (r.error ? String(r.error) : ""), timedOut: r.error?.code === "ETIMEDOUT" };
}

function report(kind, id, text, detail) {
  counts[kind]++;
  const f = path.join(OUT, `${kind}-${id}.ts`);
  fs.writeFileSync(f, text + (detail ? `\n// ${detail.replace(/\n/g, "\n// ")}\n` : ""));
  console.log(`${kind} ${id}: ${(detail || "").split("\n")[0].slice(0, 300)}  (${path.relative(process.cwd(), f)})`);
}

// tsgo's errors in a file: [{line (1-based), code, msg}]; the stock tsgo
// without its limit errors, or (values) the one without limits
function tsgoErrors(file, values = false) {
  const r = run(values ? TSGO : TSGO_CHECK, ["--noEmit", "--strict", "--pretty", "false", "--target", "esnext", "--skipLibCheck", file], 600);
  if (r.timedOut) return { timedOut: true, errs: [] };
  // (an error in another file, one the program imports, is the program's:
  // line 0)
  const errs = [];
  for (const l of r.out.split("\n")) {
    const m = /^(.*)\((\d+),(\d+)\): error (TS\d+): (.*)$/.exec(l);
    if (m) {
      const own = path.resolve(path.dirname(file), m[1]) === path.resolve(file) || path.basename(m[1]) === path.basename(file);
      errs.push({ line: own ? Number(m[2]) : 0, code: m[4], msg: own ? m[5] : `${m[1]}(${m[2]}): ${m[5]}` });
    }
  }
  if (r.code !== 0 && errs.length === 0) return { crashed: (r.err + r.out).split("\n").slice(0, 3).join(" ").slice(0, 300), errs };
  return { errs: values ? errs : errs.filter(e => !LIMITS.has(e.code)) };
}

// text (of a file in dir) for the tsgo without limits: the files it imports
// become declaration files, which --skipLibCheck leaves unchecked (their
// generic declarations would instantiate forever); what is evaluated is the
// same. Writes it as name in a directory of its own, returns the path.
function forValues(text, dir, name) {
  const T = path.join(OUT, `.values-${name.replace(/\.ts$/, "")}`);
  fs.rmSync(T, { recursive: true, force: true });
  fs.mkdirSync(T, { recursive: true });
  const dirs = new Map();
  const out = text.replace(/from "(\.{1,2}\/[^"]+)"/g, (m, spec) => {
    const target = path.resolve(dir, spec);
    const d = path.dirname(target);
    if (!dirs.has(d)) {
      const k = `d${dirs.size}`;
      dirs.set(d, k);
      fs.mkdirSync(path.join(T, k));
      for (const f of fs.readdirSync(d))
        if (f.endsWith(".ts") && !f.endsWith(".d.ts") && !f.startsWith(".")) fs.copyFileSync(path.join(d, f), path.join(T, k, f.replace(/\.ts$/, ".d.ts")));
    }
    return `from "./${dirs.get(d)}/${path.basename(target)}"`;
  });
  const f = path.join(T, name);
  fs.writeFileSync(f, out);
  return f;
}

// tstc's values of the parameterless aliases: {ok, values: Map, stage, msg}
function tstcValues(file) {
  const exe = file.replace(/\.ts$/, "");
  const b = run("./tstc", ["build", file, "-o", exe, "--rt", "rt", "--no-cache", ...FLAGS], 900);
  if (b.code !== 0) return { ok: false, stage: "build", msg: (b.err + b.out).trim().slice(-2000) };
  const d = run(exe, ["dump"], 300);
  for (const f of [exe, exe + ".ll"]) fs.rmSync(f, { force: true });
  if (d.code !== 0) return { ok: false, stage: "run", msg: (d.err || (d.timedOut ? "timed out" : `exit ${d.code}`)).trim().slice(-2000) };
  const values = new Map();
  for (const l of d.out.split("\n")) {
    const i = l.indexOf(" = ");
    if (i > 0) values.set(l.slice(0, i), l.slice(i + 3));
  }
  return { ok: true, values };
}

const HEADER =
  "type __Equal<X, Y> = (<T>() => T extends X ? 1 : 2) extends (<T>() => T extends Y ? 1 : 2) ? true : false;\n" +
  "type __Assert<T extends true> = T;\n";

// compares tstc's values with tsgo's for the programs of text (names: the
// aliases to check, each with its program id); returns the ids that mismatch
function compare(text, values, names, file) {
  let chk = text + "\n// ---- checks ----\n" + HEADER;
  const at = new Map();
  let line = chk.split("\n").length;
  for (const [n, id] of names) {
    if (!values.has(n)) continue;
    // (the value as an alias of its own: as written in a type argument, a
    // type with substitution types is no alias's type)
    chk += `type __val_${n} = ${values.get(n)};\n`;
    at.set(line++, [n, id]);
    chk += `type __chk_${n} = __Assert<__Equal<${n}, __val_${n}>>;\n`;
    at.set(line++, [n, id]);
    counts.checked++;
  }
  const vf = forValues(chk, path.dirname(file), path.basename(file));
  const { errs, timedOut, crashed } = tsgoErrors(vf, true);
  fs.rmSync(path.dirname(vf), { recursive: true, force: true });
  if (timedOut || crashed) {
    counts.TSGO_FAILED++;
    console.log(`TSGO-FAILED ${file}: ${timedOut ? "tsgo did not finish in 600 s" : crashed}`);
    return new Map();
  }
  const bad = new Map();
  for (const e of errs) {
    const hit = at.get(e.line);
    if (e.line === 0) continue;  // (in a declaration file)
    if (hit && !bad.has(hit[0])) bad.set(hit[0], { id: hit[1], msg: `${e.code} ${e.msg}` });
    else if (!hit) bad.set(`line ${e.line}`, { id: null, msg: `${e.code} ${e.msg}` });
  }
  return bad;
}

// tsgo's type of each alias, for the reports
function tsgoShow(text, ns, file) {
  let s = text + "\n";
  const first = s.split("\n").length;
  // the alias's body, not its name (a checker prints a type made by an alias as the alias's name)
  const body = n => {
    const m = new RegExp(`^(?:export )?type ${n} = (.*);$`, "m").exec(text);
    return m ? m[1] : n;
  };
  ns.forEach((n, k) => (s += `const __show_${k}: [${body(n)}] = 0 as unknown as "__show";\n`));
  const vf = forValues(s, path.dirname(file), path.basename(file));
  const { errs } = tsgoErrors(vf, true);
  fs.rmSync(path.dirname(vf), { recursive: true, force: true });
  const m = new Map();
  for (const e of errs) {
    const k = e.line - first;
    if (k >= 0 && k < ns.length) {
      const t = /to type '\[(.*)\]'/.exec(e.msg);
      m.set(ns[k], t ? t[1] : e.msg);
    }
  }
  return m;
}

// one or more programs: [{id, lines}] checked together; a failure of the
// whole build splits them
function checkPrograms(progs, tag) {
  if (progs.length === 0) return;
  // (a file's program is checked beside it, where its imports resolve)
  const dir = progs[0].dir || OUT;
  const base = path.join(dir, `.conform-${tag}`);
  // the line ranges of the programs, for tsgo's errors
  let text = "";
  const ranges = [];
  for (const p of progs) {
    const start = text.split("\n").length;
    text += p.lines.join("\n") + "\n";
    ranges.push([start, text.split("\n").length - 1, p]);
  }
  const progAt = l => (l === 0 ? progs[0] : ranges.find(([a, b]) => l >= a && l <= b)?.[2]);
  fs.writeFileSync(base + ".ts", text);
  const { errs, timedOut, crashed } = tsgoErrors(base + ".ts");
  if (timedOut || crashed) {
    fs.rmSync(base + ".ts", { force: true });
    if (progs.length > 1) return split(progs, tag);
    counts.TSGO_FAILED++;
    console.log(`TSGO-FAILED ${progs[0].id}: ${timedOut ? "tsgo did not finish in 600 s" : crashed}`);
    return;
  }
  const rejected = new Map();
  for (const e of errs) {
    const p = progAt(e.line);
    if (p && !rejected.has(p)) rejected.set(p, `${e.code} line ${e.line - ranges.find(r => r[2] === p)[0] + 1}: ${e.msg}`);
  }
  // programs tsgo rejects: tstc must reject them (at build, or when run)
  for (const [p, why] of rejected) {
    counts.programs++;
    const one = path.join(dir, `.conform-${tag}-${p.id}.ts`);
    const src = p.lines.join("\n") + "\n";
    fs.writeFileSync(one, src);
    const t = tstcValues(one);
    if (t.ok) report("ACCEPTS", p.id, src, `tsgo: ${why}\ntstc: ${[...t.values].map(([k, v]) => `${k} = ${v}`).join("; ").slice(0, 1000)}`);
    else counts.BOTH_REJECT++;
    fs.rmSync(one, { force: true });
  }
  fs.rmSync(base + ".ts", { force: true });
  const ok = progs.filter(p => !rejected.has(p));
  if (ok.length === 0) return;
  if (ok.length < progs.length) return checkAccepted(ok, tag);
  return checkAccepted(ok, tag, text);
}

function checkAccepted(progs, tag, text) {
  const base = path.join(progs[0].dir || OUT, `.conform-${tag}-ok`);
  text ??= progs.map(p => p.lines.join("\n") + "\n").join("");
  fs.writeFileSync(base + ".ts", text);
  const t = tstcValues(base + ".ts");
  if (!t.ok && t.stage === "build" && progs.length > 1) {
    // the program at the line tstc names
    const m = /-ok\.ts:(\d+):\d+: /.exec(t.msg);
    if (m) {
      let line = 1;
      const p = progs.find(q => {
        const end = line + q.lines.length;
        const hit = Number(m[1]) >= line && Number(m[1]) < end;
        line = end;
        return hit;
      });
      if (p) {
        counts.programs++;
        report("REJECTS", p.id, p.lines.join("\n") + "\n", t.msg.replace(/^.*-ok\.ts:\d+:\d+: /s, ""));
        fs.rmSync(base + ".ts", { force: true });
        return checkAccepted(progs.filter(q => q !== p), tag);
      }
    }
  }
  if (!t.ok) {
    fs.rmSync(base + ".ts", { force: true });
    if (progs.length > 1) return split(progs, tag);
    counts.programs++;
    report(t.stage === "build" ? "REJECTS" : "DIES", progs[0].id, text, t.msg);
    return;
  }
  counts.programs += progs.length;
  const names = [];
  for (const p of progs)
    for (const l of p.lines) {
      const m = /^(?:export )?type (\w+) =/.exec(l);
      if (m) names.push([m[1], p.id]);
    }
  const bad = compare(text, t.values, names, base + "-chk.ts");
  const byProg = new Map();
  for (const [n, b] of bad) {
    const p = progs.find(q => q.id === b.id) || null;
    if (!byProg.has(p)) byProg.set(p, []);
    byProg.get(p).push(n);
  }
  for (const [p, ns] of byProg) {
    const src = p ? p.lines.join("\n") + "\n" : text;
    const shown = p ? tsgoShow(src, ns, base + "-show.ts") : new Map();
    report("MISMATCH", p ? p.id : tag, src, ns.map(n => `${n}: tstc ${(t.values.get(n) || "?").slice(0, 400)} | tsgo ${(shown.get(n) || bad.get(n).msg).slice(0, 400)}`).join("\n"));
  }
  for (const f of [base + ".ts", base + "-chk.ts", base + "-show.ts"]) fs.rmSync(f, { force: true });
}

function split(progs, tag) {
  const h = progs.length >> 1;
  checkPrograms(progs.slice(0, h), tag + "a");
  checkPrograms(progs.slice(h), tag + "b");
}

const t0 = Date.now();
// the work: files, batches of valid programs, invalid programs; --shard i/K
// (a process of --jobs K) does every K-th from the i-th
const work = [];
for (const f of files) work.push(() => {
  const lines = fs.readFileSync(f, "utf8").split("\n");
  checkPrograms([{ id: path.basename(f, ".ts"), lines, dir: path.dirname(path.resolve(f)) }], path.basename(f, ".ts"));
});
for (let s = seed0; s < seed0 + nValid; s += batch) work.push(() => {
  const progs = [];
  for (let k = s; k < Math.min(s + batch, seed0 + nValid); k++) progs.push({ id: `v${k}`, ...program(k, `P${k}`, { depth }) });
  checkPrograms(progs, `v${s}`);
  fs.rmSync(path.join(OUT, `.conform-v${s}.ts`), { force: true });
});
for (let k = seed0; k < seed0 + nInvalid; k++) work.push(() => {
  checkPrograms([{ id: `i${k}`, ...program(k, `Q${k}`, { depth: 2, invalid: true }) }], `i${k}`);
  fs.rmSync(path.join(OUT, `.conform-i${k}.ts`), { force: true });
});
const shard = opt("--shard", "");
const jobs = Number(opt("--jobs", Math.max(1, Math.floor((os.cpus().length - os.loadavg()[2]) / 2))));
if (shard) {
  const [i, K] = shard.split("/").map(Number);
  work.forEach((w, n) => n % K === i && w());
  console.log(`conform-counts ${JSON.stringify(counts)}`);
  process.exit(0);
}
let broken = 0;
if (jobs > 1) {
  // the shards' findings as they come, their counts summed
  const K = Math.min(jobs, work.length);
  const shards = Array.from({ length: K }, (_, i) => new Promise(done => {
    const c = spawn(process.execPath, [process.argv[1], "--shard", `${i}/${K}`, ...argv], { stdio: ["ignore", "pipe", "inherit"] });
    let buf = "", got = false;
    c.stdout.on("data", d => {
      buf += d;
      let n;
      while ((n = buf.indexOf("\n")) >= 0) {
        const l = buf.slice(0, n);
        buf = buf.slice(n + 1);
        if (l.startsWith("conform-counts ")) {
          got = true;
          for (const [k, v] of Object.entries(JSON.parse(l.slice(15)))) counts[k] += v;
        } else console.log(l);
      }
    });
    c.on("close", code => {
      if (!got) {
        console.log(`conform: shard ${i}/${K} ended without its counts (exit ${code})`);
        broken++;
      }
      done();
    });
  }));
  await Promise.all(shards);
} else work.forEach(w => w());
const fails = [...failing].reduce((a, k) => a + counts[k], 0);
console.log(
  `conform: ${counts.programs} programs, ${counts.checked} values compared in ${((Date.now() - t0) / 1000).toFixed(0)} s: ` +
    `${counts.MISMATCH} mismatches, ${counts.ACCEPTS} accepted that tsgo rejects (${counts.BOTH_REJECT} rejected by both); ` +
    `not supported: ${counts.REJECTS} rejected, ${counts.DIES} died; tsgo failed (crash or timeout) on ${counts.TSGO_FAILED}`
);
process.exit(fails > 0 || broken > 0 ? 1 : 0);
