// Prints what tsc computes for each type alias of a file (and its errors).
// usage: node scripts/tscval.mjs <file.ts> [alias...]
import ts from "typescript";
const [file, ...only] = process.argv.slice(2);
const prog = ts.createProgram([file], { strict: true, noEmit: true, target: ts.ScriptTarget.ESNext, skipLibCheck: true });
const checker = prog.getTypeChecker();
const sf = prog.getSourceFile(file);
for (const d of ts.getPreEmitDiagnostics(prog, sf)) {
  const { line } = d.file.getLineAndCharacterOfPosition(d.start);
  console.log(`ERR line ${line + 1}: ${ts.flattenDiagnosticMessageText(d.messageText, " ").slice(0, 300)}`);
}
ts.forEachChild(sf, n => {
  if (ts.isTypeAliasDeclaration(n) && !n.typeParameters && (only.length === 0 || only.includes(n.name.text))) {
    const t = checker.getTypeAtLocation(n.name);
    console.log(`${n.name.text} = ${checker.typeToString(t, undefined, ts.TypeFormatFlags.NoTruncation | ts.TypeFormatFlags.InTypeAlias)}`);
  }
});
