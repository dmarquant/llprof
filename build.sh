gcc test.c -o test -g -O2 -fPIE -pie -fno-omit-frame-pointer

zig build-exe profiler.zig
zig build-exe deserialization.zig

zig build-lib capi.zig -fPIC
gcc test_consumer.c -o test_consumer libcapi.a


