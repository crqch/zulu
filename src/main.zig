const std = @import("std");
const Io = std.Io;

const zulu = @import("zulu");
const lexer = @import("./lexer.zig");

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();

    // const args = try init.minimal.args.toSlice(arena);
    // for (args) |arg| {
    //     std.log.info("arg: {s}", .{arg});
    // }

    var instance = try lexer.Lexer.init(arena, "24 + *  -");
    defer instance.deinit();

    const tokens = try instance.scanTokens();

    for (tokens) |token| {
        std.log.info("[{}] lexeme: \"{s}\" - {} ", .{ token.type, token.lexeme, token.location });
    }
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
