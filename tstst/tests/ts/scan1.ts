// A small TypeScript file for scanner tests
interface Point { x: number; y?: string }
export function add(a: number, b: number): number {
  return a + b * 2 - 0x1F / 3.5e2;
}
const s = `template ${add(1, 2)} done`;
let re = /ab+c/gi;
class Foo<T> extends Bar implements Baz {
  private readonly name: string = "héllo\n";
  constructor() { super(); }
}
