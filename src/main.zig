const std = @import("std");
const Io = std.Io;

const zulu = @import("zulu");
const Lexer = @import("./lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const AstPrinter = @import("ast.zig").AstPrinter;

pub const std_options: std.Options = .{
    .fmt_max_depth = 15, // Increase this to however deep your AST gets
};

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();

    // const args = try init.minimal.args.toSlice(arena);
    // for (args) |arg| {
    //     std.log.info("arg: {s}", .{arg});
    // }

    //var lexer = try Lexer.init(arena, "[x;x + 10.0];10");
    var lexer = try Lexer.init(arena, "f=[y;y*y];x=10;f x + x+42");
    // var lexer = try Lexer.init(arena, "2+2");
    defer lexer.deinit();

    const tokens = try lexer.scanTokens();

    for (tokens) |token| {
        std.log.info("[{}] lexeme: \"{s}\" - {} ", .{ token.type, token.lexeme, token.location });
    }

    var parser = Parser.init(arena, tokens);
    const expr = try parser.parse();

    const printedExpr = try AstPrinter.prettyPrint(arena, expr.*);

    try std.Io.File.stdout().writeStreamingAll(init.io, printedExpr);
}

test "run all tests" {
    _ = @import("lexer.zig");
}
