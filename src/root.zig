const std = @import("std");

const Io = std.Io;

pub const Parser = @import("./parser.zig").Parser;
pub const Lexer = @import("./lexer.zig").Lexer;
pub const Token = @import("./lexer.zig").Token;
pub const Expression = @import("./ast.zig").Expression;
pub const AstPrinter = @import("./ast.zig").AstPrinter;
pub const Interpreter = @import("./interpreter.zig");

pub const ansi = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const red = "\x1b[31m";
    pub const green = "\x1b[32m";
    pub const yellow = "\x1b[33m";
    pub const blue = "\x1b[34m";
    pub const cyan = "\x1b[36m";
    pub const gray = "\x1b[90m";
};

test "run all tests" {
    _ = @import("./lexer.zig");
}
