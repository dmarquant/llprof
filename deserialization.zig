const std = @import("std");

const SampleData = @import("serialization.zig").SampleData;
const StringTableEntry = @import("serialization.zig").StringTableEntry;

const LocationType = @import("location_table.zig").LocationType;
const Location = @import("location_table.zig").Location;

const DefaultArrayList = @import("default_array_list.zig").DefaultArrayList;

pub const CallchainNode = struct {
    loc_ix: u32 = 0,

    inclusive_count: u64 = 0,
    exclusive_count: u64 = 0,

    // index into the list of nodes
    children: DefaultArrayList(u32, 8) = .empty,
};

pub const CallchainTree = struct {
    node_list: std.ArrayList(CallchainNode) = .empty,

    root_node: u32 = 0,

    //arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) !CallchainTree {
        var tree: CallchainTree = .{
            .allocator = gpa,
        };


        try tree.node_list.append(tree.allocator, .{});
        return tree;
    }

    pub fn deinit(tree: *CallchainTree) void {
        _ = tree;
        //tree.arena.deinit();
    }

    pub fn addNode(tree: *CallchainTree, parent: *CallchainNode, loc_ix: u32) !*CallchainNode {
        try tree.node_list.append(tree.allocator, .{ .loc_ix = loc_ix });
        try parent.children.append(tree.allocator, @intCast(tree.node_list.items.len - 1));
        return &tree.node_list.items[tree.node_list.items.len - 1];
    }

    pub fn addCallchain(tree: *CallchainTree, locations: []u32) !void {
        var node = &tree.node_list.items[0];
        node.inclusive_count += 1;

        var ix = locations.len;
        while (ix > 0) {
            ix -= 1;

            var next_node: ?*CallchainNode = null;
            for (node.children.items()) |child| {
                if (tree.node_list.items[child].loc_ix == locations[ix]) {
                    next_node = &tree.node_list.items[child];
                    break;
                }
            }

            node = next_node orelse try tree.addNode(node, locations[ix]);
            if (ix == 0) {
                node.exclusive_count += 1;
            }
            node.inclusive_count += 1;
        }
    }
};


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

pub const Samples = struct {
    string_table: []const u8,
    location_table: []const Location,
    samples: []SampleData,
    locations: []u32,

    pub fn read(reader: *std.Io.Reader, arena: std.mem.Allocator) !Samples {
        const major = try reader.takeInt(u16, .little);
        const minor = try reader.takeInt(u16, .little);
        if (major != 0 or minor != 2) {
            return error.UnsupportedVersion;
        }

        const string_table_bytes = try reader.takeInt(u32, .little);
        const location_table_length = try reader.takeInt(u32, .little);
        const num_samples = try reader.takeInt(u64, .little);
        const num_locations = try reader.takeInt(u64, .little);

        const string_table = try reader.readAlloc(arena, string_table_bytes);
        var location_table = try arena.alloc(Location, location_table_length);

        for (0 .. location_table_length) |i| {
            const first_byte = try reader.takeByte();
            const location_type: LocationType = @enumFromInt(first_byte);

            switch (location_type) {
                .address => {
                    location_table[i] = .{ .address = try reader.takeInt(u64, .little) };
                },
                .elf_file => {
                    const name = try readStringTableEntry(reader);
                    const offset = try reader.takeInt(u64, .little);
                    location_table[i] = .{ 
                        .elf_file = .{ 
                            .name = name,
                            .offset = offset,
                        }
                    };
                },
                .symbol => {
                    const file_name = try readStringTableEntry(reader);
                    const name = try readStringTableEntry(reader);
                    location_table[i] = .{ 
                        .symbol = .{ 
                            .file_name = file_name,
                            .name = name,
                        }
                    };
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

        return .{
            .string_table = string_table,
            .location_table = location_table,
            .samples = samples,
            .locations = locations
        };
    }

    pub fn printLocation(self: *const Samples, loc_ix: u32) void {
        const loc = self.location_table[loc_ix];
        switch (loc) {
            .elf_file => |elf_file| {
                const name = self.lookupString(elf_file.name);
                std.debug.print("{s}@{x}\n", .{ name, elf_file.offset });
            },
            .symbol => |symbol| {
                const file_name = self.lookupString(symbol.file_name);
                const name = self.lookupString(symbol.name);
                std.debug.print("{s}:{s}\n", .{ file_name, name });
            },
            .address => |address| {
                std.debug.print("0x{x}\n", .{ address });
            }
        }
    }

    fn lookupString(self: *const Samples, entry: StringTableEntry) []const u8 {
        return self.string_table[entry.offset .. entry.offset + entry.len];
    }
};

const TreeWalkItem = struct {
    node: *CallchainNode,
    child_ix: u32 = 0,
};

pub fn printCallchainTree(samples: *const Samples, arena: std.mem.Allocator) !void {
    var cc_tree = try CallchainTree.init(arena);
    defer cc_tree.deinit();

    var loc_start: usize = 0;
    for (samples.samples) |sample| {
        const location_ixs = samples.locations[loc_start .. loc_start + sample.num_frames];
        try cc_tree.addCallchain(location_ixs);

        loc_start += sample.num_frames;
    }


    const root_node = &cc_tree.node_list.items[0];

    const total_inclusive_count = root_node.inclusive_count;
    
    var walk_stack: DefaultArrayList(TreeWalkItem, 128) = .empty;
    defer walk_stack.deinit(arena);

    try walk_stack.append(arena, .{
        .node = root_node,
    });

    while (walk_stack.len() > 0) {
        const item = walk_stack.topPtr();
        if (item.child_ix < item.node.children.len()) {

            const child = &cc_tree.node_list.items[item.node.children.items()[item.child_ix]];
            try walk_stack.append(arena, .{
                .node = child,
            });

            const inclusive_pct: f64 = @as(f64, @floatFromInt(child.inclusive_count))/@as(f64, @floatFromInt(total_inclusive_count)) * 100.0;

            if (inclusive_pct > 0.05) {
                for (2 .. walk_stack.len()) |_| {
                    std.debug.print("  ", .{});
                }
                std.debug.print("{d:.2} - ", .{ inclusive_pct });
                samples.printLocation(child.loc_ix);
            }

            item.child_ix += 1;
        } else {
            _ = walk_stack.pop();
        }
    }
}

pub fn main(init: std.process.Init) !void {
    var cwd = std.Io.Dir.cwd();
    var samples_bin = try cwd.openFile(init.io, "./samples.bin", .{});

    var buffer: [16 * 4096]u8 = undefined;
    var samples_reader = samples_bin.reader(init.io, &buffer);

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();

    const samples = try Samples.read(&samples_reader.interface, arena.allocator());

    try printCallchainTree(&samples, arena.allocator());
}

