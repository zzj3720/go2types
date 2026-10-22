type L<S extends string> = S;
type F<S> = S extends `${infer A}${infer B}` ? L<B> : 0;
type X = F<"ab">;
