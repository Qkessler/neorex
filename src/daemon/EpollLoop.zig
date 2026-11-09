//! The epoll backend of Loop, for Linux. Signals arrive through a
//! self-pipe and each timer is a timerfd, so one epoll fd waits on all of
//! them. The signal handler needs a global, so only one loop at a time.

const std = @import("std");
const linux = std.os.linux;
const fd_t = std.posix.fd_t;
const Event = @import("Loop.zig").Event;

const EpollLoop = @This();

/// Timer ids index a table, so they stay below this.
pub const max_timers = 64;
const max_ready = 64;
const source_shift = 62;
const payload_mask = (@as(u64, 1) << source_shift) - 1;

/// What an epoll entry's data stands for.
const Source = enum(u2) { read, signal_pipe, timer };

const WatchedSignal = struct {
    token: usize,
    /// The action before addSignal, restored on deinit.
    old_action: std.posix.Sigaction,
};

const Timer = struct {
    fd: fd_t,
    token: usize,
};

epoll: fd_t,
/// The handler writes each signal's number to the write end.
signal_pipe: [2]fd_t,
signals: [linux.NSIG]?WatchedSignal,
timers: [max_timers]?Timer,

var signal_pipe_write_end: fd_t = -1;

pub fn init() !EpollLoop {
    std.debug.assert(signal_pipe_write_end == -1);
    const epoll_rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
    if (linux.errno(epoll_rc) != .SUCCESS) return error.EpollCreateFailed;
    const epoll: fd_t = @intCast(epoll_rc);
    errdefer _ = linux.close(epoll);

    var signal_pipe: [2]fd_t = undefined;
    if (linux.errno(linux.pipe2(&signal_pipe, .{ .CLOEXEC = true, .NONBLOCK = true })) != .SUCCESS) {
        return error.PipeFailed;
    }
    errdefer for (signal_pipe) |end| {
        _ = linux.close(end);
    };

    const self: EpollLoop = .{
        .epoll = epoll,
        .signal_pipe = signal_pipe,
        .signals = @splat(null),
        .timers = @splat(null),
    };
    try self.watch(linux.EPOLL.CTL_ADD, signal_pipe[0], .signal_pipe, 0);
    signal_pipe_write_end = signal_pipe[1];
    return self;
}

/// Restores the old signal actions, then closes every fd the loop opened.
pub fn deinit(self: *EpollLoop) void {
    for (self.signals, 0..) |maybe_signal, number| {
        if (maybe_signal) |signal| {
            std.posix.sigaction(@fromBackingInt(@intCast(number)), &signal.old_action, null);
        }
    }
    signal_pipe_write_end = -1;
    for (self.timers) |maybe_timer| {
        if (maybe_timer) |timer| _ = linux.close(timer.fd);
    }
    for (self.signal_pipe) |end| _ = linux.close(end);
    _ = linux.close(self.epoll);
    self.* = undefined;
}

/// Watches `fd` for reading. Adding it again replaces the token.
pub fn addRead(self: *const EpollLoop, fd: fd_t, token: usize) !void {
    self.watch(linux.EPOLL.CTL_ADD, fd, .read, token) catch |err| switch (err) {
        error.AlreadyWatched => try self.watch(linux.EPOLL.CTL_MOD, fd, .read, token),
        else => return err,
    };
}

/// Stops watching `fd`. epoll keeps watching until every copy of the open
/// file closes, so call this before closing an fd another process holds.
pub fn remove(self: *const EpollLoop, fd: fd_t) !void {
    if (linux.errno(linux.epoll_ctl(self.epoll, linux.EPOLL.CTL_DEL, fd, null)) != .SUCCESS) {
        return error.EpollCtlFailed;
    }
}

/// Watches `sig` with a handler that forwards it to the signal pipe, so its
/// default action never runs.
pub fn addSignal(self: *EpollLoop, sig: std.c.SIG, token: usize) !void {
    const number: usize = @intCast(@backingInt(sig));
    const old_action = if (self.signals[number]) |signal| signal.old_action else saved: {
        var action: std.posix.Sigaction = undefined;
        std.posix.sigaction(sig, null, &action);
        break :saved action;
    };
    self.signals[number] = .{ .token = token, .old_action = old_action };
    const forward: std.posix.Sigaction = .{
        .handler = .{ .handler = forwardSignal },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };
    std.posix.sigaction(sig, &forward, null);
}

