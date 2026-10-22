// String processing character by character.
type Txt = "The quick brown fox jumps over the lazy dog, then the dog sleeps while the fox runs far away into the forest. Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur.";
type Chars<S extends string, R extends string[] = []> = S extends `${infer C}${infer T}` ? Chars<T, [...R, C]> : R;
type StrLen<S extends string> = Chars<S>["length"];
type Reverse<S extends string, R extends string = ""> = S extends `${infer C}${infer T}` ? Reverse<T, `${C}${R}`> : R;
type Split<S extends string, D extends string, R extends string[] = []> =
  S extends `${infer A}${D}${infer B}` ? Split<B, D, [...R, A]> : [...R, S];
type Join<T extends string[], D extends string, R extends string = ""> =
  T extends [infer F extends string, ...infer Rest extends string[]] ? Join<Rest, D, R extends "" ? F : `${R}${D}${F}`> : R;
type ReplaceAll<S extends string, F extends string, T extends string, R extends string = ""> =
  S extends `${infer A}${F}${infer B}` ? ReplaceAll<B, F, T, `${R}${A}${T}`> : `${R}${S}`;
type CountChar<S extends string, C extends string, N extends 0[] = []> =
  S extends `${infer H}${infer T}` ? CountChar<T, C, H extends C ? [...N, 0] : N> : N["length"];
type Upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
type KebabCase<S extends string, R extends string = ""> =
  S extends `${infer C}${infer T}` ? KebabCase<T, C extends Lowercase<C> ? `${R}${C}` : R extends "" ? `${R}${Lowercase<C>}` : `${R}-${Lowercase<C>}`> : R;
type CamelCase<S extends string, R extends string = ""> =
  S extends `${infer A}_${infer B}${infer T}` ? CamelCase<T, `${R}${A}${Uppercase<B>}`> : `${R}${S}`;
type IsPalindrome<S extends string> = S extends Reverse<S> ? true : false;
type Words<S extends string> = Split<S, " ">["length"];
type Vowels<S extends string> = CountChar<S, "a" | "e" | "i" | "o" | "u">;

// decimal strings: addition and multiplication digit by digit
type DigitAdd = [
  ["0","1","2","3","4","5","6","7","8","9"], ["1","2","3","4","5","6","7","8","9","10"],
  ["2","3","4","5","6","7","8","9","10","11"], ["3","4","5","6","7","8","9","10","11","12"],
  ["4","5","6","7","8","9","10","11","12","13"], ["5","6","7","8","9","10","11","12","13","14"],
  ["6","7","8","9","10","11","12","13","14","15"], ["7","8","9","10","11","12","13","14","15","16"],
  ["8","9","10","11","12","13","14","15","16","17"], ["9","10","11","12","13","14","15","16","17","18"]];
type Dig = "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9";
type ToIdx<D extends string> = D extends `${infer N extends number}` ? N : 0;
type RevStr<S extends string, R extends string = ""> = S extends `${infer C}${infer T}` ? RevStr<T, `${C}${R}`> : R;
// adds reversed digit strings
type AddRev<A extends string, B extends string, C extends 0 | 1 = 0, R extends string = ""> =
  A extends `${infer X extends Dig}${infer AT}`
    ? B extends `${infer Y extends Dig}${infer BT}` ? AddDigit<DigitAdd[ToIdx<X>][ToIdx<Y>], C, AT, BT, R> : AddDigit<DigitAdd[ToIdx<X>][0], C, AT, "", R>
    : B extends `${infer Y extends Dig}${infer BT}` ? AddDigit<DigitAdd[ToIdx<Y>][0], C, "", BT, R>
    : C extends 1 ? `${R}1` : R;
type Inc<S extends string> = S extends `1${infer D extends Dig}` ? (D extends "9" ? "20" : `1${DigitAdd[ToIdx<D>][1]}`) : S extends "9" ? "10" : DigitAdd[ToIdx<S>][1];
type AddDigit<S extends string, C extends 0 | 1, AT extends string, BT extends string, R extends string> =
  (C extends 1 ? Inc<S> : S) extends infer T extends string
    ? T extends `1${infer D extends Dig}` ? AddRev<AT, BT, 1, `${R}${D}`> : AddRev<AT, BT, 0, `${R}${T}`>
    : never;
type BigAdd<A extends string, B extends string> = RevStr<AddRev<RevStr<A>, RevStr<B>>>;
type BigFib<N extends number, I extends 0[] = [], A extends string = "0", B extends string = "1"> =
  I["length"] extends N ? A : BigFib<N, [...I, 0], B, BigAdd<A, B>>;
// multiplication by repeated addition of shifted rows
type MulDigit<A extends string, D extends string, I extends 0[] = [], R extends string = "0"> =
  I["length"] extends ToIdx<D> ? R : MulDigit<A, D, [...I, 0], BigAdd<R, A>>;
type BigMul<A extends string, B extends string, R extends string = "0"> =
  B extends `${infer D extends Dig}${infer T}` ? BigMul<A, T, BigAdd<R extends "0" ? "0" : `${R}0`, MulDigit<A, D>>> : R;
type BigFact<N extends number, I extends 0[] = [0], R extends string = "1"> =
  I["length"] extends N ? BigMul<R, `${N}`> : BigFact<N, [...I, 0], BigMul<R, `${I["length"]}`>>;
// scaled up (tstc only)
type Txt8 = `${Txt}${Txt}${Txt}${Txt}${Txt}${Txt}${Txt}${Txt}`;
type S1 = StrLen<Txt8>;
type S2 = Reverse<Txt8>;
type S3 = Words<Txt8>;
type S4 = Join<Split<Txt8, " ">, "_">;
type S5 = ReplaceAll<Txt8, "the", "THE">;
type S6 = Vowels<Txt8>;
type S9 = IsPalindrome<`${Txt8}${Reverse<Txt8>}`>;
type S10 = BigFib<1000>;
type S11 = BigFact<60>;
type S12 = BigMul<"123456789123456789123456789123456789", "987654321987654321987654321987654321">;
