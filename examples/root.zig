const std = @import("std");

const examples = struct {
    pub const info = @import("info.zig");
};

const Examples:type = std.meta.DeclEnum(examples);

pub fn main(init:std.process.Init) !u8 {
    if (init.minimal.args.vector.len != 2) {
        std.debug.print("expected exactly one arg: an example to run\n", .{});
        printExamples();
        return 1;
    }

    var itr = init.minimal.args.iterate();
    defer itr.deinit();
    _ = itr.skip();
    const match = std.meta.stringToEnum(Examples, itr.next().?) orelse {
        std.debug.print("invalid example... below are valid examples:\n", .{});
        printExamples();
        return 1;
    };

    return switch (match) {
        inline else => |m| @field(examples, @tagName(m)).main(init),
    };
}

pub fn printExamples() void {
    for (std.meta.fields(examples)) |eg|
        std.debug.print("\t- {s}\n", .{eg});
}
