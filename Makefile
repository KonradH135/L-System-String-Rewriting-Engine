.PHONY: all clean

all: discrete_fractal

discrete_fractal.o: discrete_fractal.asm
	nasm -f elf64 -w+all -w+error -w-unknown-warning -w-reloc-rel -o discrete_fractal.o discrete_fractal.asm
	
discrete_fractal: discrete_fractal.o
	ld -pie -I /lib64/ld-linux-x86-64.so.2 --fatal-warnings -o discrete_fractal discrete_fractal.o
	
clean:
	rm -f discrete_fractal.o discrete_fractal
