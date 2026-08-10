const std = @import("std");
const linux = std.os.linux;
const ArrayList = std.ArrayList;

const procmaps = @import("procmaps.zig");

const Sample = struct {
    cpu: u32,
    tid: u32,
    time_ns: u64,
    cc_len: u32
};

const Samples = struct {
    samples: ArrayList(Sample) = .empty,
    ips: ArrayList(u64) = .empty,

    fn deinit(samples: *Samples, gpa: std.mem.Allocator) void {
        samples.samples.deinit(gpa);
        samples.ips.deinit(gpa);
    }
};

const ExecutableRegion = struct {
    // mapped address space
    start: u64,
    end: u64,

    file_name: []const u8,
    offset: u64,

    elf_file: ?std.Io.File = null,
    elf: ?std.debug.ElfFile = null,
    dwarf: ?std.debug.Dwarf = null,

    fn deinit(region: *ExecutableRegion, io: std.Io, gpa: std.mem.Allocator) void {
        if (region.dwarf) |*dwarf| {
            dwarf.deinit(gpa);
        }
        if (region.elf_file) |f| {
            f.close(io);
        }
    }
};

fn lookupAddress(regions: []ExecutableRegion, addr: u64) ?ExecutableRegion {
    for (regions) |region| {
        if (region.start <= addr and addr < region.end) {
            return region;
        }
    }
    return null;
}

// Basically a perf_event sampling data for a single cpu
const PerfSampler = struct {
    cpu: u64,
    fd: std.posix.fd_t,
    page_size: usize,
    ring_buffer_size: usize,
    buffer: []u8
};

const RingBufferReader = struct {
    first: std.Io.Reader,
    second: std.Io.Reader,

    fn init(s1: []u8, s2: []u8) RingBufferReader {
        const r1 = std.Io.Reader.fixed(s1);
        const r2 = std.Io.Reader.fixed(s2);
        return .{
            .first = r1,
            .second = r2,
        };
    }

    // maybe I could provide a reader interface, but I don't want to bother with it (also it needs another buffer)
    fn takeStruct(r: *RingBufferReader, comptime T: type) std.Io.Reader.Error!T {
        // NOTE: This only handles values correctly that do not cross across the ring buffer boundary
        // Currently I am reading always in chunks of 8bytes, therefore this will not be a problem
        // with the buffer being a multiple of the page size, but probably I could assert that this
        // is the case here
        if (r.first.takeStruct(T, .native)) |s| {
            return s;
        } else |_| {
            return r.second.takeStruct(T, .native);
        }
    }

    fn takeInt(r: *RingBufferReader, comptime T: type) std.Io.Reader.Error!T {
        if (r.first.takeInt(T, .native)) |s| {
            return s;
        } else |_| {
            return r.second.takeInt(T, .native);
        }
    }
};

fn openPid(pid: i32) !std.posix.fd_t {
    const rc = linux.pidfd_open(pid, 0);
    if (linux.errno(rc) == .SUCCESS) {
        return @intCast(rc);
    } else {
        return error.PidfOpenFailed;
    }
}
    
fn recordSamples(sampler: PerfSampler, samples: *Samples, gpa: std.mem.Allocator) !void {
    var metadata = std.mem.bytesAsValue(linux.perf_event_mmap_page, sampler.buffer[0 .. @sizeOf(linux.perf_event_mmap_page)]);
    const sampledata = sampler.buffer[sampler.page_size .. ];

    std.debug.print("Woken up to write samples for CPU({}. {} bytes available\n", .{
        sampler.cpu,
        metadata.data_head - metadata.data_tail
    });

    var tail = metadata.data_tail;
    while (tail < metadata.data_head) {
        // Can the ring buffer wrap around?
        const readp = tail % sampler.ring_buffer_size;
        var reader = RingBufferReader.init(sampledata[readp ..], sampledata[0 ..]);

        const header = try reader.takeStruct(linux.perf_event_header);

        const ip = try reader.takeInt(u64);
        const pid = try reader.takeInt(u32);
        const tid = try reader.takeInt(u32);
        const time = try reader.takeInt(u64);
        const size_callchain = try reader.takeInt(u64);

        const sample = Sample {
            .cpu = @intCast(sampler.cpu),
            .tid = tid,
            .time_ns = time,
            .cc_len = @intCast(size_callchain + 1), // one more for the current ip
        };

        try samples.samples.append(gpa, sample);

        // TODO: Samples should be written into a growing array
        // To save space I could store between the samples what has actually changed
        // The time obviously always changes. Thread id and cpu will remain equal for a long time.
        // The callchain will also remain (at least) partially the same for consecutive samples.
        // My idea would be to store a bit for cpu and tid respectively if they differ from the
        // previous sample. And for the callchain I could store the number of samples that are
        // equal. Maybe separate arrays would also make sense.
        for (0 .. size_callchain) |_| {
            // TODO: Kernel/userspace transitions
            const cc_ip = try reader.takeInt(u64);
            try samples.ips.append(gpa, cc_ip);
        }

        try samples.ips.append(gpa, ip);

        _ = pid;

        tail += header.size;
    }
    // notify the kernel about that data was read
    metadata.data_tail = tail;
}

