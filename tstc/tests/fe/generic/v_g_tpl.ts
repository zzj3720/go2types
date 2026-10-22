type F<T extends string | number> = `a${T}`;
type X = F<1>;
