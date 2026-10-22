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
// scaled up (tstc only)
type Big = [331, 970, 154, 404, 666, 49, 74, 840, 548, 96, 374, 596, 59, 931, 519, 219, 38, 88, 444, 428, 71, 246, 92, 564, 434, 60, 846, 579, 126, 970, 228, 645, 642, 596, 970, 63, 590, 599, 406, 50, 999, 226, 47, 570, 879, 136, 296, 429, 147, 553, 120, 584, 315, 573, 835, 698, 185, 105, 595, 584, 654, 192, 381, 99, 560, 729, 64, 577, 61, 633, 210, 508, 696, 544, 437, 795, 321, 476, 599, 945, 464, 370, 306, 254, 813, 184, 715, 798, 249, 83, 588, 307, 537, 506, 896, 351, 746, 459, 294, 623, 74, 120, 524, 428, 168, 775, 350, 155, 955, 500, 431, 40, 985, 684, 79, 782, 571, 586, 808, 896, 837, 321, 348, 711, 358, 608, 508, 593, 816, 467, 70, 860, 95, 967, 276, 485, 713, 680, 66, 62, 748, 718, 317, 662, 591, 697, 841, 456, 291, 733, 395, 908, 684, 355, 23, 963, 472, 363, 172, 625];
type R1 = InsertionSort<[...Data, ...Data]>;
type R2 = QuickSort<Big>;
type R3 = MergeSort<Big>;
