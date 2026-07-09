const std = @import("std");
const types = @import("types.zig");
const hlp = @import("helpers.zig");


io:Io,
alloc:Alloc,
addr:*const IpAddr,
handler:HandlerFn,


const Server = @This();

const startsWith = std.mem.startsWith;
const stringToEnum = std.meta.stringToEnum;
const isWhitespace = std.ascii.isWhitespace;
const isDigit = std.ascii.isDigit;
const isAlpha = std.ascii.isAlphanumeric;
const toUpper = std.ascii.toUpper;
const toLower =  std.ascii.toLower;
const assert = hlp.assert;
const inaccessible = hlp.inaccessible;

const Io = std.Io;
const Alloc = std.mem.Allocator;
const IpAddr = std.Io.net.IpAddress;
const ParsedHeader = types.ParsedHeader;
const ListenReturn = types.ListenReturn;
const Connection = types.Connection;
const HandleResult = types.HandleResult;
const HandlerFn = types.HandlerFn;

pub fn init(io:std.Io, alloc:Alloc, addr:*const IpAddr, handler:HandlerFn) !Server {
    return .{
        .io = io,
        .alloc = alloc,
        .addr = addr,
        .handler = handler,
    };
}

pub fn listen(self:*Server) ListenReturn {
    var server = self.addr.listen(self.io, .{ .reuse_address = true }) catch |err| switch (err) {
        error.AddressFamilyUnsupported => return .fail(error.UnsupportedSystem, "no ipv6"),
        error.AddressUnavailable, error.AddressInUse => |er| {
            var buf:[1024]u8 = undefined;
            var w:std.Io.Writer = .fixed(&buf);
            const e:ListenReturn.Error =
                if (er != error.AddressInUse)
                    @errorCast(er)
                else
                    error.AddressTaken;
            self.addr.format(&w) catch unreachable;
            return .fail(e, buf[0..w.end]);
        },
        error.NetworkDown => |e| return .fail(e, "failed to begin listening for connections"),
        else => |e| return .abort(e, "server = addr.listen(...)"),
    };
    defer server.deinit(self.io);

    var group:std.Io.Group = .init;
    defer group.cancel(self.io);

    while (true) {
        const stream = server.accept(self.io) catch |err| switch (err) {
            error.Unexpected => |e| return .abort(e, "stream = server.accept(...)"),
            error.BlockedByFirewall => |e| return .fail(e, "failed to accept connection"),
            error.Canceled => return .success(.canceled),
            else => continue,
        };
        group.concurrent(self.io, handleIoShim, .{ self, stream }) catch |e| switch (e) {
            error.ConcurrencyUnavailable => {
                stream.close(self.io); //discard current connection
                group.await(self.io) catch continue; //wait for other connections to finish
            },
        };
    }

    unreachable;
}

const Cancelable = std.Io.Cancelable;
fn handleIoShim(self:*Server, stream:std.Io.net.Stream) Cancelable!void {
    self.handleShim(stream) catch return;
}

fn handleShim(
    self:*Server,
    stream:std.Io.net.Stream,
) !void {
    var handle_res:HandleResult = .{};
    defer blk: {
        if (handle_res.closed) break :blk;
        stream.shutdown(self.io, .both) catch break :blk; // TODO: should I handle this?
        stream.close(self.io);
    }

    var arena:std.heap.ArenaAllocator = .init(self.alloc);
    const alloc = arena.allocator();
    defer arena.deinit(); // TODO: what (*exactly*) does stdlib mean this is not threadsafe?

    var reader_buf:[8192]u8 = undefined; //buf larger for headers
    var reader = stream.reader(self.io, &reader_buf);
    handle_res = try self.handler(.{
        .headers = try parseHeader(&reader, alloc),
        .alloc = alloc,
        .stream = stream,
        .io = self.io,
    });
}

pub fn isValidHeaderByte(which:enum{ key, value }, b:u8) bool {
    switch (which) {
        .key => {
            if (isAlpha(b) or isDigit(b)) return true;
            return hlp.inlineContains("!#$%&'*+-.^_`|~", b);
        },
        .value => return (b >= 0x20 and b <= 0x7e) or b == 0x09,
    }
    return false;
}

