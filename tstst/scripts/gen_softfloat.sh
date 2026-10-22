#!/bin/sh
# Compiles go2types/softfloat to lib/pure/softfloat.ts (the float arithmetic
# of the pure runtime) after testing it against the hardware.
cd "$(dirname "$0")/../go2types"
go test ./softfloat || exit 1
# -split 8: shallow aliases, which real checkers resolve fast (tsc_run.sh)
go run . -split 8 -o ../lib/pure/softfloat.ts -lib . -v \
  -export Fadd=Fadd,Fsub=Fsub,Fmul=Fmul,Fdiv=Fdiv,Fneg=Fneg,Feq=Feq,Fne=Fne,Flt=Flt,Fle=Fle,I2f=I2f,U2f=U2f,F2i=F2i,F2u=F2u,Fround32=Fround32,F32bits=F32bits,Bits2f32=Bits2f32,Isnan=Isnan,Ffloor=Ffloor,Fsqrt=Fsqrt,Ftoa=Ftoa \
  ./softfloat 2>&1 | grep -v "^go2types: reached"
