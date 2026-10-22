# The runtime library of programs compiled by tstc.
CC ?= clang
CFLAGS ?= -O2 -g -Wall -Wextra -Wno-unused-parameter
SRC = $(wildcard *.c)
OBJ = $(SRC:%.c=build/%.o)

libtstcrt.a: $(OBJ)
	rm -f $@
	ar rcs $@ $(OBJ)

build/%.o: %.c tstc.h desc.h lib.h
	@mkdir -p build
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -rf build libtstcrt.a
