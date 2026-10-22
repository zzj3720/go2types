type L<S extends number> = S;
type F<S> = S extends `${infer A}` ? L<A> : 0;
