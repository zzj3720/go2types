// A JSON parser: string literal in, object type out.
type WS = " " | "\n" | "\t" | "\r";
type Skip<S extends string> = S extends `${WS}${infer R}` ? Skip<R> : S;
type NumChar = "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" | "-" | "." | "e" | "E" | "+";
type TakeNum<S extends string, N extends string = ""> = S extends `${infer C extends NumChar}${infer R}` ? TakeNum<R, `${N}${C}`> : [N, S];
type Esc = { n: "\n"; t: "\t"; r: "\r"; b: "\b"; f: "\f"; '"': '"'; "\\": "\\"; "/": "/" };
type TakeStr<S extends string, R extends string = ""> =
  S extends `"${infer T}` ? [R, T]
  : S extends `\\${infer E extends keyof Esc}${infer T}` ? TakeStr<T, `${R}${Esc[E]}`>
  : S extends `${infer C}${infer T}` ? TakeStr<T, `${R}${C}`> : never;
// [value, rest]
type Value<S extends string> =
  Skip<S> extends `{${infer R}` ? Members<Skip<R>, {}>
  : Skip<S> extends `[${infer R}` ? Elements<Skip<R>, []>
  : Skip<S> extends `"${infer R}` ? TakeStr<R>
  : Skip<S> extends `true${infer R}` ? [true, R]
  : Skip<S> extends `false${infer R}` ? [false, R]
  : Skip<S> extends `null${infer R}` ? [null, R]
  : TakeNum<Skip<S>> extends [`${infer N extends number}`, infer R] ? [N, R] : never;
type Elements<S extends string, A extends unknown[]> =
  S extends `]${infer R}` ? [A, R]
  : Value<S> extends [infer V, infer R extends string]
    ? Skip<R> extends `,${infer R2}` ? Elements<Skip<R2>, [...A, V]> : Skip<R> extends `]${infer R2}` ? [[...A, V], R2] : never
    : never;
type Merge<O> = { [K in keyof O]: O[K] };
type Members<S extends string, O> =
  S extends `}${infer R}` ? [Merge<O>, R]
  : S extends `"${infer K}` ? TakeStr<K> extends [infer Key extends string, infer R extends string]
    ? Skip<R> extends `:${infer R2}` ? Value<R2> extends [infer V, infer R3 extends string]
      ? Skip<R3> extends `,${infer R4}` ? Members<Skip<R4>, O & { [P in Key]: V }> : Skip<R3> extends `}${infer R4}` ? [Merge<O & { [P in Key]: V }>, R4] : never
      : never : never : never
  : never;
type Parse<S extends string> = Value<S> extends [infer V, infer R extends string] ? Skip<R> extends "" ? V : never : never;

type Doc = `{
  "name": "tstc",
  "version": "0.1.0",
  "description": "Compiles type-level TypeScript programs to native executables",
  "private": true,
  "keywords": ["typescript", "types", "compiler", "llvm", "native"],
  "scripts": { "build": "moon build --target native", "test": "sh scripts/ci.sh", "diff": "sh scripts/ci.sh diff" },
  "config": { "jobs": 3, "opt": "f", "split": 200000, "gc": { "growth": 2, "block": 1048576 } },
  "matrix": [[1, 2, 3], [4, 5, 6], [7, 8, 9]],
  "people": [
    { "id": 1, "name": "Ada", "langs": ["en", "fr"], "admin": true, "score": 9.5 },
    { "id": 2, "name": "Brian", "langs": ["en"], "admin": false, "score": 7.25 },
    { "id": 3, "name": "Chen", "langs": ["zh", "en"], "admin": false, "score": -3 },
    { "id": 4, "name": "Dana", "langs": [], "admin": null, "score": 1e3 }
  ],
  "escaped": "line\\nbreak and \\"quotes\\"",
  "nested": { "a": { "b": { "c": { "d": { "e": [true, false, null] } } } } }
}`;
type J1 = Parse<Doc>;
type J2 = Parse<`[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40]`>;
type J3 = Parse<Doc>["people"][2]["langs"];
