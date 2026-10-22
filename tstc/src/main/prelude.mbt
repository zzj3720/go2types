// Embedded prelude (global types), see lib/prelude.ts for the same text.

let prelude_src : String =
  #|// Global declarations available to every program (subset of lib.es5.d.ts).
  #|type PropertyKey = string | number | symbol;
  #|type Partial<T> = { [P in keyof T]?: T[P] };
  #|type Required<T> = { [P in keyof T]-?: T[P] };
  #|type Readonly<T> = { readonly [P in keyof T]: T[P] };
  #|type Pick<T, K extends keyof T> = { [P in K]: T[P] };
  #|type Record<K extends keyof any, T> = { [P in K]: T };
  #|type Exclude<T, U> = T extends U ? never : T;
  #|type Extract<T, U> = T extends U ? T : never;
  #|type Omit<T, K extends keyof any> = Pick<T, Exclude<keyof T, K>>;
  #|type NonNullable<T> = T & {};
  #|type Parameters<T extends (...args: any) => any> = T extends (...args: infer P) => any ? P : never;
  #|type ConstructorParameters<T extends abstract new (...args: any) => any> = T extends abstract new (...args: infer P) => any ? P : never;
  #|type ReturnType<T extends (...args: any) => any> = T extends (...args: any) => infer R ? R : any;
  #|type InstanceType<T extends abstract new (...args: any) => any> = T extends abstract new (...args: any) => infer R ? R : any;
  #|type NoInfer<T> = T;
  #|type Awaited<T> = T;
  #|type ArrayLike<T> = { readonly length: number; readonly [n: number]: T };
  #|/** @native uppercase */
  #|type Uppercase<S extends string> = S;
  #|/** @native lowercase */
  #|type Lowercase<S extends string> = S;
  #|/** @native capitalize */
  #|type Capitalize<S extends string> = S;
  #|/** @native uncapitalize */
  #|type Uncapitalize<S extends string> = S;
  #|/** @native indexok */
  #|type __tstc_index_ok<O, K> = 1;
  #|/** @native subst */
  #|type __TstcSubst<N, C, E, M> = N;
  #|/** @native strip */
  #|type __TstcStrip<T> = T;
  #|/** @native iface */
  #|type __TstcIface<T> = T;
