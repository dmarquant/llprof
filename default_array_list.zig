const std = @import("std");

const CurrentStorage = enum {
    fixed,
    allocated
};

pub fn DefaultArrayList(comptime T: type, comptime FixedSize: usize) type {
    return struct {
        const Self = @This();

        storage: union(CurrentStorage) {
            fixed: struct {
                len: usize = 0,
                data: [FixedSize]T = undefined,
            },
            allocated: std.ArrayList(T),

        },

        pub const empty: Self = .{ .storage = .{ .fixed = .{} } };

        pub fn deinit(al: *Self, gpa: std.mem.Allocator) void {
            switch (al.storage) {
                .fixed => {},
                .allocated => |*allocated| {
                    allocated.deinit(gpa);
                }
            }
        }

        pub fn capacity(al: *const Self) usize {
            switch (al.storage) {
                .fixed => |*fixed| {
                    return fixed.data.len;
                },
                .allocated => |allocated| {
                    return allocated.capacity;
                }
            }
        }

        pub fn items(al: *const Self) []const T {
            switch (al.storage) {
                .fixed => |*fixed| {
                    return fixed.data[0 .. fixed.len];
                },
                .allocated => |allocated| {
                    return allocated.items;
                }
            }
        }

        pub fn ensureTotalCapacity(al: *Self, gpa: std.mem.Allocator, new_capacity: usize) !void {
            switch (al.storage) {
                .fixed => |*fixed| {
                    if (fixed.data.len < new_capacity) {
                        var new_array_list: std.ArrayList(T) = .empty;
                        try new_array_list.ensureTotalCapacity(gpa, new_capacity);
                        new_array_list.appendSliceAssumeCapacity(fixed.data[0 .. fixed.data.len]);

                        al.storage = .{
                            .allocated = new_array_list
                        };
                    }
                },
                .allocated => |*allocated| {
                    try allocated.ensureTotalCapacity(gpa, new_capacity);
                }
            }
        }

        pub fn append(al: *Self, gpa: std.mem.Allocator, value: T) !void {
            try al.insert(gpa, al.items().len, value);
        }

        pub fn insert(al: *Self, gpa: std.mem.Allocator, i: usize, value: T) !void {
            try al.ensureTotalCapacity(gpa, al.items().len + 1);

            switch (al.storage) {
                .fixed => |*fixed| {
                    @memmove(fixed.data[i + 1 .. fixed.len + 1], fixed.data[i .. fixed.len]);
                    fixed.data[i] = value;
                    fixed.len += 1;
                },
                .allocated => |*allocated| {
                    try allocated.insert(gpa, i, value);
                }
            }
        }
    };
}

//pub fn main(init: std.process.Init) !void {
pub fn sample(init: std.process.Init) !void {
    var arr: DefaultArrayList(u8, 8) = .empty;
    defer arr.deinit(init.gpa);

    std.debug.print("Sizeof default array list: {}\n", .{ @sizeOf(@TypeOf(arr)) });

    try arr.append(init.gpa, 'h');
    try arr.append(init.gpa, 'e');
    try arr.append(init.gpa, 'l');
    try arr.append(init.gpa, 'l');
    try arr.append(init.gpa, 'o');
    std.debug.print("capacity: {}\n", .{ arr.capacity() });

    try arr.insert(init.gpa, 3, 'X');

    try arr.append(init.gpa, ',');
    try arr.append(init.gpa, ' ');
    try arr.append(init.gpa, 'w');
    try arr.append(init.gpa, 'o');
    try arr.append(init.gpa, 'r');
    try arr.append(init.gpa, 'l');
    try arr.append(init.gpa, 'd');
    try arr.append(init.gpa, '!');
    
    std.debug.print("capacity: {}\n", .{ arr.capacity() });

    const items = arr.items();
    std.debug.print("Items: {any}\n", .{ items });

    std.debug.print("Items: {s}\n", .{ items });
}
