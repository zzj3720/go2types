// Heavier type-challenges.
type Permutation<T, K = T> = [T] extends [never] ? [] : K extends K ? [K, ...Permutation<Exclude<T, K>>] : never;
type Subsequence<T extends any[]> = T extends [infer F, ...infer R] ? Subsequence<R> | [F, ...Subsequence<R>] : [];
type Combination<T extends string[], All = T[number], Item = All> = Item extends string ? Item | `${Item} ${Combination<[], Exclude<All, Item>>}` : never;
type Chunk<T extends any[], N extends number, C extends any[] = [], R extends any[] = []> =
  T extends [infer F, ...infer Rest] ? C["length"] extends N ? Chunk<Rest, N, [F], [...R, C]> : Chunk<Rest, N, [...C, F], R> : C extends [] ? R : [...R, C];
type Flatten<T> = T extends [infer F, ...infer R] ? F extends any[] ? [...Flatten<F>, ...Flatten<R>] : [F, ...Flatten<R>] : [];
type Zip<A extends any[], B extends any[]> = A extends [infer X, ...infer AR] ? B extends [infer Y, ...infer BR] ? [[X, Y], ...Zip<AR, BR>] : [] : [];
type UnionToIntersection<U> = (U extends any ? (x: U) => void : never) extends (x: infer I) => void ? I : never;
type LastOf<U> = UnionToIntersection<U extends any ? () => U : never> extends () => infer R ? R : never;
type UnionToTuple<U, L = LastOf<U>> = [U] extends [never] ? [] : [...UnionToTuple<Exclude<U, L>>, L];
// MinusOne on decimal strings
type MinusDigit = { "1": "0"; "2": "1"; "3": "2"; "4": "3"; "5": "4"; "6": "5"; "7": "6"; "8": "7"; "9": "8" };
type RevS<S extends string, R extends string = ""> = S extends `${infer C}${infer T}` ? RevS<T, `${C}${R}`> : R;
type MinusRev<S extends string> = S extends `0${infer T}` ? `9${MinusRev<T>}` : S extends `${infer D extends keyof MinusDigit}${infer T}` ? `${MinusDigit[D]}${T}` : never;
type TrimZero<S extends string> = S extends `0${infer T}` ? T extends "" ? "0" : TrimZero<T> : S;
type MinusOne<N extends number> = TrimZero<RevS<MinusRev<RevS<`${N}`>>>> extends `${infer R extends number}` ? R : never;
type CountDown<N extends number, R extends number[] = []> = N extends 0 ? R : CountDown<MinusOne<N>, [...R, N]>;
type DeepKeys<T, P extends string = ""> = T extends object ? { [K in keyof T & string]: `${P}${K}` | DeepKeys<T[K], `${P}${K}.`> }[keyof T & string] : never;
type Tree = { a: { b: { c: 1; d: 2 }; e: { f: { g: 3; h: 4 } } }; i: { j: 5; k: { l: 6; m: { n: 7; o: 8 } } }; p: 9 };
type ParseQuery<S extends string, R = {}> = S extends `${infer K}=${infer V}&${infer T}` ? ParseQuery<T, R & { [P in K]: V }> : S extends `${infer K}=${infer V}` ? { [P in keyof (R & { [Q in K]: V })]: (R & { [Q in K]: V })[P] } : R;
type Repeat<S extends string, N extends number, C extends 0[] = [], R extends string = ""> = C["length"] extends N ? R : Repeat<S, N, [...C, 0], `${R}${S}`>;
type CountUnique<T extends any[], Seen = never, N extends 0[] = []> = T extends [infer F, ...infer R] ? [F] extends [Seen] ? CountUnique<R, Seen, N> : CountUnique<R, Seen | F, [...N, 0]> : N["length"];
type Rng<N extends number, R extends number[] = []> = R["length"] extends N ? R : Rng<N, [...R, R["length"]]>;
// scaled up (tstc only)
type X1 = Permutation<"a" | "b" | "c" | "d" | "e" | "f" | "g">["length"];
type X2 = Subsequence<[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]>["length"];
type X4 = Chunk<Rng<1000>, 7>["length"];
type X6 = Zip<Rng<500>, Rng<500>>["length"];
type X7 = UnionToTuple<"a" | "b" | "c" | "d" | "e" | "f" | "g" | "h" | "i" | "j" | "k" | "l" | "m" | "n" | "o" | "p" | "q" | "r" | "s" | "t">["length"];
type X9 = CountDown<3000>["length"];
type X12 = Repeat<"ab", 5000>;
type X13 = CountUnique<[...Rng<300>, ...Rng<300>, ...Rng<100>]>;
