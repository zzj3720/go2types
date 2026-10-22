type M1 = string extends `${string}` ? 1 : 0;
type M2 = "abc" extends `a${string}` ? 1 : 0;
type M3 = "abc" extends `${string}c` ? 1 : 0;
type M4 = "1.5" extends `${number}` ? 1 : 0;
type M5 = "x1" extends `${number}` ? 1 : 0;
type M6 = `${number}px` | "auto";
type M7 = "12px" extends M6 ? 1 : 0;
type M8 = [1, 2?] extends [1] ? 1 : 0;
type M9 = [1] extends [1, 2?] ? 1 : 0;
type M10 = [string, ...number[]];
type M11 = [string, 1, 2] extends M10 ? 1 : 0;
type M12 = M10 extends [infer H, ...infer R] ? [H, R] : 0;
type M13 = readonly [1, 2] extends [1, 2] ? 1 : 0;
type M14 = [1, 2] extends readonly [1, 2] ? 1 : 0;
type M15 = { a: 1 } & { b: 2 };
type M16 = M15 extends { a: 1; b: 2 } ? 1 : 0;
type M17 = never extends string ? 1 : 0;
type M18 = any extends string ? 1 : 0;
type M19 = unknown extends string ? 1 : 0;
type Dist<T> = T extends string ? "s" : "o";
type M20 = Dist<string | number>;
type M21 = Dist<never>;
type M22 = Dist<any>;
type M23 = null extends undefined ? 1 : 0;
type M24 = undefined extends void ? 1 : 0;
type M25 = (() => void) extends Function ? 1 : 0;
type M26 = ((a: string) => void) extends ((a: "x") => void) ? 1 : 0;
type M27 = ((a: "x") => void) extends ((a: string) => void) ? 1 : 0;
type M28 = keyof { a: 1; 0: 2 };
type M29 = { [K in "a" | "b"]?: K };
type M30 = Required<M29>;
type M31 = { a?: 1 }["a"];
type M32 = [1, 2, 3]["length"];
type M33 = string[]["length"];
type M34 = "a" | "b" extends "a" ? 1 : 0;
type M35 = ["a" | "b"] extends ["a"] ? 1 : 0;
type M36 = `${1 | 2}-${"a" | "b"}`;
type M37 = Lowercase<"ABC" | "DeF">;
type M38 = Extract<"a" | 1 | true, string | boolean>;
type M39 = NonNullable<string | null | undefined>;
type M40 = Record<"a" | "b", number>;
type M41 = Pick<{ a: 1; b: 2; c: 3 }, "a" | "b">;
type M42 = Omit<{ a: 1; b: 2; c: 3 }, "a">;
type M43 = bigint extends number ? 1 : 0;
type M44 = 10n extends bigint ? 1 : 0;
type M45 = `${10n}`;
type M46 = `${true}${null}${undefined}`;
type M47 = "a" extends "a" | "b" ? true : false;
type M48 = {} extends { a?: 1 } ? 1 : 0;
type M49 = { a: 1 } extends {} ? 1 : 0;
type M50 = string extends {} ? 1 : 0;
type M51 = null extends {} ? 1 : 0;
type M52 = { [k: string]: number } extends { a: number } ? 1 : 0;
type M53 = { a: 1; b: 2 } extends { [k: string]: number } ? 1 : 0;
type M54 = [] extends (infer U)[] ? [U] : 0;
type M55 = "" extends `${infer A}${infer B}` ? [A, B] : 0;
type M56 = "a" extends `${infer A}${infer B}` ? [A, B] : 0;
type M57 = "abc" extends `${infer A}${infer B}${infer C}` ? [A, B, C] : 0;
type M58 = "a.b.c" extends `${infer A}.${infer B}` ? [A, B] : 0;
type M59 = "1e3" extends `${infer N extends number}` ? N : 0;
type M60 = "007" extends `${infer N extends number}` ? N : 0;
type M61 = "true" extends `${infer B extends boolean}` ? B : 0;
type M62 = { a: string; b: number }[keyof { a: string; b: number }];
type M63 = [a: 1, b?: 2, ...c: 3[]];
type M64 = Parameters<(a: 1, b?: 2, ...c: 3[]) => void>;
type M65 = ReturnType<<T>() => T>;
type M66 = [...[1, 2], ...3[]];
type M67 = [...3[], 1];
type Homo<T> = { [K in keyof T]: [T[K]] };
type M69 = Homo<[1, 2]>;
type M70 = Homo<string[]>;
type M71 = Homo<{ a?: 1 }>;
type M72 = Homo<string>;
type M73 = 1 | 2 extends 1 ? 1 : 0;
type M74 = (string | number)[] extends string[] ? 1 : 0;
type M75 = "a" & string;
type M76 = "a" & "b";
type M77 = (1 | 2) & (2 | 3);
type M78 = object extends {} ? 1 : 0;
type M79 = [1, 2] extends object ? 1 : 0;
type M80 = "x" extends object ? 1 : 0;

// a constrained infer directly in an extends clause
type InferC1 = "ab" extends infer S extends string ? [S] : 0;
type InferC2 = 5 extends infer N extends string ? [N] : 0;
type InferC3 = ["x"] extends [infer S extends string] ? S : 0;

// bigint inference from strings
type BigInf1 = "-5" extends `${infer N extends bigint}` ? [N] : 0;
type BigInf2 = "-0" extends `${infer N extends bigint}` ? [N] : 0;
type BigInf3 = "007" extends `${infer N extends bigint}` ? [N] : 0;
type BigInf4 = ("12" extends `${infer N extends bigint}` ? N : 0) extends 12n ? true : false;

// keyof distinguishes numeric and quoted numeric-looking names
type KeyNum1 = keyof { "3": 1 };
type KeyNum2 = keyof { 3: 1 };
type KeyNum3 = "3" & keyof { "3": 1; "4": 2 };
type KeyNum4 = keyof { [K in 1 | 2]: K };

// spreads of known tuples in tuple patterns
type SpreadPat<N extends unknown[], All extends unknown[]> = All extends [...N, ...infer R] ? R : "no";
type SpreadPat0 = SpreadPat<[], [0, 0, 0]>;
type SpreadPat1 = SpreadPat<[0], [0, 0, 0]>;
type SpreadPat2 = SpreadPat<[0, 0, 0], [0, 0, 0]>;
type SpreadPat3 = SpreadPat<[1], [0, 0, 0]>;
type SpreadPat4 = [1, 2, 3] extends [...infer A, ...[3]] ? A : "no";

// a bigint literal intersected with bigint
type BigInter1 = `${1n & bigint}`;
type BigInter2 = 5n & bigint;
type BigInter3 = 5n & string;

// how many characters string placeholders need
type StrPh1 = "ab" extends `${string}${string}${string}` ? 1 : 0;
type StrPh2 = "a" extends `${string}${string}${string}` ? 1 : 0;
type StrPh3 = "" extends `${string}${string}` ? 1 : 0;
type StrPh4 = "abc" extends `${string}${string}${string}${infer R}` ? R : 0;

// bigint literals in other radixes
type BigHex1 = 0x80n;
type BigHex2 = 0xffffffffffffffffn;
type BigHex3 = [0b101n, 0o17n];
type BigHex4 = 128n extends 0x80n ? true : false;
