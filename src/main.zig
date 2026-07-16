const std = @import("std");
const Io = std.Io;

const argsParser = @import("args");
const Repl = @import("./repl.zig");
const zulu = @import("zulu");
const Options = zulu.Options;
const Lexer = zulu.Lexer;
const Parser = zulu.Parser;
const AstPrinter = zulu.AstPrinter;
const TypeChecker = zulu.TypeChecker;
const TypeError = zulu.TypeChecker.TypeError;
const Interpreter = zulu.Interpreter;
const ansi = zulu.ansi;
const Token = zulu.Token;
const Expression = zulu.Expression;

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

fn printUsage() void {
    std.debug.print(ansi.bold ++ "Usage: zulu [options] <source | repl>\n\n" ++ ansi.reset, .{});
    std.debug.print("Options:\n", .{});
    std.debug.print("  -i, --text             Take text input from positional argument\n", .{});
    std.debug.print("  -h, --help             Display this help message\n", .{});

    std.debug.print("\n" ++ ansi.blue ++ ansi.bold ++ "Debug options:\n" ++ ansi.reset, .{});
    std.debug.print("  -l, --debug-lexer      Print lexer output (tokens)\n", .{});
    std.debug.print("  -L, --halt-lexer       Stop after lexer\n", .{});
    std.debug.print("  -p, --debug-parser     Print parser output (AST)\n", .{});
    std.debug.print("  -P, --halt-parser      Stop after parser\n", .{});
    std.debug.print("  -t, --debug-type       Print typechecker output (final program's type)\n", .{});
    std.debug.print("  -T, --halt-type        Stop after typechecking\n", .{});
}

fn readFile(io: std.Io, arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var fileReader = file.reader(io, &.{});

    const maxFileSize = 1024 * 1024 * 10;
    const contents = fileReader.interface.allocRemaining(arena, .limited(maxFileSize));

    return contents;
}

pub fn pipeline(allocator: std.mem.Allocator, source: []const u8, options: Options) !?Interpreter.Value {
    var lexer = try Lexer.init(allocator, source);
    defer lexer.deinit();

    const tokens = lexer.scanTokens() catch |err| {
        std.debug.print(ansi.bold ++ ansi.red ++ "Lexer Error: " ++ ansi.reset, .{});
        switch (err) {
            error.UNMATCHED_TOKEN => {
                const char = if (lexer.current > 0) lexer.source[lexer.current - 1] else '?';
                std.debug.print("Unexpected character '{c}' at line {}, column {}.\n", .{ char, lexer.line, lexer.column });
                printSourceHighlight(source, lexer.line, lexer.column, 1);
            },
            error.UNTERMINATED_STRING_LITERAL => {
                std.debug.print("Unterminated string literal starting at line {}, column {}.\n", .{ lexer.line, lexer.column });
                printSourceHighlight(source, lexer.line, lexer.column, 1);
            },
            else => {
                std.debug.print("Unexpected scanning error: {s}\n", .{@errorName(err)});
            },
        }
        return err;
    };

    if (options.@"debug-lexer") {
        std.debug.print(ansi.bold ++ ansi.green ++ "Lexer output:\n" ++ ansi.reset, .{});
        const tokensPrinted = try lexer.printTokens();
        std.debug.print("{s}", .{tokensPrinted});
    }

    if (options.@"halt-lexer") {
        return null;
    }

    var parser = Parser.init(allocator, tokens);
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
            error.NOT_A_BINARY_OPERATION => {
                std.debug.print("Invalid binary operation at line {}, column {}.\n", .{ token.location.line, token.location.column });
            },
            error.OUT_OF_MEMORY => {
                std.debug.print("Out of memory.\n", .{});
            },
            error.UNEXPECTED_TOKEN => {
                if (token.type == .EOF) {
                    std.debug.print("Unexpected end of input at line {}, column {}.\n", .{ token.location.line, token.location.column });
                } else {
                    std.debug.print("Unexpected token '{s}' at line {}, column {}.\n", .{ token.lexeme, token.location.line, token.location.column });
                }
            },
            else => {
                std.debug.print("Unexpected parsing error: {s}\n", .{@errorName(err)});
            },
        }
        printSourceHighlight(source, token.location.line, token.location.column, token.lexeme.len);
        return err;
    };

    if (options.@"debug-parser") {
        std.debug.print(ansi.bold ++ ansi.green ++ "Parser output:\n" ++ ansi.reset, .{});
        const printedExpr = try AstPrinter.prettyPrint(allocator, expression.*);
        std.debug.print("{s}\n", .{printedExpr});
    }

    if (options.@"halt-parser") {
        return null;
    }

    var typeArena = std.heap.ArenaAllocator.init(allocator);
    defer typeArena.deinit();
    const typeAllocator = typeArena.allocator();
    var typeChecker = TypeChecker.init(typeAllocator);

    const programType = typeChecker.inferType(expression) catch |err| {
        switch (err) {
            TypeError.UNEXPECTED_TYPE => {
                std.debug.print(ansi.bold ++ ansi.red ++ "Type Error: Unexpected type\n" ++ ansi.reset, .{});
                if (typeChecker.errorContext) |context| {
                    if (findExprLocation(tokens, context.UNEXPECTED_TYPE.context)) |token| {
                        printSourceHighlight(source, token.location.line, token.location.column, token.lexeme.len);
                    }

                    std.debug.print("Expected one of the following types:\n", .{});
                    for (context.UNEXPECTED_TYPE.expectedType) |expectedType| {
                        std.debug.print(ansi.blue ++ "\t{s}\n" ++ ansi.reset, .{try TypeChecker.PrettyPrinter.prettyPrint(typeAllocator, typeChecker.finalizeType(expectedType).*)});
                    }
                    std.debug.print("But got: " ++ ansi.blue ++ "{s}" ++ ansi.reset ++ "\n", .{try TypeChecker.PrettyPrinter.prettyPrint(typeAllocator, typeChecker.finalizeType(context.UNEXPECTED_TYPE.foundType).*)});
                }
            },
            else => {
                std.debug.print(ansi.bold ++ ansi.red ++ "Type Error: {}\n", .{err});
            },
        }
        return null;
    };
    if (options.@"debug-type") {
        std.debug.print(ansi.bold ++ ansi.green ++ "Typechecker output:\n" ++ ansi.reset, .{});
        const printedType = try TypeChecker.PrettyPrinter.prettyPrint(allocator, typeChecker.finalizeType(programType).*);
        std.debug.print("{s}\n", .{printedType});
    }

    if (options.@"halt-type") {
        return null;
    }

    var interpreter = Interpreter.init(allocator);

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
            error.TYPE_PROMOTION_NOT_IMPLEMENTED => {
                std.debug.print("Type promotion not implemented yet.\n", .{});
            },
            error.UNIMPLEMENTED => {
                std.debug.print("Unimplemented feature encountered.\n", .{});
            },
        }
        if (interpreter.last_expression) |last_expr| {
            if (findExprLocation(tokens, last_expr)) |token| {
                printSourceHighlight(source, token.location.line, token.location.column, token.lexeme.len);
            }
        }
        return err;
    };
    return value;
}

