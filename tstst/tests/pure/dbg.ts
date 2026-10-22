type Rest<N extends unknown[], All extends unknown[]> = All extends [...N, ...infer R] ? R : "no";
type R0 = Rest<[], [0, 0, 0]>;
type R1 = Rest<[0], [0, 0, 0]>;
type R2 = Rest<[0, 0, 0], [0, 0, 0]>;
type R3 = [0, 0, 0] extends [...[], ...infer R] ? R : "no";
type R4 = [0, 0, 0] extends [...[0], ...infer R] ? R : "no";
type Take<S extends string, N extends unknown[], Acc extends string = ""> =
  N extends [unknown, ...infer NR] ? S extends `${infer C}${infer R}` ? Take<R, NR, `${Acc}${C}`> : Acc : Acc;
type T1 = Take<"abcd", [0, 0]>;
type T2 = Take<"abcd", R0>;
