// Random type-level programs for scripts/conform.mjs.
//
// A program is a few aliases named <prefix>_<name>: generic helpers and
// parameterless outputs. Valid programs are well-formed TypeScript by
// construction (every construct is guarded so that tsc/tsgo accept it), so
// the checker and tstc must agree on every output. Invalid programs bend one
// rule (a constraint, an arity, an unbound name, a bad index...): when tsgo
// reports an error for one, tstc must reject it too.

export function rng(seed) {
  let s = seed >>> 0;
  const next = () => {
    s = (s + 0x6d2b79f5) >>> 0;
    let t = s;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  const r = {
    f: next,
    int: n => Math.floor(next() * n),
    pick: a => a[Math.floor(next() * a.length)],
    chance: p => next() < p,
  };
  return r;
}

const STRS = ['""', '"a"', '"b"', '"ab"', '"abc"', '"hello"', '"a,b,c"', '"x y"', '"A"', '"Ab"', '"1"', '"12"', '"-3"', '"1.5"', '"true"', '"foo.bar"', '" a "', '"a\\nb"', '"\\u00e9"'];
const NUMS = ["0", "1", "2", "3", "7", "42", "-1", "1.5", "0.1", "-2.5", "1e21", "123456789", "0.000001", "1e-7"];
const BIGS = ["0n", "1n", "2n", "-5n", "10n", "12345678901234567890n"];
const KW = ["string", "number", "bigint", "boolean", "unknown", "any", "never", "object", "void", "{}", "null", "undefined"];
const KEYS = ["a", "b", "c", "x", '"x y"', "0", "1", "length"];
const LABELS = ["a", "b", "c", "d"];
// keys as types
const KEYT = ['"a"', '"b"', '"c"', '"x"', '"x y"', "0", "1", '"length"'];

export class Gen {
  constructor(r, prefix) {
    this.r = r;
    this.p = prefix;
    this.helpers = [];
    this.n = 0;
  }
  name(s) {
    return `${this.p}_${s}${this.n++}`;
  }
  helper(params, body) {
    const n = this.name("H");
    this.helpers.push(`type ${n}${params ? `<${params}>` : ""} = ${body};`);
    return n;
  }

  // a string-like type usable in a template placeholder
  strish(d) {
    const r = this.r;
    switch (d <= 0 ? r.int(3) : r.int(8)) {
      case 0: return r.pick(STRS);
      case 1: return r.pick(NUMS.concat(BIGS, ["true", "false", "null", "undefined"]));
      case 2: return r.pick(["string", "number", "bigint", "boolean", "never", "any"]);
      case 3: return `${r.pick(STRS)} | ${r.pick(STRS)}`;
      case 4: return this.template(d - 1);
      case 5: return `${r.pick(["Uppercase", "Lowercase", "Capitalize", "Uncapitalize"])}<${this.strOnly(d - 1)}>`;
      case 6: return `${r.pick(NUMS)} | ${r.pick(BIGS)}`;
      default: return this.strOnly(d - 1);
    }
  }
  // a type assignable to string
  strOnly(d) {
    const r = this.r;
    switch (d <= 0 ? r.int(2) : r.int(5)) {
      case 0: return r.pick(STRS);
      case 1: return `${r.pick(STRS)} | ${r.pick(STRS)}`;
      case 2: return this.template(d - 1);
      case 3: return "string";
      default: return `${r.pick(["Uppercase", "Lowercase", "Capitalize", "Uncapitalize"])}<${this.strOnly(d - 1)}>`;
    }
  }
  template(d) {
    const r = this.r;
    let s = "`";
    const n = 1 + r.int(3);
    for (let i = 0; i < n; i++) {
      s += r.pick(["", "a", "-", ".", "x", " ", "1", "\\n"]);
      if (r.chance(0.8)) s += "${" + this.strish(d - 1) + "}";
    }
    return s + r.pick(["", "z", "."]) + "`";
  }

  leaf() {
    const r = this.r;
    switch (r.int(5)) {
      case 0: return r.pick(STRS);
      case 1: return r.pick(NUMS);
      case 2: return r.pick(BIGS);
      case 3: return r.pick(["true", "false", "null", "undefined"]);
      default: return r.pick(KW);
    }
  }

  tuple(d) {
    const r = this.r;
    const n = r.int(4);
    const labeled = r.chance(0.15);
    const els = [];
    // optional elements only at the end or before a rest element; after a
    // rest element only required ones
    let opt = false, rest = false;
    for (let i = 0; i < n; i++) {
      const k = r.int(10);
      if (!rest && k === 0) {
        rest = true;
        const t = this.wrapArr(this.type(d - 1));
        els.push(labeled ? `...${LABELS[i]}: ${t}` : `...${t}`);
      } else if (!rest && (opt || k === 1)) {
        opt = true;
        const t = this.type(d - 1);
        els.push(labeled ? `${LABELS[i]}?: ${t}` : `${this.paren(t)}?`);
      } else if (rest && opt) {
        break;
      } else {
        const t = this.type(d - 1);
        els.push(labeled ? `${LABELS[i]}: ${t}` : t);
      }
    }
    const s = `[${els.join(", ")}]`;
    return r.chance(0.15) ? `readonly ${s}` : s;
  }
  wrapArr(t) {
    return `${this.paren(t)}[]`;
  }
  paren(t) {
    return /^[\w"`.\-{}\[\]]+$/.test(t) && !t.includes(" ") ? t : `(${t})`;
  }
  object(d) {
    const r = this.r;
    const ks = [...KEYS].sort(() => r.f() - 0.5).slice(0, r.int(4));
    const ps = ks.map(k => `${r.chance(0.2) ? "readonly " : ""}${k}${r.chance(0.25) ? "?" : ""}: ${this.type(d - 1)}`);
    if (r.chance(0.1)) ps.push(`[k: string]: ${r.pick(["unknown", "any", this.type(d - 1)])}`);
    return `{ ${ps.join("; ")} }`;
  }
  func(d) {
    const r = this.r;
    const n = r.int(3);
    const ps = [];
    let opt = false;
    for (let i = 0; i < n; i++) {
      opt = opt || r.chance(0.2);
      ps.push(`${LABELS[i]}${opt ? "?" : ""}: ${this.type(d - 1)}`);
    }
    if (r.chance(0.15)) ps.push(`...rest: ${this.wrapArr(this.type(d - 1))}`);
    return `((${ps.join(", ")}) => ${this.type(d - 1)})`;
  }

  // a variation of type T, for extends checks that are sometimes true
  mutate(t, d) {
    const r = this.r;
    switch (r.int(9)) {
      case 0: return t;
      case 1: return `${t} | ${this.leaf()}`;
      case 2: return r.pick(KW);
      case 3: return this.type(d);
      case 4: return `readonly ${this.wrapArr(r.pick(["unknown", "any", t]))}`;
      case 5: return `[${t}]`;
      case 6: return `{ a: ${t} }`;
      case 7: return this.pattern(d).pat;
      default: return `${t} & ${this.leaf()}`;
    }
  }

  // an extends clause with infer declarations, and what the true branch may use
  pattern(d) {
    const r = this.r;
    const v = ["X", "Y", "Z"];
    switch (r.int(11)) {
      case 0: return { pat: "[infer X, ...infer Y]", vars: v.slice(0, 2) };
      case 1: return { pat: "[...infer X, infer Y]", vars: v.slice(0, 2) };
      case 2: return { pat: "`${infer X}${infer Y}`", vars: v.slice(0, 2) };
      case 3: return { pat: `\`\${infer X}${r.pick([",", ".", " ", "a", "1"])}\${infer Y}\``, vars: v.slice(0, 2) };
      case 4: return { pat: `\`\${infer X extends ${r.pick(["number", "bigint", "boolean", "1 | 2", '"a"', "string"])}}\``, vars: ["X"] };
      case 5: return { pat: "{ a: infer X }", vars: ["X"] };
      case 6: return { pat: "(a: infer X) => infer Y", vars: v.slice(0, 2) };
      case 7: return { pat: "(infer X)[]", vars: ["X"] };
      case 8: return { pat: `[infer X extends ${this.leaf()}, ...infer Y extends unknown[]]`, vars: v.slice(0, 2) };
      case 9: return { pat: "{ a: infer X; b?: infer Y }", vars: v.slice(0, 2) };
      default: return { pat: `[infer X, infer X]`, vars: ["X"] };
    }
  }

  conditional(d) {
    const r = this.r;
    const a = this.type(d - 1);
    if (r.chance(0.5)) {
      const { pat, vars } = this.pattern(d - 1);
      const t = vars.length === 1 ? `[${vars[0]}]` : `[${vars.join(", ")}]`;
      return `(${a} extends ${pat} ? ${t} : ${this.leaf()})`;
    }
    return `(${a} extends ${this.mutate(a, d - 1)} ? ${this.type(d - 1)} : ${this.type(d - 1)})`;
  }

  // a generic helper applied to an argument
  generic(d) {
    const r = this.r;
    const arg = this.type(d - 1);
    switch (r.int(14)) {
      case 0: {
        // distributive over a union argument
        const h = this.helper("T", `T extends ${this.mutate(this.leaf(), d - 1)} ? [T] : ${this.leaf()}`);
        return `${h}<${arg} | ${this.leaf()}>`;
      }
      case 1: {
        const h = this.helper("T", `[T] extends [${this.mutate(this.leaf(), d - 1)}] ? true : false`);
        return `${h}<${arg}>`;
      }
      case 2: {
        // homomorphic mapped type (over objects, tuples and arrays)
        const mod = r.pick(["", "-readonly ", "+readonly ", "readonly "]);
        const opt = r.pick(["", "?", "-?", "+?"]);
        const val = r.pick(["T[K]", "[T[K]]", "K", `T[K] | ${this.leaf()}`, "T[K] extends string ? 1 : 0"]);
        const h = this.helper("T", `{ ${mod}[K in keyof T]${opt}: ${val} }`);
        return `${h}<${r.chance(0.5) ? this.tuple(d - 1) : this.object(d - 1)}>`;
      }
      case 3: {
        const h = this.helper("T", `{ [K in keyof T as K extends string ? \`${r.pick(["get", "x", ""])}\${Capitalize<K>}\` : never]: T[K] }`);
        return `${h}<${this.object(d - 1)}>`;
      }
      case 4: {
        const h = this.helper("T, K", "K extends keyof T ? T[K] : \"nokey\"");
        return `${h}<${r.chance(0.5) ? this.object(d - 1) : this.tuple(d - 1)}, ${r.pick(KEYT.concat(["number", "string", "keyof " + this.paren(arg)]))}>`;
      }
      case 5: return `keyof ${this.paren(r.chance(0.5) ? this.object(d - 1) : arg)}`;
      case 6: {
        const u = r.pick(["Exclude", "Extract"]);
        return `${u}<${arg} | ${this.leaf()} | ${this.leaf()}, ${this.mutate(this.leaf(), d - 1)}>`;
      }
      case 7: return `${r.pick(["Partial", "Required", "Readonly", "NonNullable"])}<${r.chance(0.6) ? this.object(d - 1) : arg}>`;
      case 8: {
        const o = this.object(d - 1);
        const k = r.pick(KEYT);
        return r.chance(0.5) ? `Pick<${o}, Extract<keyof ${o}, ${k}>>` : `Omit<${o}, ${k}>`;
      }
      case 9: return `Record<${r.pick(KEYT)} | ${r.pick(KEYT)}, ${arg}>`;
      case 10: return `${r.pick(["ReturnType", "Parameters"])}<${this.func(d - 1)}>`;
      case 11: return this.idiom(d);
      case 12: {
        const h = this.helper("T", `T extends string ? ${r.pick(["Uppercase", "Lowercase", "Capitalize", "Uncapitalize"])}<T> : T`);
        return `${h}<${r.chance(0.6) ? this.strOnly(d - 1) : arg}>`;
      }
      default: {
        // the identity check
        const b = r.chance(0.5) ? arg : this.mutate(arg, d - 1);
        const h = this.helper("X, Y", "(<T>() => T extends X ? 1 : 2) extends (<T>() => T extends Y ? 1 : 2) ? true : false");
        return `${h}<${arg}, ${b}>`;
      }
    }
  }

  // well-known recursive idioms on random inputs
  idiom(d) {
    const r = this.r;
    const n = () => r.int(12);
    const strs = () => r.pick(STRS);
    const tup = () => `[${Array.from({ length: r.int(6) }, () => this.leaf()).join(", ")}]`;
    switch (r.int(12)) {
      case 0: {
        const h = this.name("RevT");
        this.helpers.push(`type ${h}<T extends unknown[], A extends unknown[] = []> = T extends [infer H, ...infer R] ? ${h}<R, [H, ...A]> : A;`);
        return `${h}<${tup()}>`;
      }
      case 1: {
        const h = this.name("Len");
        this.helpers.push(`type ${h}<S extends string, N extends 0[] = []> = S extends \`\${infer _}\${infer R}\` ? ${h}<R, [...N, 0]> : N["length"];`);
        return `${h}<${strs()}>`;
      }
      case 2: {
        const h = this.name("Split");
        const sep = r.pick(['","', '""', '"."', '" "', '"b"']);
        this.helpers.push(`type ${h}<S extends string, D extends string> = S extends \`\${infer H}\${D}\${infer T}\` ? [H, ...${h}<T, D>] : [S];`);
        return `${h}<${strs()}, ${sep}>`;
      }
      case 3: {
        const h = this.name("Tup");
        this.helpers.push(`type ${h}<N extends number, R extends 0[] = []> = R["length"] extends N ? R : ${h}<N, [...R, 0]>;`);
        return r.chance(0.5) ? `${h}<${n()}>["length"]` : `[...${h}<${n()}>, ...${h}<${n()}>]["length"]`;
      }
      case 4: {
        const h = this.name("Join");
        this.helpers.push(`type ${h}<T extends unknown[], U extends string> = T extends [infer F extends string | number, ...infer R] ? R["length"] extends 0 ? \`\${F}\` : \`\${F}\${U}\${${h}<R, U>}\` : "";`);
        return `${h}<${tup()}, ${r.pick(['","', '"-"', '""'])}>`;
      }
      case 5: {
        const h = this.name("Flat");
        this.helpers.push(`type ${h}<T> = T extends [] ? [] : T extends [infer F, ...infer R] ? [...${h}<F>, ...${h}<R>] : [T];`);
        return `${h}<[${tup()}, ${this.leaf()}, [${tup()}]]>`;
      }
      case 6: {
        const h = this.name("Rev");
        this.helpers.push(`type ${h}<S extends string> = S extends \`\${infer F}\${infer R}\` ? \`\${${h}<R>}\${F}\` : "";`);
        return `${h}<${strs()}>`;
      }
      case 7: {
        const h = this.name("Sub");
        const t = this.name("Tp");
        this.helpers.push(`type ${t}<N extends number, R extends 0[] = []> = R["length"] extends N ? R : ${t}<N, [...R, 0]>;`);
        this.helpers.push(`type ${h}<A extends number, B extends number> = ${t}<A> extends [...${t}<B>, ...infer R] ? R["length"] : never;`);
        return `${h}<${n()}, ${n()}>`;
      }
      case 8: {
        const h = this.name("Repl");
        this.helpers.push(`type ${h}<S extends string, F extends string, T extends string> = F extends "" ? S : S extends \`\${infer A}\${F}\${infer B}\` ? \`\${A}\${T}\${${h}<B, F, T>}\` : S;`);
        return `${h}<${strs()}, ${r.pick(['"a"', '"b"', '","', '""', '"l"'])}, ${r.pick(['"X"', '""', '"aa"'])}>`;
      }
      case 9: {
        const h = this.name("ToU");
        this.helpers.push(`type ${h}<T extends string> = T extends \`\${infer L}\${infer R}\` ? L | ${h}<R> : never;`);
        return `${h}<${strs()}>`;
      }
      case 10: {
        const h = this.name("Num");
        this.helpers.push(`type ${h}<S extends string> = S extends \`\${infer N extends number}\` ? [N] : S extends \`\${infer B extends bigint}\` ? [B, "big"] : "no";`);
        return `${h}<${r.pick(STRS.concat(['"0x10"', '"1e3"', '" 1"', '"01"', '"1_000"', '"-0"', '"5n"', '"Infinity"', '"NaN"']))}>`;
      }
      default: {
        const h = this.name("Zip");
        this.helpers.push(`type ${h}<T extends unknown[], U extends unknown[]> = T extends [infer TF, ...infer TR] ? U extends [infer UF, ...infer UR] ? [[TF, UF], ...${h}<TR, UR>] : [] : [];`);
        return `${h}<${tup()}, ${tup()}>`;
      }
    }
  }

  type(d) {
    const r = this.r;
    if (d <= 0) return this.leaf();
    switch (r.int(14)) {
      case 0: case 1: return this.leaf();
      case 2: return `${this.type(d - 1)} | ${this.type(d - 1)}`;
      case 3: return `${this.paren(this.type(d - 1))} & ${this.paren(this.type(d - 1))}`;
      case 4: return this.tuple(d);
      case 5: return r.chance(0.3) ? `readonly ${this.wrapArr(this.type(d - 1))}` : this.wrapArr(this.type(d - 1));
      case 6: return this.object(d);
      case 7: return this.template(d - 1);
      case 8: return this.func(d);
      case 9: case 10: return this.conditional(d);
      default: return this.generic(d);
    }
  }

  // invalid on purpose (one rule bent); tsgo decides whether it is an error
  invalid(d) {
    const r = this.r;
    switch (r.int(12)) {
      case 0: {
        const h = this.helper(`T extends ${r.pick(["string", "number", "unknown[]", "{ a: 1 }"])}`, "[T]");
        return `${h}<${this.type(d)}>`;
      }
      case 1: {
        const h = this.helper("A, B", "[A, B]");
        return r.chance(0.5) ? `${h}<${this.type(d)}>` : `${h}<${this.leaf()}, ${this.leaf()}, ${this.leaf()}>`;
      }
      case 2: return `${this.p}_Missing${r.int(3)}`;
      case 3: return `${this.object(d)}[${r.pick(KEYT)}]`;
      case 4: return `\`a\${${this.type(d)}}\``;
      case 5: return `${this.tuple(d)}[${r.pick(["0", "1", "3", "number", '"length"', '"x"'])}]`;
      case 6: {
        const n = this.name("Self");
        this.helpers.push(`type ${n} = ${r.pick([n, `[${n}]`, `${n} | 1`, `{ a: ${n} }`, `${n}[]`])};`);
        return n;
      }
      case 7: return `${r.pick(["Uppercase", "Capitalize"])}<${this.type(d)}>`;
      case 8: return `[${this.leaf()}?, ${this.leaf()}]`;
      case 9: {
        const h = this.helper("T", "T");
        return `${h}`;
      }
      case 10: return `(${this.type(d)} extends infer X extends ${this.leaf()} ? X : 0)`;
      default: return `ReturnType<${this.type(d)}>`;
    }
  }
}

// one program: its lines and its output aliases
export function program(seed, prefix, { invalid = false, outputs = 3, depth = 3 } = {}) {
  const r = rng(seed);
  const g = new Gen(r, prefix);
  const outs = [];
  for (let i = 0; i < outputs; i++) {
    const t = invalid && i === 0 ? g.invalid(depth) : g.type(depth);
    outs.push(`type ${prefix}_O${i} = ${t};`);
  }
  return { lines: [...g.helpers, ...outs] };
}
