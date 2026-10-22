// Differential test of compiled programs against tsc.
// For every parameterless alias X in a test file, the compiled program prints its value V;
// tsc then checks Equal<X, V> for all of them.
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import ts from "typescript";

const files = process.argv.slice(2);
let total = 0, failed = 0;
for (const file of files) {
  let out;
  try {
    const exe = path.join("out", "difftest", path.basename(file, ".ts"));
    fs.mkdirSync(path.dirname(exe), { recursive: true });
    execFileSync("./tstc", ["build", file, "-o", exe, "--rt", "rt", ...(process.env.TSTC_FLAGS || "").split(" ").filter(Boolean)], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
    out = execFileSync(exe, ["dump"], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  } catch (e) {
    console.log(`FAIL ${file}: ${(e.stderr || e.message).toString().slice(0, 1500)}`);
    failed++;
    continue;
  }
  const lines = out.split("\n").filter(Boolean);
  const src = fs.readFileSync(file, "utf8");
  let check = src + "\n// ---- generated checks ----\n";
  check += "type __Equal<X, Y> = (<T>() => T extends X ? 1 : 2) extends (<T>() => T extends Y ? 1 : 2) ? true : false;\n";
  check += "type __Assert<T extends true> = T;\n";
  const names = [];
  for (const line of lines) {
    const i = line.indexOf(" = ");
    const name = line.slice(0, i);
    const val = line.slice(i + 3);
    names.push([name, val]);
    // (the value as an alias of its own, see conform.mjs)
    check += `type __val_${name} = ${val};\n`;
    check += `type __chk_${name} = __Assert<__Equal<${name}, __val_${name}>>;\n`;
  }
  const tmp = path.join("out", "difftest", "chk_" + path.basename(file));
  fs.mkdirSync(path.dirname(tmp), { recursive: true });
  fs.writeFileSync(tmp, check);
  const prog = ts.createProgram([tmp], { strict: true, noEmit: true, target: ts.ScriptTarget.ESNext, skipLibCheck: true });
  const diags = ts.getPreEmitDiagnostics(prog).filter(d => d.file && d.file.fileName.endsWith("chk_" + path.basename(file)));
  const bad = new Map();
  for (const d of diags) {
    const { line } = d.file.getLineAndCharacterOfPosition(d.start);
    const text = d.file.text.split("\n")[line];
    const m = /type __(?:chk|val)_(\w+)/.exec(text);
    const key = m ? m[1] : `line ${line + 1}`;
    if (!bad.has(key)) bad.set(key, ts.flattenDiagnosticMessageText(d.messageText, " ").slice(0, 300));
  }
  for (const [name, val] of names) {
    total++;
    if (bad.has(name)) {
      failed++;
      // what does tsc think it is?
      const checker = prog.getTypeChecker();
      const sf = prog.getSourceFile(tmp);
      let tscType = "?";
      ts.forEachChild(sf, n => {
        if (ts.isTypeAliasDeclaration(n) && n.name.text === name) {
          tscType = checker.typeToString(checker.getTypeAtLocation(n.name), undefined, ts.TypeFormatFlags.NoTruncation | ts.TypeFormatFlags.InTypeAlias);
        }
      });
      console.log(`FAIL ${path.basename(file)} ${name}: tstc=${val.slice(0, 200)} tsc=${tscType.slice(0, 200)}`);
    }
  }
  for (const [k, v] of bad) if (!names.some(n => n[0] === k)) { console.log(`ERR ${path.basename(file)} ${k}: ${v}`); }
}
console.log(`difftest: ${total - failed}/${total} passed`);
