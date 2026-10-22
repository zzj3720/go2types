type H<T extends { a: 1 }> = [T];
type A = H<{ b: 1 }>;
