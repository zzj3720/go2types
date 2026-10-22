// A stack machine interpreted at the type level, numbers as tuples.
type Tup<N extends number, R extends 0[] = []> = R["length"] extends N ? R : Tup<N, [...R, 0]>;
type Instr = ["push", number] | ["add"] | ["sub"] | ["mul"] | ["dup"] | ["swap"] | ["over"] | ["drop"]
  | ["jz", number] | ["jmp", number] | ["load", number] | ["store", number] | ["lt"] | ["halt"];
type SetAt<T extends unknown[], I extends number, V, Pre extends unknown[] = []> =
  T extends [infer H, ...infer R] ? Pre["length"] extends I ? [...Pre, V, ...R] : SetAt<R, I, V, [...Pre, H]> : T;
type MulT<A extends 0[], B extends 0[], R extends 0[] = []> = B extends [0, ...infer BT extends 0[]] ? MulT<A, BT, [...R, ...A]> : R;
// state: [pc, stack (top first, numbers as tuples), memory, steps]
type Step<P extends Instr[], PC extends number, St extends 0[][], M extends 0[][]> =
  P[PC] extends ["push", infer N extends number] ? [Inc<PC>, [Tup<N>, ...St], M]
  : P[PC] extends ["add"] ? St extends [infer A extends 0[], infer B extends 0[], ...infer R extends 0[][]] ? [Inc<PC>, [[...B, ...A], ...R], M] : never
  : P[PC] extends ["sub"] ? St extends [infer A extends 0[], infer B extends 0[], ...infer R extends 0[][]] ? [Inc<PC>, [B extends [...A, ...infer D extends 0[]] ? D : [], ...R], M] : never
  : P[PC] extends ["mul"] ? St extends [infer A extends 0[], infer B extends 0[], ...infer R extends 0[][]] ? [Inc<PC>, [MulT<B, A>, ...R], M] : never
  : P[PC] extends ["lt"] ? St extends [infer A extends 0[], infer B extends 0[], ...infer R extends 0[][]] ? [Inc<PC>, [A extends [...B, 0, ...0[]] ? [0] : [], ...R], M] : never
  : P[PC] extends ["dup"] ? St extends [infer A extends 0[], ...infer R extends 0[][]] ? [Inc<PC>, [A, A, ...R], M] : never
  : P[PC] extends ["over"] ? St extends [infer A extends 0[], infer B extends 0[], ...infer R extends 0[][]] ? [Inc<PC>, [B, A, B, ...R], M] : never
  : P[PC] extends ["swap"] ? St extends [infer A extends 0[], infer B extends 0[], ...infer R extends 0[][]] ? [Inc<PC>, [B, A, ...R], M] : never
  : P[PC] extends ["drop"] ? St extends [any, ...infer R extends 0[][]] ? [Inc<PC>, R, M] : never
  : P[PC] extends ["jz", infer T extends number] ? St extends [infer A extends 0[], ...infer R extends 0[][]] ? [A extends [] ? T : Inc<PC>, R, M] : never
  : P[PC] extends ["jmp", infer T extends number] ? [T, St, M]
  : P[PC] extends ["load", infer I extends number] ? [Inc<PC>, [M[I], ...St], M]
  : P[PC] extends ["store", infer I extends number] ? St extends [infer A extends 0[], ...infer R extends 0[][]] ? [Inc<PC>, R, SetAt<M, I, A>] : never
  : never;
type Inc<N extends number> = [...Tup<N>, 0]["length"] & number;
// runs at most 900 steps (tsc allows 1000 tail calls), returns the state
type Run<P extends Instr[], S extends [number, 0[][], 0[][]], Fuel extends 0[] = []> =
  P[S[0]] extends ["halt"] ? S : Fuel["length"] extends 900 ? S
  : Step<P, S[0], S[1], S[2]> extends infer N extends [number, 0[][], 0[][]] ? Run<P, N, [...Fuel, 0]> : never;
type Init = [0, [], [[], [], [], []]];
type Result<S extends [number, 0[][], 0[][]]> = S[1][0]["length"];
type Run4<P extends Instr[]> = Run<P, Run<P, Run<P, Run<P, Init>>>>;

// sum of 1..n: m0 = n, m1 = acc
type SumProg<N extends number> = [
  ["push", N], ["store", 0], ["push", 0], ["store", 1],
  ["load", 0], ["jz", 15],
  ["load", 1], ["load", 0], ["add"], ["store", 1],
  ["load", 0], ["push", 1], ["sub"], ["store", 0], ["jmp", 4],
  ["load", 1], ["halt"]];
// fib(n) iteratively: m0 = n, m1 = a, m2 = b
type FibProg<N extends number> = [
  ["push", N], ["store", 0], ["push", 0], ["store", 1], ["push", 1], ["store", 2],
  ["load", 0], ["jz", 20],
  ["load", 1], ["load", 2], ["add"], ["load", 2], ["store", 1], ["store", 2],
  ["load", 0], ["push", 1], ["sub"], ["store", 0], ["jmp", 6], ["halt"],
  ["load", 1], ["halt"]];
// n! with mul
type FactProg<N extends number> = [
  ["push", N], ["store", 0], ["push", 1], ["store", 1],
  ["load", 0], ["jz", 15],
  ["load", 1], ["load", 0], ["mul"], ["store", 1],
  ["load", 0], ["push", 1], ["sub"], ["store", 0], ["jmp", 4],
  ["load", 1], ["halt"]];
type I1 = Result<Run4<SumProg<100>>>;
type I2 = Result<Run4<FibProg<18>>>;
type I3 = Result<Run<FactProg<7>, Init>>;
