// Arithmetic on tuple lengths (Peano style).
type Tup<N, R extends 0[] = []> = R["length"] extends N ? R : Tup<N, [...R, 0]>;
type Add<A, B> = [...Tup<A>, ...Tup<B>]["length"];
type Sub<A, B> = Tup<A> extends [...Tup<B>, ...infer R] ? R["length"] : never;
type MulT<A extends 0[], B extends 0[], R extends 0[] = []> = B extends [0, ...infer BT extends 0[]] ? MulT<A, BT, [...R, ...A]> : R["length"];
type Mul<A, B> = MulT<Tup<A>, Tup<B>>;
type DivT<A extends 0[], B extends 0[], Q extends 0[] = []> = A extends [...B, ...infer R extends 0[]] ? DivT<R, B, [...Q, 0]> : Q["length"];
type ModT<A extends 0[], B extends 0[]> = A extends [...B, ...infer R extends 0[]] ? ModT<R, B> : A["length"];
type Div<A, B> = DivT<Tup<A>, Tup<B>>;
type Mod<A, B> = ModT<Tup<A>, Tup<B>>;
type Lt<A, B> = Tup<B> extends [...Tup<A>, 0, ...0[]] ? true : false;
type Gcd<A, B> = B extends 0 ? A : Gcd<B, Mod<A, B>>;
type Pow<A, B, I extends 0[] = [], R = 1> = I["length"] extends B ? R : Pow<A, B, [...I, 0], Mul<R, A>>;
type Fact<N, I extends 0[] = [0], R = 1> = I["length"] extends N ? Mul<R, N> : Fact<N, [...I, 0], Mul<R, I["length"]>>;
type SumTo<N, I extends 0[] = [], Acc extends 0[] = []> = I["length"] extends N ? [...Acc, ...I]["length"] : SumTo<N, [...I, 0], [...Acc, ...I]>;
// trial division up to the square root
type IsPrime<N, D extends 0[] = [0, 0]> =
  Lt<N, 2> extends true ? false
  : Lt<N, Mul<D["length"], D["length"]>> extends true ? true
  : Mod<N, D["length"]> extends 0 ? false : IsPrime<N, [...D, 0]>;
type Primes<N, I extends 0[] = [], R extends unknown[] = []> =
  I["length"] extends N ? R : Primes<N, [...I, 0], IsPrime<I["length"]> extends true ? [...R, I["length"]] : R>;
type Collatz<N, Steps extends 0[] = [], Max = N> =
  N extends 1 ? [Steps["length"], Max]
  : Collatz<Mod<N, 2> extends 0 ? Div<N, 2> : Add<Mul<N, 3>, 1>, [...Steps, 0], Lt<Max, N> extends true ? N : Max>;
// scaled up (tstc only)
type P1 = Add<3450, 6780>;
type P2 = Sub<10000, 1>;
type P3 = Mul<99, 99>;
type P4 = [Div<9801, 7>, Mod<9801, 7>];
type P5 = Gcd<9240, 7920>;
type P6 = Pow<2, 13>;
type P7 = Fact<7>;
type P8 = SumTo<300>;
type P9 = Primes<400>;
type P10 = Collatz<27>;
type P11 = Collatz<97>;
