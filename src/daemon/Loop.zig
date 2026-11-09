//! An event loop: register fds, signals and timers once, then wait for
//! whichever is ready. Each watch carries a token that comes back with its
//! events.

const std = @import("std");
const fd_t = std.posix.fd_t;

const Loop = @This();

const Backend = @import("KqueueLoop.zig");

backend: Backend,

pub const Event = struct {
    token: usize,
    kind: Kind,
    /// The other end hung up. There may still be bytes to read first.
    eof: bool,

    pub const Kind = enum { read, signal, timer };
};

pub fn init() !Loop {
    return .{ .backend = try .init() };
}

/// Restores the old signal actions, then closes everything the loop opened.
pub fn deinit(self: *Loop) void {
    self.backend.deinit();
    self.* = undefined;
}

/// Watches `fd` for reading. Adding it again replaces the token.
pub fn addRead(self: *const Loop, fd: fd_t, token: usize) !void {
    try self.backend.addRead(fd, token);
}

/// Stops watching `fd`. Not needed before closing it.
pub fn remove(self: *const Loop, fd: fd_t) !void {
    try self.backend.remove(fd);
}

/// Watches `sig`, and keeps its default action from running.
pub fn addSignal(self: *Loop, sig: std.c.SIG, token: usize) !void {
    try self.backend.addSignal(sig, token);
}

/// Fires once, `ms` milliseconds from now. Adding timer `id` again
/// restarts it.
pub fn addTimer(self: *const Loop, id: usize, ms: u32, token: usize) !void {
    try self.backend.addTimer(id, ms, token);
}

/// Blocks until something is ready, then fills the start of `buf`.
pub fn wait(self: *const Loop, buf: []Event) ![]Event {
    return self.backend.wait(buf);
}

const testing = std.testing;

fn pipe() ![2]fd_t {
    var p: [2]fd_t = undefined;
    if (std.c.pipe(&p) != 0) return error.Pipe;
    return p;
}

test "a readable pipe, then its hang-up" {
    var loop: Loop = try .init();
    defer loop.deinit();
    const p = try pipe();
    defer _ = std.c.close(p[0]);
    try loop.addRead(p[0], 7);

    _ = std.c.write(p[1], "x", 1);
    var buf: [4]Event = undefined;
    try testing.expectEqualSlices(Event, &.{.{ .token = 7, .kind = .read, .eof = false }}, try loop.wait(&buf));

    _ = std.c.close(p[1]);
    try testing.expectEqualSlices(Event, &.{.{ .token = 7, .kind = .read, .eof = true }}, try loop.wait(&buf));
}

test "only ready fds are reported; removed ones aren't" {
    var loop: Loop = try .init();
    defer loop.deinit();
    const a = try pipe();
    const b = try pipe();
    defer for (a ++ b) |fd| {
        _ = std.c.close(fd);
    };
    try loop.addRead(a[0], 1);
    try loop.addRead(b[0], 2);
    try loop.remove(a[0]);

    _ = std.c.write(a[1], "x", 1);
    _ = std.c.write(b[1], "x", 1);
    var buf: [4]Event = undefined;
    try testing.expectEqualSlices(Event, &.{.{ .token = 2, .kind = .read, .eof = false }}, try loop.wait(&buf));
}

test "signals arrive as events and the old action comes back" {
    var loop: Loop = try .init();
    try loop.addSignal(.USR1, 9);
    // the whole process: raise only signals this thread, which kqueue misses
    _ = std.c.kill(std.c.getpid(), .USR1);
    var buf: [4]Event = undefined;
    try testing.expectEqualSlices(Event, &.{.{ .token = 9, .kind = .signal, .eof = false }}, try loop.wait(&buf));

    loop.deinit();
    var now: std.c.Sigaction = undefined;
    std.posix.sigaction(.USR1, null, &now);
    try testing.expect(now.handler.handler != std.c.SIG.IGN);
}

test "a timer fires once" {
    var loop: Loop = try .init();
    defer loop.deinit();
    try loop.addTimer(1, 5, 11);
    var buf: [4]Event = undefined;
    try testing.expectEqualSlices(Event, &.{.{ .token = 11, .kind = .timer, .eof = false }}, try loop.wait(&buf));
}
