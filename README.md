# L-System-String-Rewriting-Engine

The Discrete Fractals project is an efficient implementation of a discrete fractal generator written entirely in x86-64 assembly for Linux, demonstrating advanced skills in low-level memory management and performance optimization.

- The program processes ASCII character replacement rules to generate complex strings over a specified number of iterations, operating without any predefined limitations on the length of the processed input data.
- The solution relies entirely on direct Linux system calls, such as `sys_mmap` and `sys_mremap`, for the dynamic allocation and scaling of memory buffers in page-sized units, completely bypassing the C standard library.
- The application's architecture ensures high performance by efficiently swapping working buffer pointers between iterations and utilizing optimized parsing loops.
- Additionally, the code implements rigorous error handling and argument verification, ensuring the proper release of allocated resources via `sys_munmap` and safe termination with the appropriate exit code across all edge cases.

The project compiles into a Position Independent Executable (PIE) using the `nasm` and `ld` toolchain.
