const std = @import("std");

pub const HandlerFn = *const fn (Connection) anyerror!HandleResult;

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

    pub fn cancel(self:Connection) HandleResult {
        if (self.stream.shutdown(self.io, .both)) |_|
            self.stream.close(self.io)
        else |_| {} // TODO: should I handle this?
        return .{ .closed = true };
    }
};

pub const KVPair = struct{ key:[]const u8, value:[]const u8 };

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
