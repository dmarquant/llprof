const std = @import("std");
const serialization = @import("serialization.zig");


/// Keep track of all locations existing in a list of samples and assign a u32 to it.
///
/// For a profiler checking samples the list of locations is initially built and then never changed
/// again. This means the lookup direction is inverted after the initial construction. Therefore
/// there is a location table for filling with fast insertion and then there is a filled one for
/// fast lookup.
///
pub const LocationType = enum (u8) {
    address,
    elf_file,
    symbol,
};

pub const SymbolInfo = struct {
    file_name: serialization.StringTableEntry,
    name: serialization.StringTableEntry,
    // TODO: Add line number info
};

pub const Location = union(LocationType) {
    address: u64,
    elf_file: struct {
        name: serialization.StringTableEntry,
        offset: u64,
    },
    symbol: SymbolInfo,
};

pub const FillingLocationTable = struct {
    hash_map: std.AutoHashMapUnmanaged(Location, u32) = .{},
    next: u32 = 0,

    pub fn addOrGet(table: *FillingLocationTable, gpa: std.mem.Allocator, location: Location) !u32 {
        const it = try table.hash_map.getOrPut(gpa, location);
        if (!it.found_existing) {
            it.value_ptr.* = table.next;
            table.next += 1;
        }
        return it.value_ptr.*;
    }

    pub fn serializedSize(table: *const FillingLocationTable) u32 {
        var byteSize: usize = 0;

        var it = table.hash_map.keyIterator();
        while (it.next()) |loc| {
            byteSize += 1;
            byteSize += switch (loc.*) {
                .address => 8,
                .elf_file => 16,
                .symbol => 16,
            };
        }
        return @intCast(byteSize);
    }
};
