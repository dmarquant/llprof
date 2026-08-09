const std = @import("std");
const linux = std.os.linux;


const PerfSampler = struct {
    cpu: u64,
    fd: std.posix.fd_t,
    buffer: []u8
};

fn openPid(pid: i32) !std.posix.fd_t {
    const rc = linux.pidfd_open(pid, 0);
    if (linux.errno(rc) == .SUCCESS) {
        return @intCast(rc);
    } else {
        return error.PidfOpenFailed;
    }
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

        var argv = try init.gpa.allocSentinel(?[*:0]const u8, 1, null);
        argv[0] = "./test";

        const env = try init.gpa.allocSentinel(?[*:0]const u8, 0, null);

        _ = linux.execve("./test", argv, env);
        return;
    } 

    std.debug.print("Forked at {}!\n", .{pid});

    const childfd = try openPid(pid);

    _ = linux.close(pipes[0]);
    try init.io.sleep(std.Io.Duration.fromMilliseconds(200), .real);


    var perf_attr = linux.perf_event_attr{
        .type = .HARDWARE,
        .config = 0, // PERF_COUNT_HW_CPU_CYCLES
        .sample_period_or_freq = 4000,
        .sample_type = linux.PERF.SAMPLE.IP,

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


    for (samplers, 0..) |*sampler, cpu| {
        sampler.cpu = cpu;
        sampler.fd = try std.posix.perf_event_open(&perf_attr, pid, @intCast(cpu), -1, 0);
        sampler.buffer = try std.posix.mmap(null, 528384, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, sampler.fd, 0);

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


    var events: [128]linux.epoll_event = undefined;
    outer: while (true) {
        const nfds = linux.epoll_wait(epoll_fd, &events, events.len, -1);

        for (0 .. nfds) |i| {
            if (events[i].data.fd == childfd) {
                std.debug.print("Process {} has terminated\n", .{pid});

                var buf: [4096]u8 = undefined;
                var stdin_reader = std.Io.File.stdin().reader(init.io, &buf);
                const r = &stdin_reader.interface;
                _ = try r.takeByte();

                break :outer;
            } else {
                for (samplers) |sampler| {
                    if (sampler.fd == events[i].data.fd) {
                        // TODO: put this in a function :)
                        var metadata = std.mem.bytesAsValue(linux.perf_event_mmap_page, sampler.buffer[0 .. @sizeOf(linux.perf_event_mmap_page)]);
                        const sampledata = sampler.buffer[4096 .. ];
                
                        std.debug.print("Woken up to write samples. {} bytes available\n", .{
                            metadata.data_head - metadata.data_tail
                        });

                        var tail = metadata.data_tail;
                        while (tail < metadata.data_head) {
                            // TODO: Properly setup this frame size
                            const readp = tail % (528384 - 4096);
                            const header = std.mem.bytesToValue(linux.perf_event_header, sampledata[readp .. readp + @sizeOf(linux.perf_event_header)]);
                            const ip = std.mem.bytesToValue(u64, sampledata[readp + @sizeOf(linux.perf_event_header) .. readp + header.size]);

                            // TODO: write to file
                            _ = ip;
                            //std.debug.print("IP {x}\n", .{ ip });


                            tail += header.size;
                        }
                        metadata.data_tail = tail;
                    }
                }
            }
        }
    }

    // TODO: Get the actual page size
    // TODO: Configure watermark to get woken up? Seems to do it automatically
    for (samplers) |sampler| {
        const metadata = std.mem.bytesToValue(linux.perf_event_mmap_page, sampler.buffer[0 .. @sizeOf(linux.perf_event_mmap_page)]);

        std.debug.print("Have {} bytes of samples for CPU {}\n", .{ metadata.data_head - metadata.data_tail, sampler.cpu });

        const sampledata = sampler.buffer[4096 .. ];

        var tail = metadata.data_tail;
        while (tail < metadata.data_head) {
            // TODO: Properly setup this frame size
            const readp = tail % (528384 - 4096);
            const header = std.mem.bytesToValue(linux.perf_event_header, sampledata[readp .. readp + @sizeOf(linux.perf_event_header)]);
            const ip = std.mem.bytesToValue(u64, sampledata[readp + @sizeOf(linux.perf_event_header) .. readp + header.size]);

            // TODO: write to file
            _ = ip;
            //std.debug.print("IP {x}\n", .{ ip });


            tail += header.size;
        }

    }
    
}
