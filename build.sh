gcc test.c -o test -g -O2 -fPIE -pie -fno-omit-frame-pointer

zig build-exe profiler.zig

