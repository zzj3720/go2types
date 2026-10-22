type F<T extends unknown[]> = [...T, 1];
type X = F<[0]>;
