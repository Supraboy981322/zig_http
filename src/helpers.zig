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

