type F<K extends string> = { [P in K]: 1 };
type X = F<"a">;
