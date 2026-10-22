type L<S extends number> = S;
type F<S> = S extends `${infer N extends number}` ? L<N> : 0;
type X = F<"12">;
