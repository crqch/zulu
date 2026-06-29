const std = @import("std");
const Io = std.Io;

const zulu = @import("zulu");
const Lexer = @import("./lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;

pub const std_options: std.Options = .{
    .fmt_max_depth = 15, // Increase this to however deep your AST gets
};

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();

    // const args = try init.minimal.args.toSlice(arena);
    // for (args) |arg| {
    //     std.log.info("arg: {s}", .{arg});
    // }

    var lexer = try Lexer.init(arena, "[x;x + 10.0];10");
    // var lexer = try Lexer.init(arena, "2+2");
    defer lexer.deinit();

    const tokens = try lexer.scanTokens();

    for (tokens) |token| {
        std.log.info("[{}] lexeme: \"{s}\" - {} ", .{ token.type, token.lexeme, token.location });
    }

    var parser = Parser.init(arena, tokens);
    const expr = try parser.parse();

    std.log.info("{}", .{expr});
}

test "run all tests" {
    _ = @import("lexer.zig");
}