pub fn main(init: std.process.Init) !void {
    var pipes: [2]i32 = undefined;
    _ = linux.pipe(&pipes); // TODO: Handle error

    // TODO: Check the clone syscall. perf is using that
    const rc = linux.fork();
    if (linux.errno(rc) != .SUCCESS) {
        std.debug.print("Failed to fork\n", .{});
        return;
    }
    const pid: i32 = @intCast(rc);

    if (pid == 0) {
        std.debug.print("Child!\n", .{});
        _ = linux.close(pipes[1]);

        var ch: [1]u8 = undefined;
        _ = linux.read(pipes[0], &ch, 1);
        _ = linux.close(pipes[0]);

        std.debug.print("Child ready to execute!\n", .{});

        // TODO: Take this seriously ;)
        var argv = try init.gpa.allocSentinel(?[*:0]const u8, 1, null);
        argv[0] = "./test";

        const env = try init.gpa.allocSentinel(?[*:0]const u8, 0, null);

        _ = linux.execve("./test", argv, env);
        return;
    } 

    std.debug.print("Forked at {}!\n", .{pid});

    // TODO: With clone I think there is an option to get the fd immediately
    const childfd = try openPid(pid);

    _ = linux.close(pipes[0]);

    var perf_attr = linux.perf_event_attr{
        .type = .HARDWARE,
        .config = 0, // PERF_COUNT_HW_CPU_CYCLES
        .sample_period_or_freq = 4000,
        .sample_type = linux.PERF.SAMPLE.IP | linux.PERF.SAMPLE.TID | linux.PERF.SAMPLE.TIME | linux.PERF.SAMPLE.CALLCHAIN,

        .flags = .{
            .disabled = true,
            .inherit = true,
            .exclude_kernel = true,
            .exclude_hv = true,
            .freq = true,
            .precise_ip = 0, // TODO: Is 2 ok? :)
            .enable_on_exec = true,
        }
    };

    const numCpus = try std.Thread.getCpuCount();

    const samplers = try init.gpa.alloc(PerfSampler, numCpus);
    defer init.gpa.free(samplers);

    // TODO: Error checking
    const epoll_fd: i32 = @intCast(linux.epoll_create1(0));
    var epoll_event: linux.epoll_event = .{
        .events = linux.EPOLL.IN,
        .data = .{
            .fd = childfd
        }
    };
    _ = linux.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, childfd, &epoll_event);

    const page_size = std.heap.pageSize();

    // Must be a power of 2 multiple of the page size
    const ring_buffer_size = page_size * 128;

    // One extra page is needed for the metadata (head, tail)
    const mmap_size = ring_buffer_size + page_size;

    for (samplers, 0..) |*sampler, cpu| {
        sampler.cpu = cpu;
        sampler.fd = try std.posix.perf_event_open(&perf_attr, pid, @intCast(cpu), -1, 0);
        sampler.buffer = try std.posix.mmap(null, mmap_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, sampler.fd, 0);
        sampler.page_size = page_size;
        sampler.ring_buffer_size = ring_buffer_size;

        var perf_epoll_event: linux.epoll_event = .{
            .events = linux.EPOLL.IN,
            .data = .{
                .fd = sampler.fd
            }
        };
        _ = linux.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, sampler.fd, &perf_epoll_event);
    }


    // Signal child to continue with execve
    _ = linux.close(pipes[1]);


    var samples = Samples{};
    defer samples.deinit(init.gpa);

    var mapped_regions: ?procmaps.MappedRegions = null;
    defer if (mapped_regions) |*regions| regions.deinit(init.gpa);

    var events: [128]linux.epoll_event = undefined;
    outer: while (true) {
        const nfds = linux.epoll_wait(epoll_fd, &events, events.len, -1);

        for (0 .. nfds) |i| {
            if (events[i].data.fd == childfd) {
                std.debug.print("Process {} has terminated\n", .{pid});
                break :outer;
            } else {
                if (mapped_regions == null) {
                    // TODO: Remove this debug output
                    // TODO: Attach region information to the samples
                    mapped_regions = try procmaps.readExecutableRegions(init.io, init.gpa, pid);
                }

                // Before the process closes epoll triggers all of the events 
                // TODO: Find documentation for that
                for (samplers) |sampler| {
                    if (sampler.fd == events[i].data.fd) {
                        try recordSamples(sampler, &samples, init.gpa);
                    }
                }
            }
        }
    }

    var regions: std.ArrayList(ExecutableRegion) = .empty;
    defer regions.deinit(init.gpa);
    defer for (regions.items) |*region| region.deinit(init.io, init.gpa);

    if (mapped_regions) |mapped| {
        for (mapped.regions) |region| {
            std.debug.print("Loading elf: {s}\n", .{ region.file_name });
            var executable_region = ExecutableRegion{
                .start = region.start,
                .end = region.end,
                .file_name = region.file_name,
                .offset = region.offset,
            };
            if (region.file_name[0] == '/') {
                if (std.Io.Dir.openFileAbsolute(init.io, region.file_name, .{})) |elf_file| {
                    executable_region.elf_file = elf_file;

                    // TODO: Figure out what is actually needed 
                    // TODO: What is the nullable build id parameter?
                    const search_paths = std.debug.ElfFile.DebugInfoSearchPaths.none;
                    const elf = try std.debug.ElfFile.load(init.gpa, init.io, elf_file, null, &search_paths);

                    executable_region.elf = elf;
                    executable_region.dwarf = elf.dwarf;
                    if (executable_region.dwarf) |*dwarf| {
                        try dwarf.open(init.gpa, .native);
                        std.debug.print("Got dwarf file for: {s}\n", .{ region.file_name });
                    }
                } else |_| {
                    std.debug.print("Failed to load elf file: {s}\n", .{ region.file_name });
                }
            }
            try regions.append(init.gpa, executable_region);

        }
    }

    var cwd = std.Io.Dir.cwd();
    var outFile = try cwd.createFile(init.io, "./samples.txt", .{});

    
    var outbuffer: [4096 * 4]u8 = undefined;
    var fwriter = outFile.writer(init.io, &outbuffer);
    var writer = &fwriter.interface;

    var ip_ix: usize = 0;
    for (samples.samples.items) |sample| {
        try writer.print("{},{},{}\n", .{ sample.cpu, sample.tid, sample.time_ns });
        for (0 .. sample.cc_len) |i| {
            const ip = samples.ips.items[ip_ix];
            if (lookupAddress(regions.items, ip)) |region| {
                const offset = region.offset + ip - region.start;
                const symbol_name = if (region.dwarf) |dwarf| dwarf.getSymbolName(offset) else null;

                if (region.dwarf) |_| {
                    const sym = if (region.dwarf) |dwarf| dwarf.getSymbolName(offset) else null;
                    std.debug.print("Symbol name: {?s}\n", .{ sym });
                }

                if (symbol_name) |name| {
                    try writer.print("  {}: {s}:{s}\n", .{ i, region.file_name, name });
                } else {
                    try writer.print("  {}: {s}@{x}\n", .{ i, region.file_name, offset });
                }
            } else {
                try writer.print("  {}: {x}\n", .{ i, ip });
            }
            ip_ix += 1;
        }
        try writer.print("\n", .{});
    }


    const memory_usage = samples.samples.items.len * @sizeOf(Sample) + samples.ips.items.len * 8;
    std.debug.print("Storing {} samples takes {} bytes\n", .{ samples.samples.items.len, memory_usage });

    // TODO: Configure watermark to get woken up? Seems to do it automatically
    try writer.flush();
    outFile.close(init.io);    
}
