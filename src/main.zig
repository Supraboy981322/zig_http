const std = @import("std");
const module = @import("module.zig");

const types = module.types;

const Server = module.Server;
const Connection = types.Connection;
const HandleResult = types.HandleResult;

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
    const headers = conn.headers;
    const log = conn.log;

    log.request("recieved request", .{});

    var render_buf:std.Io.Writer.Allocating = .init(conn.alloc);
    defer render_buf.deinit();

    try render_buf.writer.print(
        \\.{{
        \\    .method = {t},
        \\    .page = {s},
        \\    .version = .{{
        \\        .is_https = {},
        \\        .num = .{any},
        \\    }},
        \\    .headers = &.{{
    ++ "\n", .{
        headers.method,
        headers.page,
        headers.version.is_https,
        headers.version.num,
    });
    for (headers.headers) |header| try render_buf.writer.print(
        "        .{{ .key = \"{s}\", .value = \"{s}\" }},\n",
        .{ header.key, header.value },
    );
    try render_buf.writer.print("    }},\n}};\n", .{});


    const rendered_len = render_buf.written().len;
    try render_buf.writer.print("{d}", .{rendered_len});
    const res = render_buf.written();
    const len_str = res[rendered_len..];
    const rendered = res[0..rendered_len];
    var content:std.Io.Reader = .fixed(rendered);

    try conn.beginResponse(.ok, .fromMap(.{
        .{ "Content-Length", len_str },
    }));
    
    _ = try content.streamRemaining(&conn.writer.interface);
    try conn.writer.interface.flush();

    return .done(.{});
}
