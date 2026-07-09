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

    pub const SendHeaderMapError = error{OutOfMemory} || SendHeadersError;
    pub fn sendHeadersMap(self:Connection, headers:[]const [2][]const u8) SendHeaderMapError!void {
        try self.sendHeaders(try .fromMap(self.alloc, headers));
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
        try self.stream.close(self.io, .both);
        self.stream.close(self.io);
        return .{ .closed = true };
    }
};

pub const KVPair = struct{ key:[]const u8, value:[]const u8 };

// TODO: iterator (?)
pub const Headers = struct {
    pairs:[]const KVPair,

    // NOTE: the resulting keys and values are still owned by the provided map
    //  (the KVPair slice is allocated, however)
    pub fn fromMap(alloc:Allocator, map:[]const [2][]const u8) error{OutOfMemory}!Headers {
        const res = try alloc.alloc(KVPair, map.len);
        for (map, 0..) |pair, i|
            res[i] = .{ .key = pair[0], .value = pair[1] };
        return .{ .pairs = res };
    }

    pub fn fromMapFast(comptime len:usize, map:[len][2][]const u8) Headers {
        var res:[len]KVPair = undefined;
        inline for (map, 0..) |pair, i|
            res[i] = .{ .key = pair[0], .value = pair[1] };
        return .{ .pairs = res[0..] };
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
