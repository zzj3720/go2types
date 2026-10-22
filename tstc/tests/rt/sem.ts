// Classes of semantics where tstc must compute what the checker computes
// (found by scripts/conform.mjs).

// template literal types keep `any` placeholders; string mappings of
// non-literals stay mappings
type T1 = `a${any}b`;
type T2 = `${any}` extends string ? 1 : 0;
type T3 = Uppercase<string>;
type T4 = Capitalize<`a${string}`>;
type T5 = Capitalize<`${string}a`>;
type T6 = `x${Capitalize<string>}`;
type T7 = Lowercase<Uppercase<string>>;
type T8 = "ABC" extends Uppercase<string> ? 1 : 0;
type T9 = "AbC" extends Uppercase<string> ? 1 : 0;
type T10 = Uppercase<string> | "ABC";
type T11 = Uppercase<string> | "abc";
type T12 = Uppercase<string> & "abc";
type T13 = `${string}${string}`;
type T14 = `a${string}${string}`;
type Remap<T> = { [K in keyof T as K extends string ? `get${Capitalize<K>}` : never]: T[K] };
type T15 = Remap<{ [k: string]: 1; a: 1 }>;
type T16 = " 1" extends `${number}` ? 1 : 0;
type T17 = "0x1F" extends `${number}` ? 1 : 0;
type T18 = "1_0" extends `${number}` ? 1 : 0;
type T19 = "01" extends `${bigint}` ? 1 : 0;
type T20 = "1e3" extends `${infer N extends number}` ? [N] : 0;
type T21 = Uncapitalize<`${bigint}`>;

// keyof of primitives, arrays and tuples: their interfaces' members
type K1 = keyof 42;
type K2 = keyof boolean;
type K3 = keyof 10n;
type K4 = keyof string;
type K5 = keyof unknown[];
type K6 = keyof readonly [1, 2];
type K7 = keyof (() => void);
type K8 = keyof object;
type K9 = keyof ({ a: 1 } | { a: 2; b: 3 });
type K10 = [0, number]["toString"];
type K11 = keyof symbol;

// intersections as the checker reduces them
type I1 = false & [void];
type I2 = [never, never] & 10n;
type I3 = Pick<{ c: 1 }, never> & "a";
type I4 = string & {};
type I5 = NonNullable<string>;
type I6 = { a: 1 } & { a: 2 } extends never ? 1 : 0;
type I7 = ("a" | "b") & ("b" | "c");
type I8 = Omit<{}, 1> & 1e21;
type I9 = (1 | undefined) & (1 | 2 | undefined);

// inference: no candidates give unknown (or the constraint)
type N1 = never extends [infer X, ...infer Y] ? [X, Y] : 0;
type N2 = any extends { a: infer X } ? [X] : 0;
type N3 = any extends [infer X extends 0n, ...infer Y extends unknown[]] ? [X, Y] : 1n;
type N4 = (() => 3) extends (a: infer X) => infer Y ? [X, Y] : 0;
type N5 = ((a?: 1) => 2) extends (a: infer X) => infer Y ? [X, Y] : 0;
type N6 = ((a: 1, b: 2) => 3) extends (a: infer X) => infer Y ? [X, Y] : 0;
type N7 = ["a", 1] | [2] extends [infer X, ...infer R] ? [X, R] : 0;
type N8 = [string, "x"] extends [infer A, infer A] ? [A] : 0;
type N9 = { a: 1 } extends { a: infer X; b?: infer Y } ? [X, Y] : 0;
type N10 = "abc" extends { length: infer L } ? [L] : 0;
type N11 = string extends `${infer X}` ? [X] : 0;
type N12 = `a${number}b` extends `a${infer X}b` ? [X] : 0;
type N13 = Parameters<(a: "true") => 2n>;
type N14 = Parameters<(a: void) => 1>;
type N15 = ReturnType<() => 1e21>;

// optional properties, elements and parameters have undefined
type O1 = { a?: 1 }["a"];
type O2 = [1, 2?]["length"];
type O3 = Partial<{ [k: string]: 1n }>;
type O4 = Required<{ a?: 1 | undefined }>;
type O6 = Required<[1?, 2?]>;
type O7 = Partial<any>;
type O8 = Required<1n>;
type O9 = Readonly<`a${string}`>;
type O10 = Omit<{ [k: string]: any }, 1>;

// relations
type R1 = false[] extends readonly [] ? 1 : 0;
type R2 = 1 extends { a?: 1 } ? 1 : 0;
type R3 = "abc" extends { length?: number } ? 1 : 0;
type R4 = null extends {} ? 1 : 0;
type R5 = [1, 2] extends { length: 2 } ? 1 : 0;
type R6 = ((a: string) => void) extends (a: "x", b: 1) => void ? 1 : 0;
type R7 = (() => void) extends (a?: 1) => unknown ? 1 : 0;
type R8 = [1] extends [1, 2?] ? 1 : 0;
type R9 = { a: 1 } extends { [k: string]: number } ? 1 : 0;
type R10 = 1[] extends [...1[]] ? 1 : 0;

