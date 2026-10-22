type A = 1 extends (number) ? "y" : "n";
type B = [1] extends [infer X] ? X : 0;