pub fn parseHeader(
    stream_reader:*std.Io.net.Stream.Reader,
    alloc:std.mem.Allocator
) !ParsedHeader {
    const reader = &stream_reader.interface;
    var headers:std.ArrayList(types.KVPair) = .empty;
    errdefer headers.deinit(alloc); //only deinit on err (otherwise deinit is no-op)

    //newline included so the last segment (the version) can just read to the
    //  carrage return for the chunk
    const status_line = try reader.takeDelimiter('\n') orelse return error.InvalidRequest;
    if (status_line[status_line.len - 1] != '\r') return error.InvalidRequest;
    var status_reader:std.Io.Reader = .fixed(status_line);

    const method = blk: {
        const str = try status_reader.takeDelimiter(' ') orelse {
            return error.InvalidRequest; //method
        };
        for (str) |*b| b.* = toUpper(b.*);
        break :blk stringToEnum(ParsedHeader.Method, str) orelse {
            return error.UnsupportedMethod;
        };
    };

    const page = blk: {
        const str = try status_reader.takeDelimiter(' ') orelse {
            return error.InvalidRequest; //page
        };
        // TODO:
        //  if (!options.SERVER_case_sensitive_pages) {
        //      for (str) |*b| b.* = toLower(b.*);
        //  }
        break :blk try alloc.dupe(u8, str);
    };

    const version:ParsedHeader.Version = blk: {
        const chunk_str = try status_reader.takeDelimiter('\r') orelse {
            return error.InvalidRequest; //version
        };
        for (chunk_str) |*b| b.* = toLower(b.*);

        //set during loop below
        var is_https:bool = undefined;
        var proto_len:usize = undefined;

        for ([_]bool{
            startsWith(u8, chunk_str, "http"),
            chunk_str.len > "https".len,
            cond: {
                is_https = chunk_str[4] == 's';
                proto_len = if (is_https) 5 else 4;
                break :cond chunk_str[proto_len] == '/';
            },
        }) |matches|
            if (!matches) return error.UnsupportedProtocol; //version

        const ver_chunk = chunk_str[ proto_len+1 .. chunk_str.len ];
        const ver_len = ver_chunk.len;

        for ([_]bool{
            ver_len == 3 or ver_len == 1,
            if (ver_len == 3) ver_chunk[1] == '.' else true,
            isDigit(ver_chunk[0]) and (if (ver_len == 3) isDigit(ver_chunk[2]) else true),
        }) |is_valid|
            if (!is_valid) return error.InvalidRequest; //version

        const version:[2]u4 = .{
            @intCast(ver_chunk[0]-'0'),
            if (ver_len == 3) @intCast(ver_chunk[2]-'0') else 0
        };

        break :blk .{
            .is_https  = is_https,
            .num = version,
        };
    };


    //actual headers
    if (try reader.peekByte() != '\r') {
        var count:usize = 0;
        while (true) : (count += 1) {
            if (count > std.math.maxInt(u16)) return error.TooManyHeaders;
            const line = try reader.takeDelimiter('\n') orelse break;
            if (!std.mem.endsWith(u8, line, "\r")) return error.InvalidHeader;
            if (line.len == 1) break;
            var re:std.Io.Reader = .fixed(line);
            const key = blk: {
                const raw = (try re.takeDelimiter(':')) orelse return error.InvalidHeader;
                assert(raw[raw.len-1] != ':', "delimiter was inclusive");
                for (raw) |*b| b.* = toLower(b.*);
                break :blk try alloc.dupe(u8, raw);
            };
            const value = blk: {
                while (re.peekByte() catch null) |b|
                    if (isWhitespace(b)) break else re.toss(1);
                var buf:[8192]u8 = undefined;
                const n = try re.readSliceShort(&buf);
                const raw = buf[0..n];
                var start:usize, var found_start = .{ 0, false };
                var end:usize, var found_end = .{ raw.len-1, false };
                while (start < end and start != end) {
                    if (found_start and found_end) break;
                    if (!found_start) {
                        if (!isWhitespace(raw[start]))
                            found_start = true
                        else
                            start += 1;
                    }
                    if (!found_end) {
                        if (!isWhitespace(raw[end]))
                            found_end = true
                        else
                            end -= 1;
                    }
                }
                const slice = raw[start..end+1];
                break :blk try alloc.dupe(u8, slice);
            };
            try headers.append(alloc, .{ .key = key, .value = value });
        }
    }


    return .{
        .method = method,
        .page = page,
        .version = version,
        .headers = try headers.toOwnedSlice(alloc),
    };
}