/// Fires once, `ms` milliseconds from now. Adding timer `id` again
/// restarts it.
pub fn addTimer(self: *EpollLoop, id: usize, ms: u32, token: usize) !void {
    if (id >= max_timers) return error.TimerIdTooLarge;
    const timer = if (self.timers[id]) |existing| existing.fd else try self.createTimer(id);
    self.timers[id].?.token = token;

    const nanoseconds = @max(@as(u64, ms) * std.time.ns_per_ms, 1);
    const once: linux.itimerspec = .{
        .it_interval = .{ .sec = 0, .nsec = 0 },
        .it_value = .{
            .sec = @intCast(nanoseconds / std.time.ns_per_s),
            .nsec = @intCast(nanoseconds % std.time.ns_per_s),
        },
    };
    if (linux.errno(linux.timerfd_settime(timer, .{}, &once, null)) != .SUCCESS) {
        return error.TimerfdSettimeFailed;
    }
}

/// Blocks until something is ready, then fills the start of `buf`. A
/// pending signal can stand for several events, so what doesn't fit waits
/// for the next call.
pub fn wait(self: *const EpollLoop, buf: []Event) ![]Event {
    var ready: [max_ready]linux.epoll_event = undefined;
    const max: u32 = @intCast(@min(buf.len, ready.len));
    const ready_count: usize = while (true) {
        const rc = linux.epoll_wait(self.epoll, &ready, max, -1);
        switch (linux.errno(rc)) {
            .SUCCESS => break rc,
            .INTR => continue,
            else => return error.EpollWaitFailed,
        }
    };

    var filled: usize = 0;
    for (ready[0..ready_count]) |entry| {
        if (filled == buf.len) break;
        const payload: usize = @intCast(entry.data.u64 & payload_mask);
        switch (@as(Source, @fromBackingInt(@intCast(entry.data.u64 >> source_shift)))) {
            .read => {
                const hung_up = linux.EPOLL.HUP | linux.EPOLL.RDHUP | linux.EPOLL.ERR;
                buf[filled] = .{ .token = payload, .kind = .read, .eof = entry.events & hung_up != 0 };
                filled += 1;
            },
            .timer => {
                const timer = self.timers[payload].?;
                var expirations: u64 = undefined;
                _ = linux.read(timer.fd, @ptrCast(&expirations), @sizeOf(u64));
                buf[filled] = .{ .token = timer.token, .kind = .timer, .eof = false };
                filled += 1;
            },
            .signal_pipe => filled += self.readSignals(buf[filled..]),
        }
    }
    return buf[0..filled];
}

/// Turns up to `out.len` signal numbers from the pipe into events.
fn readSignals(self: *const EpollLoop, out: []Event) usize {
    var numbers: [max_ready]u8 = undefined;
    const rc = linux.read(self.signal_pipe[0], &numbers, @min(numbers.len, out.len));
    if (linux.errno(rc) != .SUCCESS) return 0;
    var filled: usize = 0;
    for (numbers[0..rc]) |number| {
        const signal = self.signals[number] orelse continue;
        out[filled] = .{ .token = signal.token, .kind = .signal, .eof = false };
        filled += 1;
    }
    return filled;
}

fn createTimer(self: *EpollLoop, id: usize) !fd_t {
    const rc = linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true, .NONBLOCK = true });
    if (linux.errno(rc) != .SUCCESS) return error.TimerfdCreateFailed;
    const fd: fd_t = @intCast(rc);
    errdefer _ = linux.close(fd);
    try self.watch(linux.EPOLL.CTL_ADD, fd, .timer, id);
    self.timers[id] = .{ .fd = fd, .token = 0 };
    return fd;
}

fn forwardSignal(sig: std.c.SIG) callconv(.c) void {
    const number: u8 = @intCast(@backingInt(sig));
    _ = linux.write(signal_pipe_write_end, &[_]u8{number}, 1);
}

/// Adds or changes the entry for `fd`, tagged with what it stands for.
fn watch(self: *const EpollLoop, operation: u32, fd: fd_t, source: Source, payload: usize) !void {
    std.debug.assert(payload <= payload_mask);
    var entry: linux.epoll_event = .{
        .events = linux.EPOLL.IN | linux.EPOLL.RDHUP,
        .data = .{ .u64 = (@as(u64, @backingInt(source)) << source_shift) | payload },
    };
    switch (linux.errno(linux.epoll_ctl(self.epoll, operation, fd, &entry))) {
        .SUCCESS => {},
        .EXIST => return error.AlreadyWatched,
        else => return error.EpollCtlFailed,
    }
}