fn run(init: std.process.Init) anyerror!void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const options = argsParser.parseForCurrentProcess(Options, init, .print) catch return error.ParseArgumentsError;
    defer options.deinit();

    if (options.options.help) {
        printUsage();
        return;
    }

    if (options.positionals.len != 1) {
        if (options.options.text) {
            std.debug.print(ansi.bold ++ ansi.red ++ "Usage Error: " ++ ansi.reset ++ "No source code provided.\n", .{});
            printUsage();
        } else {
            std.debug.print(ansi.bold ++ ansi.red ++ "Usage Error: " ++ ansi.reset ++ "No source file provided.\n", .{});
            printUsage();
        }
        return error.NO_INPUT;
    }

    if (std.mem.eql(u8, options.positionals[0], "repl")) {
        var repl = Repl.init(init.io, arena, options.options);
        try repl.run();

        return;
    }

    const source = if (options.options.text) options.positionals[0] else readFile(init.io, arena, options.positionals[0]) catch |err| {
        std.debug.print(ansi.bold ++ ansi.red ++ "Error: " ++ ansi.reset, .{});
        switch (err) {
            error.FileNotFound => {
                std.debug.print("No such file: {s}\n", .{options.positionals[0]});
            },
            else => {
                std.debug.print("Unknown error: {any}\n", .{err});
            },
        }
        return;
    };

    const value = try pipeline(arena, source, options.options);
    if (value) |val| {
        const printedValue = try Interpreter.printValue(arena, val);

        try std.Io.File.stdout().writeStreamingAll(init.io, printedValue);
        try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
    }

    if (false) return error.Unexpected;
}

fn findTokenByLexemePtr(tokens: []const Token, lexeme: []const u8) ?Token {
    for (tokens) |token| {
        if (token.lexeme.ptr == lexeme.ptr) {
            return token;
        }
    }
    return null;
}

fn findExprLocation(tokens: []const Token, expr: *Expression) ?Token {
    switch (expr.*) {
        .Variable => |v| return findTokenByLexemePtr(tokens, v),
        .Number => |n| return findTokenByLexemePtr(tokens, n),
        .String => |s| return findTokenByLexemePtr(tokens, s),
        .Boolean => |b| {
            const target_text = if (b) "true" else "false";
            for (tokens) |token| {
                if (std.ascii.eqlIgnoreCase(token.lexeme, target_text)) {
                    return token;
                }
            }
            return null;
        },
        .BinaryOperation => |bop| return findExprLocation(tokens, bop.left),
        .Not => |not| return findExprLocation(tokens, not),
        .UnaryMinus => |unaryMinus| return findExprLocation(tokens, unaryMinus),
        .Condition => |cond| return findExprLocation(tokens, cond.expression),
        .Declaration => |decl| return findTokenByLexemePtr(tokens, decl.identifier),
        .Lambda => |lam| return findTokenByLexemePtr(tokens, lam.identifier),
        .Match => |mat| return findExprLocation(tokens, mat.scrutinee),
        .Tuple => |val| return findExprLocation(tokens, val[0]),
        .Application => |app| return findExprLocation(tokens, app.callee),
    }
}

fn printSourceHighlight(source: []const u8, line_num: usize, col_num: usize, lexeme_len: usize) void {
    var current_line: usize = 1;
    var line_start: usize = 0;
    var line_end: usize = 0;

    for (source, 0..) |char, i| {
        if (current_line == line_num) {
            if (line_start == 0 and i > 0 and source[i - 1] == '\n') {
                line_start = i;
            } else if (i == 0) {
                line_start = 0;
            }
        }
        if (char == '\n') {
            if (current_line == line_num) {
                line_end = i;
                break;
            }
            current_line += 1;
        }
    }
    if (line_end == 0) {
        line_end = source.len;
    }

    const line_content = source[line_start..line_end];

    std.debug.print("\n  | {s}\n", .{line_content});
    std.debug.print("  | ", .{});

    var i: usize = 1;
    while (i < col_num) : (i += 1) {
        std.debug.print(" ", .{});
    }

    std.debug.print(ansi.bold ++ ansi.red, .{});
    var len = lexeme_len;
    if (len == 0) len = 1;
    i = 0;
    while (i < len) : (i += 1) {
        std.debug.print("^", .{});
    }
    std.debug.print(ansi.reset ++ "\n\n", .{});
}
