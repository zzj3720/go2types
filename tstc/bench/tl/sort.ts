// Sorting number tuples.
type Tup<N extends number, R extends 0[] = []> = R["length"] extends N ? R : Tup<N, [...R, 0]>;
type Lt<A extends number, B extends number> = Tup<B> extends [...Tup<A>, 0, ...0[]] ? true : false;
// digit-wise comparison of decimal strings (no tuples)
type CmpDigit<A extends string, B extends string> = A extends B ? 0 : "0123456789" extends `${string}${A}${string}${B}${string}` ? -1 : 1;
type LenCmp<A extends string, B extends string> =
  A extends `${string}${infer AT}` ? B extends `${string}${infer BT}` ? LenCmp<AT, BT> : 1 : B extends "" ? 0 : -1;
type DigCmp<A extends string, B extends string> =
  A extends `${infer X}${infer AT}` ? B extends `${infer Y}${infer BT}` ? CmpDigit<X, Y> extends 0 ? DigCmp<AT, BT> : CmpDigit<X, Y> : 0 : 0;
type NumCmp<A extends number, B extends number> = LenCmp<`${A}`, `${B}`> extends 0 ? DigCmp<`${A}`, `${B}`> : LenCmp<`${A}`, `${B}`>;
type NLt<A extends number, B extends number> = NumCmp<A, B> extends -1 ? true : false;

type Insert<X extends number, S extends number[], Pre extends number[] = []> =
  S extends [infer H extends number, ...infer T extends number[]] ? Lt<X, H> extends true ? [...Pre, X, ...S] : Insert<X, T, [...Pre, H]> : [...Pre, X];
type InsertionSort<T extends number[], R extends number[] = []> =
  T extends [infer H extends number, ...infer Rest extends number[]] ? InsertionSort<Rest, Insert<H, R>> : R;

type Partition<P extends number, T extends number[], L extends number[] = [], G extends number[] = []> =
  T extends [infer H extends number, ...infer R extends number[]] ? NLt<H, P> extends true ? Partition<P, R, [...L, H], G> : Partition<P, R, L, [...G, H]> : [L, G];
type QuickSort<T extends number[]> =
  T extends [infer P extends number, ...infer R extends number[]] ? Partition<P, R> extends [infer L extends number[], infer G extends number[]] ? [...QuickSort<L>, P, ...QuickSort<G>] : never : [];

type Merge<A extends number[], B extends number[], R extends number[] = []> =
  A extends [infer X extends number, ...infer AT extends number[]] ? B extends [infer Y extends number, ...infer BT extends number[]]
    ? NLt<Y, X> extends true ? Merge<A, BT, [...R, Y]> : Merge<AT, B, [...R, X]> : [...R, ...A] : [...R, ...B];
type Halve<T extends number[], L extends number[] = []> = L["length"] extends T["length"] | [...T, 0]["length"] ? [L, T] : T extends [infer H extends number, ...infer R extends number[]] ? Halve<R, [...L, H]> : [L, T];
type MergeSort<T extends number[]> = T extends [any, any, ...any[]] ? Halve<T> extends [infer L extends number[], infer R extends number[]] ? Merge<MergeSort<L>, MergeSort<R>> : never : T;

type Data = [503, 87, 12, 999, 431, 250, 6, 777, 318, 64, 902, 145, 560, 33, 689, 271, 820, 98, 415, 7, 356, 640, 199, 72, 888, 523, 41, 310, 734, 16, 469, 952, 285, 128, 601, 57, 846, 392, 23, 715];
type R1 = InsertionSort<[503, 87, 12, 99, 431, 250, 6, 777, 318, 64, 902, 145, 560, 33, 689, 271, 820, 98, 415, 7]>;
type R2 = QuickSort<Data>;
type R3 = MergeSort<Data>;
type R4 = QuickSort<[...Data, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20]>;
