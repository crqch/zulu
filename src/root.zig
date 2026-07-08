const std = @import("std");

const Io = std.Io;

pub const Parser = @import("./parser.zig").Parser;
pub const Lexer = @import("./lexer.zig").Lexer;
pub const AstPrinter = @import("./ast.zig").AstPrinter;

test "run all tests" {
    _ = @import("./lexer.zig");
}
