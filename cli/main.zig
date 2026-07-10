const std = @import("std");
const http = @import("zig_http");

const types = http.types;
const assert = std.debug.assert;

const Server = http.Server;
const Log = types.Log;
const Connection = types.Connection;
const Headers = types.Headers;
const HandleResult = types.HandleResult;

var filename:?[]const u8 = null;

pub fn main(init:std.process.Init) !u8 {
    const alloc = init.gpa;
    const args = init.minimal.args.vector;

    const log:Log = .default;

    if (args.len > 1) {
        // TODO: other args
        filename = blk: {
            const c_str = std.mem.span(args[1]);
            break :blk try alloc.dupe(u8, c_str);
        };
        log.info("serving file: {s}", .{filename.?});
    }
    defer if (filename) |name| alloc.free(name);

    const addr:std.Io.net.IpAddress = try .parse("::1", 3289);
    var server:Server = try .init(init.io, init.gpa, &addr, &handler, log);

    switch (server.listen()) {
        .ok => |why| std.log.info(
            "server stopped with reason: {t}", .{why}
        ),
        .err => |err| std.log.err(
            "server stopped with error ({t}): {s}",
            .{ err.err, err.msg orelse "[no message]"}
        ),
        .fatal => |info| std.debug.panic(
            "server halted fatally ({t}): {?s}",
            .{info.err, info.msg}
        ),
    }

    return 0;
}

pub fn handler(conn:*Connection) !HandleResult {
    const log = conn.log;

    log.request("recieved request", .{});

    const requested_page = conn.getPage() orelse "/index.html"; // TODO: arg to set default page
    var given_file = if (filename) |f| f else requested_page;
    if (given_file[0] == '/') given_file = given_file[1..];

    var file = std.Io.Dir.cwd().openFile(
        conn.io, given_file, .{ .mode = .read_only }
    ) catch |err| {
        log.err("failed to open file ({t}): {s}", .{err, given_file});
        const status = http.helpers.fileErrorToStatus(err);
        return try conn.sendStringClosing(status.msg, .{ .status = status.code });
    };
    defer file.close(conn.io);

    const len = try file.length(conn.io);
    const len_str = blk: {
        var buf:[20]u8 = undefined; //len of maxInt(u64)
        // TODO: still probably a more efficient to do this
        const end = std.fmt.printInt(&buf, len, 10, .lower, .{});
        break :blk buf[0..end];
    };

    var file_buf:[1024]u8 = undefined;
    var reader = file.reader(conn.io, &file_buf);

    try conn.beginResponse(.ok, .fromMap(.{
        .{ "Content-Length", len_str },
    }));

    _ = try reader.interface.streamRemaining(&conn.writer.interface);
    try conn.writer.interface.flush();

    return .done(.{});
}
