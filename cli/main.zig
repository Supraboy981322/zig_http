const std = @import("std");
const http = @import("zig_http");

const types = http.types;
const assert = std.debug.assert;

const Server = http.Server;
const Connection = types.Connection;
const Headers = types.Headers;
const HandleResult = types.HandleResult;

var filename:?[]const u8 = null;

pub fn main(init:std.process.Init) !u8 {
    const addr:std.Io.net.IpAddress = try .parse("::1", 3289);
    var server:Server = try .init(init.io, init.gpa, &addr, &handler, .default);

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
    ) catch |err| switch (err) {
        inline else => |e| {
            log.err("failed to open file ({t}): {s}", .{e, given_file});
            const str = comptime
                if (e == error.FileNotFound)
                    "404... (file not found)\n"
                else // TODO: helper to convert Zig error to HTTP status
                    "500... (er-umm... something's borked)\n";
            const headers:Headers = comptime blk: {
                assert(str.len < 100); //update comptime block
                const str_len:[]const u8 = &std.fmt.digits2(@intCast(str.len));
                break :blk .fromMapComptime(&.{
                    .{ "Content-Length", str_len }
                });
            };
            try conn.beginResponse(.not_found, headers);
            try conn.writer.interface.writeAll(str);
            try conn.writer.interface.flush();
            return try conn.endResponse();
        }
    };
    defer file.close(conn.io);

    const len = try file.length(conn.io);
    var len_buf:[1024]u8 = undefined;
    // TODO: there is 100% a more efficient way to do this
    const len_str = try std.fmt.bufPrint(&len_buf, "{d}", .{len});

    var file_buf:[1024]u8 = undefined;
    var reader = file.reader(conn.io, &file_buf);

    try conn.beginResponse(.ok, .fromMap(.{
        .{ "Content-Length", len_str },
    }));

    _ = try reader.interface.streamRemaining(&conn.writer.interface);
    try conn.writer.interface.flush();

    return .done(.{});
}
