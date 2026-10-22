type L<S extends unknown[]> = S;
type F<S> = S extends [infer A, ...infer B] ? L<B> : 0;
type X = F<[1, 2]>;
