// Types known when compiling: the constants of a program.

enum Ty {
  TAny
  TUnknown
  TNever
  TString
  TNumber
  TBigInt
  TSymbol
  TObjectKw
  TNull
  TUndefined
  TVoid
  TTrue
  TFalse
  TStrLit(Str)
  TNumLit(Double)
  TBigLit(String) // decimal text that does not fit in 64 bits
  TInt(Int64) // a bigint literal that fits
  TUnion(Array[Ty])
}

fn bool_ty(b : Bool) -> Ty {
  if b {
    TTrue
  } else {
    TFalse
  }
}

let t_boolean : Ty = TUnion([TFalse, TTrue])

// Tuple element kinds
const K_REQ = 0

const K_OPT = 1

const K_REST = 2
