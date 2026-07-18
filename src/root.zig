const std = @import("std");

const Io = std.Io;

pub const Parser = @import("./parser.zig");
pub const Lexer = @import("./lexer.zig");
pub const Token = @import("./lexer.zig").Token;
pub const Expression = @import("./ast.zig").Expression;
pub const AstPrinter = @import("./ast.zig").AstPrinter;
pub const TypeChecker = @import("./typechecker.zig");
pub const Interpreter = @import("./interpreter.zig");
pub const SharedContext = @import("./shared.zig");

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

pub const Options = struct {
    text: bool = false,
    help: bool = false,
    @"debug-lexer": bool = false,
    @"halt-lexer": bool = false,
    @"debug-parser": bool = false,
    @"halt-parser": bool = false,
    @"debug-type": bool = false,
    @"halt-type": bool = false,

    pub const shorthands = .{
        .i = "text",
        .h = "help",
        .l = "debug-lexer",
        .L = "halt-lexer",
        .p = "debug-parser",
        .P = "halt-parser",
        .t = "debug-type",
        .T = "halt-type",
    };
};

pub fn readFileContents(allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) ![]const u8 {
    var file = try std.Io.Dir.cwd().openFile(io, filePath, .{ .mode = .read_only });
    defer file.close(io);

    var fileReader = file.reader(io, &.{});

    const maxFileSize = 1024 * 1024 * 10;
    const contents = fileReader.interface.allocRemaining(allocator, .limited(maxFileSize));

    return contents;
}

test "run all tests" {}
