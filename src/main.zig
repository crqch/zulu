const std = @import("std");
const Io = std.Io;

const zulu = @import("zulu");
const Lexer = zulu.Lexer;
const Parser = zulu.Parser;
const AstPrinter = zulu.AstPrinter;
const Interpreter = zulu.Interpreter;

pub const std_options: std.Options = .{
    .fmt_max_depth = 15, // Increase this to however deep your AST gets
};

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    for (args) |arg| {
        errdefer std.log.debug("arg: {s}", .{arg});
    }

    if (args.len != 2) return error.NO_INPUT;

    var lexer = try Lexer.init(arena, args[1]);
    defer lexer.deinit();

    const tokens = try lexer.scanTokens();

    // for (tokens) |token| {
    //     std.log.info("[{}] lexeme: \"{s}\" - {} ", .{ token.type, token.lexeme, token.location });
    // }

    var parser = Parser.init(arena, tokens);
    const expression = try parser.parse();

    // const printedExpr = try AstPrinter.prettyPrint(arena, expression.*);

    // try std.Io.File.stdout().writeStreamingAll(init.io, printedExpr);

    var interpreter = Interpreter.init(arena);

    const value = try interpreter.eval(expression);
    const printedValue = try Interpreter.printValue(arena, value);
    try std.Io.File.stdout().writeStreamingAll(init.io, printedValue);
    try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
}