// any as the check type: both branches, the true one's check type
// constrained by the extends type
type S1 = Extract<any, never>;
type S2 = Exclude<any, never>;
type S3 = Extract<any, string>;
type SW<T, U> = T extends U ? [T] : 2;
type S4 = SW<any, never>;
type S5 = SW<any, 1 & 2>;

// objects against object patterns
type B1 = { a: 1 | { x: 1 } | { x: 1; y: 2 }; b: 2 } extends { a: infer A; b: infer B } ? [A, B] : 0;
type B2 = { a?: 1; b: 2 } extends { a: infer A; b: infer B } ? [A, B] : 0;
type B3 = { b: 2 } extends { a: infer A; b: infer B } ? [A, B] : 0;

// an object whose properties its index signature does not admit (only a
// mapped type makes one)
type KeysOf<T> = { +readonly [K in keyof T]: K };
type P1 = KeysOf<{ a?: 1; [k: string]: unknown }>;

// members of an intersection's apparent type see the intersection as this;
// symbol-named members
type L1 = Required<1[] & 7>;
type L2 = (1[] & 7)["fill"];
type L3 = keyof Required<1[] & 7>;

// substitution types: in the true branch of a conditional whose check type
// is known, a type that is the check type is constrained by the extends type
type U1 = 0 extends number ? 0 : 1;
type U2 = U1 & 5;
type UG<T> = 0 extends number ? 0 : 1;
type U3 = UG<1> & 5;
type UW<T> = [T, 0 extends number ? 0 : 1];
type U4 = UW<1>[1] & 5;
type U5 = `x${U1}`;
type U6 = never extends (infer X)[] ? `a${never}` : 0;
type U7 = U1 | 0;
type U8 = [1 extends 1 | 2 ? 1 : 3];
type U9 = ({} extends object ? [{}, "é"] : 0) | 7;
type U10 = 1n extends {} ? { b: 1n & "12" } : 0;
type U11 = -5n & (1.5 & "" extends { a: 1.5 & "" } ? "ab" & "foo.bar" : 0);
type U12s = [never extends 0 ? `a${never}` : 1, never extends unknown ? `a${never}` : 1];

// a union and an intersection where written: unknown and any absorb type
// parameters, never everything
type UA<T> = { readonly [K in keyof T]?: T[K] | unknown };
type U12 = UA<[any, 1e21]>;
type UI<T> = T & any;
type U13 = UI<never>;

// discriminated unions as targets
type D1 = { length: undefined } extends [string] | ({ length: undefined } & void) ? 1 : 0;
type D2 = { a: 1 | 2 } extends { a: 1; b?: 0 } | { a: 2 } ? 1 : 0;

// inference from an intersection's index signature
type X1 = [a?: string] & 7 extends (infer X)[] ? [X] : 0;

// interfaces: one object type of their bases' members and their own, no
// anonymous types
interface IBase { a: string; b: 1 }
interface IDer extends IBase { a: "x"; c: 2 }
interface IEmpty {}
type F1 = IDer;
type F2 = keyof IDer;
type F3 = IEmpty & string;
type F4 = IDer extends { [k: string]: unknown } ? 1 : 0;
type F5 = { a: 1 } extends { [k: string]: unknown } ? 1 : 0;
type F6 = IDer["a"];
type U15 = (a?: (1e21 & 1n extends {} ? "b" & "true" : "1.5")) => 0;
type X2 = { -readonly [K in keyof [("x y")?, 10n?]]?: [("x y")?, 10n?][K] } & (readonly [...10n[], 2]) extends (infer X)[] ? [X] : "";

// aliases that contain themselves (tsgo defers array and tuple elements)
type KS1 = KS1[];
type KS2 = [KS2];
type KS3 = { a: KS3 };
type KS4 = () => KS4;
type KS5 = [KS5] | 1;
type KS6 = KS1 extends KS1[] ? 1 : 0;
type KS7 = KS2[0] extends KS2 ? true : false;
type KS8 = KS1 extends (infer U)[] ? [U] : 0;
type KS9 = KS10[];
type KS10 = [KS9, 1];
type KS11 = KS10[0] extends KS9 ? KS3["a"]["a"] : 0;
type KS12 = readonly [x?: KS12];

// infer among an alias's type arguments (the alias instantiated with type
// parameters for them)
type IAB<T> = { v: T };
type IAP<A, B> = [A, B];
type IAH<X, Y> = (<T>() => T extends X ? 1 : 2) extends (<T>() => T extends Y ? 1 : 2) ? true : false;
type IA1 = { v: 1 } extends IAB<infer U> ? U : 0;
type IA2 = [1, 2] extends IAP<infer A, infer B> ? [B, A] : 0;
type IA3 = "ab" extends Exclude<1 | `${infer X}b`, 1> ? X : 0;
type IA4 = [] & 10n extends IAH<"cba", [...infer X, infer Y]> ? [X, Y] : 0;
type IA5 = 3 extends Exclude<null | 0n | 123456789, `${infer X}${infer Y}`> ? [X, Y] : 0;
type IA6 = [{ v: "x" }] extends [IAB<infer U extends string>] ? U : 0;

