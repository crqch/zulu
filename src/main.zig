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

    //var instance = try lexer.Lexer.init(arena, "[x=.10;x + 10.0];([y=20;y+x >= 10]);\"test\"");
    var instance = try lexer.Lexer.init(arena, "test ELSE IF TruE");
    defer instance.deinit();

    const tokens = try instance.scanTokens();

    for (tokens) |token| {
        std.log.info("[{}] lexeme: \"{s}\" - {} ", .{ token.type, token.lexeme, token.location });
    }
}

test "run all tests" {
    _ = @import("lexer.zig");
}
