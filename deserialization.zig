const std = @import("std");

const SampleData = @import("serialization.zig").SampleData;
const StringTableEntry = @import("serialization.zig").StringTableEntry;

const LocationType = @import("location_table.zig").LocationType;
const Location = @import("location_table.zig").Location;

/// Load binary samples into machine readable format.
///
fn readStringTableEntry(reader: *std.Io.Reader) !StringTableEntry {
    const str_offset = try reader.takeInt(u32, .little);
    const str_len = try reader.takeInt(u32, .little);
    return .{
        .offset = str_offset,
        .len = str_len
    };
}

fn lookupString(st: []const u8, entry: StringTableEntry) []const u8 {
    return st[entry.offset .. entry.offset + entry.len];
}

pub fn readSamples(reader: *std.Io.Reader, arena: std.mem.Allocator) !void {
    const major = try reader.takeInt(u16, .little);
    const minor = try reader.takeInt(u16, .little);
    if (major != 0 or minor != 2) {
        return error.UnsupportedVersion;
    }

    const string_table_bytes = try reader.takeInt(u32, .little);
    const location_table_length = try reader.takeInt(u32, .little);
    const num_samples = try reader.takeInt(u64, .little);
    const num_locations = try reader.takeInt(u64, .little);

    std.debug.print("Reading {} samples and {} locations\n", .{ num_samples, num_locations });

    const string_table = try reader.readAlloc(arena, string_table_bytes);

    // TODO: This can be fixed size...
    var location_table: std.ArrayList(Location) = .empty;

    for (0 .. location_table_length) |_| {
        const first_byte = try reader.takeByte();
        const location_type: LocationType = @enumFromInt(first_byte);

        switch (location_type) {
            .address => {
                try location_table.append(arena, .{ .address = try reader.takeInt(u64, .little) });
            },
            .elf_file => {
                const name = try readStringTableEntry(reader);
                const offset = try reader.takeInt(u64, .little);
                try location_table.append(arena, .{ 
                    .elf_file = .{ 
                        .name = name,
                        .offset = offset,
                    }
                });
            },
            .symbol => {
                const file_name = try readStringTableEntry(reader);
                const name = try readStringTableEntry(reader);
                try location_table.append(arena, .{ 
                    .symbol = .{ 
                        .file_name = file_name,
                        .name = name,
                    }
                });
            }
        }
    }

    const samples = try arena.alloc(SampleData, num_samples);
    for (0 .. num_samples) |i| {
        samples[i].time_ns = try reader.takeInt(u64, .little);
        samples[i].cpu = try reader.takeInt(u32, .little);
        samples[i].tid = try reader.takeInt(u32, .little);
        samples[i].num_frames = try reader.takeInt(u32, .little);
    }

    const locations = try arena.alloc(u32, num_locations);
    for (0 .. num_locations) |i| {
        locations[i] = try reader.takeInt(u32, .little);
    }

    var f: usize = 0;
    for (0 .. 30) |i| {
        std.debug.print("{},{},{}\n", .{ samples[i].cpu, samples[i].tid, samples[i].time_ns });

        for (0 .. samples[i].num_frames) |cf| {
            const loc = location_table.items[locations[f]];
            switch (loc) {
                .elf_file => |elf_file| {
                    const name = lookupString(string_table, elf_file.name);
                    std.debug.print("  {}: {s}@{x} ({})\n", .{ cf, name, elf_file.offset, locations[f] });
                },
                .symbol => |symbol| {
                    const file_name = lookupString(string_table, symbol.file_name);
                    const name = lookupString(string_table, symbol.name);
                    std.debug.print("  {}: {s}:{s} ({})\n", .{ cf, file_name, name, locations[f] });
                },
                .address => |address| {
                    std.debug.print("  {}: 0x{x}\n", .{ cf, address });
                }
            }
            f += 1;
        }
    }

    const rest = try reader.allocRemaining(arena, .unlimited);
    std.debug.print("The rest has size: {}\n", .{ rest.len });
}

pub fn main(init: std.process.Init) !void {
    var cwd = std.Io.Dir.cwd();
    var samples_bin = try cwd.openFile(init.io, "./samples.bin", .{});

    var buffer: [16 * 4096]u8 = undefined;
    var samples_reader = samples_bin.reader(init.io, &buffer);

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();

    try readSamples(&samples_reader.interface, arena.allocator());
}

