const std = @import("std");
const http = @import("zig_http");

const types = http.types;

const Server = http.Server;
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
    const info = conn.parsed;
    const log = conn.log;

    log.request("recieved request", .{});

    var render_buf:std.Io.Writer.Allocating = .init(conn.alloc);
    defer render_buf.deinit();

    try render_buf.writer.print(
        \\.{{
        \\    .method = .{t},
        \\    .page = "{s}",
        \\    .version = .{{
        \\        .is_https = {},
        \\        .num = .{any},
        \\    }},
        \\    .headers = .{{
    ++ "\n", .{
        info.method,
        info.page,
        info.version.is_https,
        info.version.num,
    });

    var header_itr = info.headers.iterator();
    while (header_itr.next()) |header|
        try render_buf.writer.print(
            "        .{{ .key = \"{s}\", .value = \"{s}\" }},\n",
            .{ header.key_ptr.*, header.value_ptr.* },
        );

    try render_buf.writer.print(
        \\    }},
        \\    .params = .{{
    ++ "\n", .{});

    var param_itr = info.params.iterator();
    while (param_itr.next()) |p|
        try render_buf.writer.print(
            "        .{{ .key = \"{s}\", .value = \"{s}\" }},\n",
            .{ p.key_ptr.*, p.value_ptr.* }
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
