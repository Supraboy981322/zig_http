const std = @import("std");
const types = @import("types.zig");

const StatusInfo = types.StatusInfo;

pub fn inlineContains(comptime str:[]const u8, b:u8) bool {
    return inline for (str) |c| {
        if (b == c) break true;
    } else false;
}

//unreachable accept it panics with a message
pub fn inaccessible(comptime msg:[]const u8) noreturn {
    @panic("reached inaccessible code: " ++ msg);
}

//std.debug.assert accept it panics with a message
pub fn assert(passed:bool, comptime msg:[]const u8) void {
    if (!passed) @panic("assertion failure: " ++ msg);
}

pub fn fileErrorToStatus(err:std.Io.File.OpenError) StatusInfo {
    switch (err) {
        inline else => |e| return switch (e) {

            error.FileNotFound
                => comptime .mk(.not_found),

            error.AccessDenied,
            error.PermissionDenied
                => comptime .mk(.forbidden),

            error.BadPathName,
            error.NameTooLong,
            error.IsDir,
            error.NotDir,
                => comptime .mk(.bad_request),

            error.FileTooBig,
            error.NoSpaceLeft,
                => comptime .mk(.insufficient_storage),

            else => comptime .mk(.internal_server_error),
        },
    }
}
