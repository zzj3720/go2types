type H<T extends string> = [T];
type A = H<"a">;
type B = H<Uppercase<"x">>;
type C = ReturnType<() => 1>;
