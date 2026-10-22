// Tuples of one repeated element (uniform buffers), tuple and template
// fast paths, memoized tree recursion, inference from contravariant
// positions and from overloads.
type Tup<N extends number, R extends 0[] = []> = R["length"] extends N ? R : Tup<N, [...R, 0]>;
type T5 = Tup<5>;
type T40 = Tup<40>;
type Cat1 = [...Tup<3>, ...Tup<4>];
type Cat2 = [...Tup<3>, 1, ...Tup<2>];
type Cat3 = [0, ...Tup<6>, 0];
type Cat4 = [...Tup<3>, ...[1, 1], ...Tup<2>];
type Cat5 = [...[], ...Tup<3>, ...[]];
type Cat6 = [...Tup<2>, "x"];
type Mixed = [...Cat6, ...Tup<3>];
type AfterMixed = [...Tup<4>, 0]["length"];
type Ro = readonly [...Tup<3>];
type RoCat = [...(readonly [0, 0]), ...Tup<2>];
type Named = [...[a: 0, b: 0], ...Tup<2>];
type Opt = [...[0?], ...Tup<2>];
type Sub<A extends number, B extends number> = Tup<A> extends [...Tup<B>, ...infer R] ? R["length"] : never;
type S1 = Sub<30, 12>;
type S2 = Sub<3, 5>;
type Head<T> = T extends [infer H, ...infer R] ? [H, R] : never;
type H1 = Head<Tup<4>>;
type H2 = Head<[]>;
type Last<T> = T extends [...infer I, infer L] ? [I["length"], L] : never;
type L1 = Last<[...Tup<5>, 1]>;
type Mid<T> = T extends [infer A, ...infer M, infer B] ? M : never;
type M1 = Mid<Tup<6>>;
type EqTup = Tup<7> extends [...Tup<3>, ...Tup<4>] ? true : false;
type NeTup = Tup<7> extends Tup<6> ? true : false;
type NeEl = Tup<3> extends [0, 0, 1] ? true : false;
type Wider = Tup<3> extends number[] ? true : false;
type ToOnes = Tup<3> extends 1[] ? true : false;
type StrUni<N extends number, R extends string[] = []> = R["length"] extends N ? R : StrUni<N, [...R, "a"]>;
type SU = [...StrUni<3>, ...StrUni<2>];
type SU2 = [...StrUni<2>, "b"];
type Spread2<A extends 0[]> = A extends [0, 0, ...infer R extends 0[]] ? R["length"] : -1;
type Sp1 = Spread2<Tup<9>>;
type Sp2 = Spread2<Tup<1>>;
type Pre<T extends unknown[]> = T extends [...[0, 0], ...infer R] ? R : "no";
type Pr1 = Pre<[0, 0, 1, 2]>;
type Pr2 = Pre<[0, 1, 2]>;
// tree recursion (memoized)
type FibT<N extends 0[]> = N extends [0, 0, ...infer R extends 0[]] ? [...FibT<[0, ...R]>, ...FibT<R>] : N;
type Fib16 = FibT<Tup<16>>["length"];
type Paths<N extends 0[]> = N extends [0, ...infer R extends 0[]] ? `L${Paths<R>}` | `R${Paths<R>}` : "";
type P3 = Paths<Tup<3>>;
// templates
type Chars<S extends string, R extends string[] = []> = S extends `${infer C}${infer T}` ? Chars<T, [...R, C]> : R;
type C1 = Chars<"hello">;
type Num<S extends string> = S extends `${infer N extends number}${infer R}` ? [N, R] : never;
type N1 = Num<"7up">;
type Two<S extends string> = S extends `${infer A}-${infer B}` ? [A, B] : never;
type W1 = Two<"ab-cd-ef">;
// repeated checks of the same expression
type Kind<T> = Tup<3> extends T ? "a" : [...Tup<3>, 0] extends T ? "b" : Tup<3> extends [0, ...infer R] ? R["length"] : "c";
type K1 = Kind<0[]>;
type K2 = Kind<[0, 0, 0, 0]>;
type K3 = Kind<string>;
// contravariant positions infer an intersection
type UnionToIntersection<U> = (U extends any ? (x: U) => void : never) extends (x: infer I) => void ? I : never;
type I1 = UnionToIntersection<{ a: 1 } | { b: 2 }>;
type I2 = UnionToIntersection<"a" | "b">;
type I3 = UnionToIntersection<(() => "a") | (() => "b")>;
type Both<T> = T extends { f: (x: infer X) => void; g: infer X } ? X : never;
type B1 = Both<{ f: (x: string) => void; g: "s" }>;
type B2 = Both<{ f: (x: { a: 1 }) => void; g: never }>;
type Ctr = ((x: 1) => void) | ((x: 2) => void) extends (x: infer I) => void ? I : never;
// the last signature of an intersection or overloads
type LastOf<U> = UnionToIntersection<U extends any ? () => U : never> extends () => infer R ? R : never;
type LO = LastOf<"a" | "b" | "c">;
type UnionToTuple<U, L = LastOf<U>> = [U] extends [never] ? [] : [...UnionToTuple<Exclude<U, L>>, L];
type UT = UnionToTuple<"a" | "b" | "c" | "d">["length"];
type Ov = { (): 1; (): 2 } extends () => infer R ? R : never;
type OvP = { (x: string): 1; (x: number): 2 } extends (x: infer P) => infer R ? [P, R] : never;
// a bigint bound by infer with a constraint (an integer binds at once), and
// go2types' table lookups keyed so
type BigKey<X> = X extends infer N extends bigint ? `${N}` : "no";
type BK1 = BigKey<5n>;
type BK2 = BigKey<-3n>;
type BK3 = BigKey<12345678901234567890123n>;
type BK4 = BigKey<"5">;
type BK5 = BigKey<1n | 2n>;
type BK6 = BigKey<never>;
type BK7 = BigKey<5>;
type BK8 = BigKey<bigint>;
type BK9 = BigKey<[1n]>;
type Tab<X> = X extends infer N extends bigint
  ? ({ "1": "one"; "2": "two"; "3": "three"; "4": "four"; "4611686018427387905": "big" } extends infer Tbl$
    ? `${N}` extends infer Key$ extends keyof Tbl$ ? Tbl$[Key$] : "default" : never)
  : "no key";
type Tb1 = Tab<1n>;
type Tb2 = Tab<4n>;
type Tb3 = Tab<9n>;
type Tb4 = Tab<"1">;
type Tb5 = Tab<1n | 3n>;
type Tb6 = Tab<4611686018427387905n>;
type Tb7 = Tab<null>;
type Tbs<L> = L extends [infer X, ...infer R] ? [Tab<X>, ...Tbs<R>] : [];
type Tb8 = Tbs<[2n, 3n, 7n, -1n, 4611686018427387905n, "2"]>;
// (simple values only: the inline conditional)
type IsBig<X> = X extends infer N extends bigint ? [N] : "no";
type IB1 = IsBig<5n>;
type IB2 = IsBig<12345678901234567890123n>;
type IB3 = IsBig<-4611686018427387905n>;
type IB4 = IsBig<"5">;
type IB5 = IsBig<5>;
type IB6 = IsBig<bigint>;
type IB7 = IsBig<never>;
type IB8 = IsBig<5n & { b: 1 }>;
type IB9 = IsBig<null>;
type IBs<L> = L extends [infer X, ...infer R] ? [IsBig<X>, ...IBs<R>] : [];
type IB10 = IBs<[1n, "x", 9223372036854775807n, [2n], 3n]>;
