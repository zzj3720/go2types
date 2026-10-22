type F<K extends "a"> = { a: 1 }[K];
type X = F<"a">;
