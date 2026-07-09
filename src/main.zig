const std = @import("std");
const module = @import("module.zig");

const types = module.types;

const Server = module.Server;
const Connection = types.Connection;
const HandleResult = types.HandleResult;

pub fn main(init:std.process.Init) !u8 {
    const addr:std.Io.net.IpAddress = try .parse("::1", 3289);
    var server:Server = try .init(init.io, init.gpa, &addr, &handler);

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

pub fn handler(conn:Connection) !HandleResult {
    const stream = conn.stream;
    const headers = conn.headers;

    var writer_buf:[1024]u8 = undefined;
    var writer = stream.writer(conn.io, &writer_buf);

    try writer.interface.print(
        \\HTTP/1.1 200 OK
        \\
        \\.{{
        \\    .method = {t},
        \\    .page = {s},
        \\    .version = .{{
        \\        .s = {},
        \\        .num = .{any},
        \\    }},
        \\    .headers = &.{{
    ++ "\n", .{
        headers.method,
        headers.page,
        headers.version.is_https,
        headers.version.num,
    });

    for (headers.headers) |header| try writer.interface.print(
        "        .{{ .key = \"{s}\", .value = \"{s}\" }},\n",
        .{ header.key, header.value }
    );

    try writer.interface.print("    }},\n}};\n", .{});
    try writer.interface.flush();

    return .done(.{});
}
