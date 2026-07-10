const std = @import("std");

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Status = std.http.Status;

pub const HandlerFn = *const fn (*Connection) anyerror!HandleResult;

pub const HandleResult = struct {
    closed:bool = false,

    pub const DoneOpts = struct {}; // TODO

    pub fn done(_:DoneOpts) HandleResult {
        return .{};
    }
};

pub const Connection = struct {
    stream:std.Io.net.Stream,
    alloc:std.mem.Allocator,
    headers:ParsedHeader,
    io:std.Io,
    comptime log:Log = .default,
    status_sent:bool = false,
    writer:*std.Io.net.Stream.Writer,
    reader:*std.Io.net.Stream.Reader,

    // WARNING: do not 'Connection.cancel(...)' *and* 'Connection.endResponse(...)'
    pub fn cancel(self:Connection) HandleResult {
        self.stream.shutdown(self.io, .both) catch {
            return .{ .closed = true };
        };
        self.stream.close(self.io);
        return .{ .closed = true };
    }

    pub const SendStatusError = error{UnknownStatus} || std.Io.Writer.Error;
    pub fn sendStatusLine(self:*Connection, status:Status) SendStatusError!void {
        const name = status.phrase() orelse return error.UnknownStatus;
        const num = @intFromEnum(status);
        try self.writer.interface.print("HTTP/1.1 {d} {s}\r\n", .{num, name});
        try self.writer.interface.flush();
        self.status_sent = true;
    }

    pub const SendHeadersMapError = error{OutOfMemory} || SendHeadersError;
    pub fn sendHeadersSlice(self:Connection, headers:[]const [2][]const u8) SendHeadersMapError!void {
        try self.sendHeaders(try .fromSlice(self.alloc, headers));
    }

    pub const SendHeadersError = std.Io.Writer.Error;
    pub fn sendHeaders(self:Connection, headers:Headers) SendHeadersError!void {
        assert(self.status_sent); //must call sendStatusLine(...) first

        for (headers.pairs) |header|
            try self.writer.interface.print("{s}: {s}\r\n", .{header.key, header.value});

        try self.writer.interface.writeAll("\r\n");
        try self.writer.interface.flush();
    }

    const ResponseError = SendStatusError || SendHeadersError;
    pub fn beginResponse(self:*Connection, status:Status, headers:Headers) ResponseError!void {
        try self.sendStatusLine(status);
        try self.sendHeaders(headers);
    }

    // WARNING: do not 'Connection.cancel(...)' *and* 'Connection.endResponse(...)'
    pub fn endResponse(self:Connection) std.Io.net.ShutdownError!HandleResult {
        try self.stream.shutdown(self.io, .both);
        self.stream.close(self.io);
        return .{ .closed = true };
    }

    pub fn getPage(self:Connection) ?[]const u8 {
        return
            if (std.mem.eql(u8, self.headers.page, "/"))
                null
            else
                self.headers.page;
    }

    pub const SendClosingOpts = struct {
        headers:?Headers = null,
        status:Status = .ok,
    };

    pub fn sendStringClosing(self:*Connection,str:[]const u8, opts:SendClosingOpts) !HandleResult {
        const headers:Headers =
            if (opts.headers) |headers|
                headers
            else blk: {
                assert(str.len <= std.math.maxInt(u64)); // string too long, just stream it
                var buf:[20]u8 = undefined;
                const end = std.fmt.printInt(&buf, str.len, 10, .lower, .{});
                const str_len:[]const u8 = buf[0..end];
                break :blk .fromMap(&.{
                    .{ "Content-Length", str_len }
                });
            };
        try self.beginResponse(opts.status, headers);
        try self.writer.interface.writeAll(str);
        try self.writer.interface.flush();
        return try self.endResponse();
    }

};

