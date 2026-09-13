const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");

const tardy = @import("root.zig");

test "tardy unit tests" {
    // Core
    _ = tardy.core.atomic.SpscRing;
    _ = tardy.core.pool;
    _ = tardy.core.Ring;
    _ = tardy.core.ZeroCopy;

    // Runtime
    _ = tardy.Runtime.Storage;
}

const CancelAcceptParams = struct {
    socket: *const tardy.net.Socket,
    accept_canceled: usize = 0,
    cancel_count: usize = 0,
};

fn waitForAccept(rt: *tardy.Runtime, params: *CancelAcceptParams) !void {
    _ = params.socket.accept(rt) catch |err| switch (err) {
        error.Canceled => {
            params.accept_canceled += 1;
            return;
        },
        else => return err,
    };
    return error.AcceptWasNotCanceled;
}

fn cancelAccept(rt: *tardy.Runtime, params: *CancelAcceptParams) !void {
    params.cancel_count = try params.socket.cancelAccepts(rt);
}

fn testCancelAccepts(comptime backend: tardy.AsyncIO.Kind, port: u16) !void {
    const Tardy = tardy.Tardy(backend);

    var socket: tardy.net.Socket = try .init(.{
        .tcp = .{ .host = "127.0.0.1", .port = port },
    });
    defer socket.close_blocking();
    try socket.bind();
    try socket.listen(1);

    var params: CancelAcceptParams = .{ .socket = &socket };
    var td: Tardy = try .init(testing.allocator, testing.io, .{
        .threading = .single,
    });
    defer td.deinit();

    try td.entry(&params, struct {
        fn start(rt: *tardy.Runtime, state: *CancelAcceptParams) !void {
            for (0..3) |_| {
                try rt.spawn(waitForAccept, .{ rt, state }, .@"64KiB");
            }
            try rt.spawn(cancelAccept, .{ rt, state }, .@"64KiB");
        }
    }.start);

    try testing.expectEqual(@as(usize, 3), params.accept_canceled);
    try testing.expectEqual(@as(usize, 3), params.cancel_count);
}

test "Socket.cancelAccepts wakes pending accept" {
    switch (builtin.os.tag) {
        .linux => {
            try testCancelAccepts(.io_uring, 38431);
            try testCancelAccepts(.epoll, 38432);
            try testCancelAccepts(.poll, 38433);
        },
        .ios, .macos, .watchos, .tvos, .visionos => {
            try testCancelAccepts(.kqueue, 38431);
            try testCancelAccepts(.poll, 38432);
        },
        else => try testCancelAccepts(.poll, 38431),
    }
}

const QueuedAcceptParams = struct {
    listener: *const tardy.net.Socket,
    port: u16,
    accepted: usize = 0,
};

fn acceptOne(rt: *tardy.Runtime, params: *QueuedAcceptParams) !void {
    const client = try params.listener.accept(rt);
    defer client.close_blocking();
    params.accepted += 1;
}

fn connectThree(rt: *tardy.Runtime, params: *QueuedAcceptParams) !void {
    for (0..3) |_| {
        const client: tardy.net.Socket = try .init(.{
            .tcp = .{
                .host = "127.0.0.1",
                .port = params.port,
                .mode = .client,
            },
        });
        defer client.close_blocking();
        try client.connect(rt);
    }
}

fn testQueuedAccepts(comptime backend: tardy.AsyncIO.Kind, port: u16) !void {
    const Tardy = tardy.Tardy(backend);

    var listener: tardy.net.Socket = try .init(.{
        .tcp = .{ .host = "127.0.0.1", .port = port },
    });
    defer listener.close_blocking();
    try listener.bind();
    try listener.listen(3);

    var params: QueuedAcceptParams = .{
        .listener = &listener,
        .port = port,
    };
    var td: Tardy = try .init(testing.allocator, testing.io, .{
        .threading = .single,
    });
    defer td.deinit();

    try td.entry(&params, struct {
        fn start(rt: *tardy.Runtime, state: *QueuedAcceptParams) !void {
            for (0..3) |_| {
                try rt.spawn(acceptOne, .{ rt, state }, .@"64KiB");
            }
            try rt.spawn(connectThree, .{ rt, state }, .@"64KiB");
        }
    }.start);

    try testing.expectEqual(@as(usize, 3), params.accepted);
}

test "Socket accepts multiple queued connections" {
    switch (builtin.os.tag) {
        .linux => {
            try testQueuedAccepts(.io_uring, 38441);
            try testQueuedAccepts(.epoll, 38442);
            try testQueuedAccepts(.poll, 38443);
        },
        .ios, .macos, .watchos, .tvos, .visionos => {
            try testQueuedAccepts(.kqueue, 38441);
            try testQueuedAccepts(.poll, 38442);
        },
        else => try testQueuedAccepts(.poll, 38441),
    }
}
