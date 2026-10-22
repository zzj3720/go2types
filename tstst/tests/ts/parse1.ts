import { a, type B } from "./mod";
export default class Shape<T extends object = {}> implements Drawable {
  static count = 0;
  #secret?: string;
  constructor(private readonly name: string, public size = 1) {}
  get area(): number { return this.size ** 2; }
  async *gen(): AsyncGenerator<number> { yield* other(); }
  @decorated method<K extends keyof T>(key: K): T[K] | undefined { return undefined as any; }
}
type Mapped<T> = { readonly [K in keyof T]?: T[K] extends Function ? never : T[K] };
type Cond<T> = T extends [infer H, ...infer R] ? `${H & string}-${R["length"]}` : never;
enum Color { Red = 1, Green = Red << 1, Blue }
namespace NS.Inner { export const x = <const>[1, 2]; }
declare module "foo" { export function f(...args: unknown[]): void; }
let v = a?.b?.[c]!(d) ?? (e as F) satisfies G;
for await (const [k, { v = 1 }] of things) { label: if (k) break label; else continue; }
const jsxLike = x < y > z;
function overload(a: string): void;
function overload(a: any) { try { throw new Error(`bad ${a}`); } catch { } finally { } }
let broken = (;
