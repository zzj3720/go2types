type F<T> = T extends string ? Uppercase<T> : T;
type A = F<"a">;
