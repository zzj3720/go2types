type L<S extends string> = S;
type F<S> = [S] extends [string] ? L<S> : 0;
type X = F<"a">;
