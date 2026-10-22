// Fibonacci with tuples: naive tree recursion (tsc caches alias
// instantiations, so it is linear there), iteration, and a list.
type Tup<N extends number, R extends 0[] = []> = R["length"] extends N ? R : Tup<N, [...R, 0]>;
type FibT<N extends 0[]> = N extends [0, 0, ...infer R extends 0[]] ? [...FibT<[0, ...R]>, ...FibT<R>] : N;
type Fib<N extends number> = FibT<Tup<N>> extends infer F extends 0[] ? F["length"] : never;
type FibIter<N extends number, I extends 0[] = [], A extends 0[] = [], B extends 0[] = [0]> =
  I["length"] extends N ? A["length"] : FibIter<N, [...I, 0], B, [...A, ...B]>;
type FibList<N extends number, L extends number[] = [], A extends 0[] = [], B extends 0[] = [0]> =
  L["length"] extends N ? L : FibList<N, [...L, A["length"]], B, [...A, ...B]>;
// sum of the first n Fibonacci numbers by naive recursion over every index
type SumFibs<N extends 0[], Acc extends 0[] = []> = N extends [0, ...infer R extends 0[]] ? SumFibs<R, [...Acc, ...FibT<N>]> : Acc["length"];

type Fib10 = Fib<10>;
type Fib15 = Fib<15>;
type Fib18 = Fib<18>;
type Fib19 = Fib<19>;
type FibIter19 = FibIter<19>;
type FibList19 = FibList<19>;
type SumFibs17 = SumFibs<Tup<17>>;
