const std = @import("std");
const Io = std.Io;

const zulu = @import("zulu");
const Lexer = zulu.Lexer;
const Parser = zulu.Parser;
const AstPrinter = zulu.AstPrinter;
const Interpreter = zulu.Interpreter;

const ansi = zulu.ansi;

fn enableAnsiColors() void {
    if (@import("builtin").os.tag == .windows) {
        const windows = std.os.windows;
        const kernel32 = windows.kernel32;
        if (kernel32.GetStdHandle(windows.STD_OUTPUT_HANDLE)) |stdout_handle| {
            var mode: windows.DWORD = 0;
            if (kernel32.GetConsoleMode(stdout_handle, &mode) != 0) {
                mode |= 0x0004; // ENABLE_VIRTUAL_TERMINAL_PROCESSING
                _ = kernel32.SetConsoleMode(stdout_handle, mode);
            }
        }
    }
}

pub const std_options: std.Options = .{
    .fmt_max_depth = 15, // Increase this to however deep your AST gets
};

pub fn main(init: std.process.Init) !void {
    enableAnsiColors();

    run(init) catch |err| {
        const is_expected = inline for (.{
            error.NO_INPUT,
            error.UNMATCHED_TOKEN,
            error.UNTERMINATED_STRING_LITERAL,
            error.EOF_NOT_REACHED,
            error.EXPECTED_VARIABLE_AT_DECLARATION,
            error.EXPECTED_LEFT_PARENTHESES,
            error.EXPECTED_RIGHT_PARENTHESES,
            error.EXPECTED_ELSE_KEYWORD,
            error.LAMBDA_UNRESOLVED,
            error.EXPECTED_EXPRESSION,
            error.PARENTHESES_UNMATCHED,
            error.UNKNOWN_ESCAPE_CHARACTER,
            error.EXPECTED_BOP,
            error.NOT_A_BINARY_OPERATION,
            error.UNBOUND_VARIABLE,
            error.UNEXPECTED_TYPE,
            error.DIVISION_BY_ZERO,
            error.FLOAT_PARSING_FAILED,
            error.INT_PARSING_FAILED,
            error.ENVIRONMENT_INITALIZATION_ERROR,
            error.ENVIRONMENT_MAP_ERROR,
            error.MEMORY_ALLOCATION_FAILED,
            error.UNIMPLEMENTED,
        }) |expected| {
            if (err == expected) break true;
        } else false;

        if (!is_expected) {
            std.debug.print(ansi.bold ++ ansi.red ++ "FATAL: ZULU Interpreter has encountered an unexpected exception.\n\n" ++ ansi.reset, .{});
            std.debug.print(ansi.gray ++ "(error_code: {s})\n" ++ ansi.reset, .{@errorName(err)});
        }
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) anyerror!void {
    const arena: std.mem.Allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);

    if (args.len != 2) {
        std.debug.print(ansi.bold ++ ansi.red ++ "Usage Error: " ++ ansi.reset ++ "No source code provided.\n", .{});
        std.debug.print("Run the interpreter with a string argument: zulu \"<source_code>\"\n", .{});
        return error.NO_INPUT;
    }

    var lexer = try Lexer.init(arena, args[1]);
    defer lexer.deinit();

    const tokens = lexer.scanTokens() catch |err| {
        std.debug.print(ansi.bold ++ ansi.red ++ "Lexer Error: " ++ ansi.reset, .{});
        switch (err) {
            error.UNMATCHED_TOKEN => {
                const char = if (lexer.current > 0) lexer.source[lexer.current - 1] else '?';
                std.debug.print("Unexpected character '{c}' at line {}, column {}.\n", .{ char, lexer.line, lexer.column });
            },
            error.UNTERMINATED_STRING_LITERAL => {
                std.debug.print("Unterminated string literal starting at line {}, column {}.\n", .{ lexer.line, lexer.column });
            },
            else => {
                std.debug.print("Unexpected scanning error: {s}\n", .{@errorName(err)});
            },
        }
        return err;
    };

    var parser = Parser.init(arena, tokens);
    const expression = parser.parse() catch |err| {
        std.debug.print(ansi.bold ++ ansi.red ++ "Parser Error: " ++ ansi.reset, .{});
        const token = if (parser.current < parser.tokens.len) parser.tokens[parser.current] else parser.tokens[parser.tokens.len - 1];
        switch (err) {
            error.EOF_NOT_REACHED => {
                std.debug.print("Unexpected token '{s}' at line {}, column {} (extra input after expression).\n", .{ token.lexeme, token.location.line, token.location.column });
            },
            error.EXPECTED_VARIABLE_AT_DECLARATION => {
                std.debug.print("Expected variable identifier in declaration at line {}, column {}.\n", .{ token.location.line, token.location.column });
            },
            error.EXPECTED_LEFT_PARENTHESES => {
                std.debug.print("Expected '(' after 'if' at line {}, column {}.\n", .{ token.location.line, token.location.column });
            },
            error.EXPECTED_RIGHT_PARENTHESES => {
                std.debug.print("Expected ')' after condition at line {}, column {}.\n", .{ token.location.line, token.location.column });
            },
            error.EXPECTED_ELSE_KEYWORD => {
                std.debug.print("Expected 'else' keyword at line {}, column {}.\n", .{ token.location.line, token.location.column });
            },
            error.LAMBDA_UNRESOLVED => {
                std.debug.print("Unresolved lambda syntax at line {}, column {}.\n", .{ token.location.line, token.location.column });
            },
            error.EXPECTED_EXPRESSION => {
                std.debug.print("Expected expression at line {}, column {}.\n", .{ token.location.line, token.location.column });
            },
            error.PARENTHESES_UNMATCHED => {
                std.debug.print("Unmatched parentheses starting at line {}, column {}.\n", .{ token.location.line, token.location.column });
            },
            error.UNKNOWN_ESCAPE_CHARACTER => {
                std.debug.print("Unknown escape character in string literal at line {}, column {}.\n", .{ token.location.line, token.location.column });
            },
            error.EXPECTED_BOP => {
                std.debug.print("Expected binary operator at line {}, column {}.\n", .{ token.location.line, token.location.column });
            },
            error.NOT_A_BINARY_OPERATION => {
                std.debug.print("Invalid binary operation at line {}, column {}.\n", .{ token.location.line, token.location.column });
            },
            else => {
                std.debug.print("Unexpected parsing error: {s}\n", .{@errorName(err)});
            },
        }
        return err;
    };

    const printedExpr = try AstPrinter.prettyPrint(arena, expression.*);
    _ = printedExpr;

    var interpreter = Interpreter.init(arena);

    const value = interpreter.eval(expression) catch |err| {
        std.debug.print(ansi.bold ++ ansi.red ++ "Runtime Error: " ++ ansi.reset, .{});
        switch (err) {
            error.UNBOUND_VARIABLE => {
                std.debug.print("Unbound variable (variable referenced before it was defined).\n", .{});
            },
            error.UNEXPECTED_TYPE => {
                std.debug.print("Unexpected type encountered in operation.\n", .{});
            },
            error.DIVISION_BY_ZERO => {
                std.debug.print("Division by zero.\n", .{});
            },
            error.FLOAT_PARSING_FAILED => {
                std.debug.print("Failed to parse float value.\n", .{});
            },
            error.INT_PARSING_FAILED => {
                std.debug.print("Failed to parse integer value.\n", .{});
            },
            error.ENVIRONMENT_INITALIZATION_ERROR, error.ENVIRONMENT_MAP_ERROR, error.MEMORY_ALLOCATION_FAILED => {
                std.debug.print("Memory allocation or environment initialization failed.\n", .{});
            },
            error.UNIMPLEMENTED => {
                std.debug.print("Unimplemented feature encountered.\n", .{});
            },
        }
        return err;
    };
    const printedValue = try Interpreter.printValue(arena, value);
    try std.Io.File.stdout().writeStreamingAll(init.io, printedValue);
    try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
    if (false) return error.Unexpected;
}