// one object type per declaration and the type arguments it may reference
// (an alias's whole body: all of the alias's); every empty object type
// literal is one type
type IDB<T> = { v: T };
type IDC<T> = { a: 1 };
type IDD<T> = [{ a: 1 }, T];
type IDF<T> = () => T;
type ID1 = Pick<{}, never> | Pick<{}, never>;
type ID2 = IDB<1> | IDB<1>;
type ID3 = IDB<1> | IDB<2>;
type ID4 = IDC<1> | IDC<2>;
type ID5 = IDD<1>[0] | IDD<2>[0];
type ID6 = {} | {};
type ID7 = { a: 1 } | { a: 1 };
type ID8 = IDF<1> | IDF<1>;
type ID9 = Partial<{ a: 1 }> | Partial<{ a: 1 }>;

// substitution types as TypeScript's Equal sees them: resolved where an
// instantiated signature has them (tsgo instantiates the source signature),
// kept in a union or intersection written as a parameterless alias's type
type SBEq<X, Y> = (<T>() => T extends X ? 1 : 2) extends (<T>() => T extends Y ? 1 : 2) ? 1 : 0;
type SBE2<SBA, B> = `${SBEq<SBA, B>}${SBEq<B, SBA>}`;
type SBP1 = (never extends 1 ? never : 0);
type SBP10 = (0 extends number ? 0 : 1);
type SBP4 = (any extends [any] ? SBP1 : null);
type SBP6 = SBP1 | null;
type SBP7 = [SBP1];
type SBP11 = SBP10 | 0;
type SBP12 = SBP10 & 5;
type SBP15 = (any extends [any] ? SBP10 : null);
type SBP16 = (0 extends number ? (any extends [any] ? 0 : null) : 1);
type SBSV = (never extends 123456789 ? never : never) | null;
type SBSW = (0 extends number ? 0 : never) | 0;
type SBS8 = (true & false extends true & false | 123456789 ? (any extends [any] ? never : null) : undefined);
type SBU7 = SBP10 | 0;
type SBU8 = [1 extends 1 | 2 ? 1 : 3];
type SBR01 = SBE2<SBP1, never>;
type SBR02 = SBE2<(never extends 1 ? [never] : 0), [never]>;
type SBR03 = SBE2<(never extends 1 ? never | null : 0), null>;
type SBR04 = SBE2<SBP4, null>;
type SBR05 = SBE2<(never extends 1 ? (any extends [any] ? never : null) : 0), null>;
type SBR06 = SBE2<SBP6, null>;
type SBR09 = SBE2<(undefined extends undefined | 1 ? undefined : 0), undefined>;
type SBR10 = SBE2<SBP10, 0>;
type SBR11 = SBE2<SBP11, 0>;
type SBR12 = SBE2<SBP12, never>;
type SBR13 = SBE2<(0 extends number ? [0] : 1), [0]>;
type SBR14 = SBE2<(0 extends number ? 0 | 1 : 1), 0 | 1>;
type SBR15 = SBE2<SBP15, 0 | null>;
type SBR16 = SBE2<SBP16, 0 | null>;
type SBR20 = SBE2<(0 extends number ? SBP10 | 3 : 1), 0 | 3>;
type SBR21 = SBE2<(0 extends number ? 0 & 5 : 1), never>;
type SBR22 = SBE2<(never extends 1 ? `a${never}` : 1), never>;
type SBR23 = SBE2<(0 extends number ? { a: 0 } : 1), { a: 0 }>;
type SBR24 = SBE2<(0 extends number ? 0[] : 1), 0[]>;
type SBR26 = SBE2<(any extends 1 ? SBP1 | 0 : null), 0 | null>;
type SBR27 = SBE2<SBS8, SBSV>;
type SBR28 = SBE2<SBU7, SBSW>;
type SBR29 = SBE2<SBU7, (0 extends number ? 0 : never) | 0>;
type SBR31 = SBE2<SBP12, (0 extends number ? 0 : never) & 5>;
type SBR32 = SBE2<SBS8, (never extends 123456789 ? never : never) | null>;
type SBA = SBS8 | 1;
type SBR1 = SBEq<SBA, null | 1>;
type SBR2 = SBEq<SBS8, null>;
type SBR3 = [SBS8] extends [null] ? ([null] extends [SBS8] ? 1 : 2) : 3;
type SBR4 = SBEq<[SBS8], [null]>;
type SBR5 = SBEq<SBS8 | 2, null | 2>;
type SBR6 = SBEq<{ a: SBS8 }, { a: null }>;
type SBS12 = [null?, (undefined extends undefined | "1.5" ? undefined : "")?][1];
type SBR7 = SBEq<SBS12, undefined>;
type SBR8 = SBEq<SBS12 | 1, undefined | 1>;
type SBR9 = SBEq<[SBS12], [undefined]>;
