type A = [A] | 1;
type B = { a: B };
type C = () => C;
type D<T> = T extends 0 ? D<1> : 2;
type E = D<0>;