pub const StatusInfo = struct{
    code:Status,
    phrase:[]const u8,
    class:Status.Class,
    msg:[]const u8,

    pub const not_found:StatusInfo = .{
        .code = .not_found,
        .phrase = Status.phrase(.not_found).?,
    };

    fn mk_msg(comptime status:Status) []const u8 {
        comptime {
            var code = @intFromEnum(status);
            assert(code >= 100 and code <= 999);
            var buf:[1024]u8 = undefined;
            var i:comptime_int = buf.len;
            while (code >= 100) : (code = @divTrunc(code, 100)) {
                i -= 2;
                buf[i..][0..2].* = std.fmt.digits2(@intCast(code % 100));
            }
            if (code < 10) {
                i -= 1;
                buf[i] = '0' + @as(u8, @intCast(code));
            } else {
                i -= 2;
                buf[i..][0..2].* = std.fmt.digits2(@intCast(code));
            }
            var res:[]const u8 = buf[i..];

            res = res ++ "... (";
            for (@tagName(status)) |b| {
                if (b == '_')
                    res = res ++ " "
                else
                    res = res ++ &[_]u8{b};
            }
            res = res ++ ")\n";
            return res;
        }
    }

    pub fn mk(status:Status) StatusInfo {
        assert(status.phrase() != null); //I'm not putting *that* much effort into this
        switch (status) { inline else => |s| {
            if (s.phrase() == null) unreachable;
            return .{
                .code = s,
                .phrase = comptime s.phrase().?,
                .class = comptime s.class(),
                .msg = comptime mk_msg(s),
            };
        } }
    }
};

pub const KVPair = struct{ key:[]const u8, value:[]const u8 };

// TODO: iterator (?)
pub const Headers = struct {
    pairs:[]const KVPair,

    // NOTE: the resulting keys and values are still owned by the provided map
    //  (the KVPair slice is allocated, however)
    pub fn fromSlice(alloc:Allocator, map:[]const [2][]const u8) error{OutOfMemory}!Headers {
        const res = try alloc.alloc(KVPair, map.len);
        for (map, 0..) |pair, i|
            res[i] = .{ .key = pair[0], .value = pair[1] };
        return .{ .pairs = res };
    }

    //takes an array (or tuple) of (meaning comptime-known length) of string
    //  tuples (two strings each), which is unrolled with keys already in-place
    //    (at comptime) and values are just slotted into place (at runtime)
    //      (meaning the only thing done here at runtime is the values)
    //
    //keys must be comptime known (which's why it's a *map* of headers)
    //
    // NOTE: (for me) if this isn't inlined, it's a segfault
    pub inline fn fromMap(map:anytype) Headers {
        var res:[map.len]KVPair = undefined;
        inline for (map, &res) |p, *r|
            r.* = .{ .key = comptime p[0], .value = p[1] };
        return .{ .pairs = res[0..map.len] };
    }

    pub fn fromMapComptime(map:anytype) Headers {
        comptime {
            var res:[]const KVPair = &.{};
            for (map) |pair|
                res = res ++ &[_]KVPair{ .{ .key = pair[0], .value = pair[1] } };
            return .{ .pairs = res };
        }
    }

    pub fn mk(pairs:[]const KVPair) Headers {
        return .{ .pairs = pairs };
    }
};

pub const Log = struct {
    info:Func,
    debug:Func,
    err:Func,
    warn:Func,
    request:Func,

    pub const Func = *const fn (comptime []const u8, anytype) void;

    // TODO: custom default
    pub const default:Log = .{
        .info = &std.log.info,
        .debug = &std.log.debug,
        .warn = &std.log.warn,
        .err = &std.log.err,
        .request = &std.log.info,
    };
};

pub const ParsedHeader = struct {
    method:Method,
    page:[]const u8,
    version:Version,
    headers:[]const KVPair,

    pub const Version = struct {
        is_https:bool,
        num:[2]u4
    };

    pub const Method = enum {
        GET,
        HEAD,
        POST,
        PUT,
        DELETE,
        CONNECT,
        OPTIONS,
        TRACE,
        PATH,
    };
};

pub const ListenReturn = union(enum(u2)) {
    ok:Ok,
    err:Err,
    fatal:Fatal,

    pub const Ok = enum {
        canceled,
    };
    pub const Err = struct {
        err:Error,
        msg:?[]const u8,
    };
    pub const Fatal = struct {
        err:anyerror,
        msg:?[]const u8,
    };

    pub const Error = error {
        UnsupportedSystem,
        AddressTaken,
        Unexpected,
        BlockedByFirewall,
        AddressUnavailable,
        NetworkDown,
    };

    pub fn fail(e:Error, msg:?[]const u8) ListenReturn {
        return .{ .err = .{ .err = e, .msg = msg } };
    }
    pub fn abort(e:anyerror, comptime msg:?[]const u8) ListenReturn {
        return .{ .fatal = .{
            .err = e,
            .msg = "@import(\"server.zig\").listen(...) -> " ++ (if (msg) |m| m else "[no message provided]")
        } };
    }
    pub fn success(status:Ok) ListenReturn {
        return .{ .ok = status };
    }
};
