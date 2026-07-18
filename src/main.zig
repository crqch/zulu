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
const SharedContext = zulu.SharedContext;

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
        var repl = try Repl.init(init.io, arena, options.options);
        try repl.run();

        return;
    }

    var sharedContext = SharedContext.init(arena, init.io, options.options) catch {
        std.debug.print(ansi.bold ++ ansi.red ++ "Memory allocator error: " ++ ansi.reset ++ ansi.red ++ "Shared context hashmap allocation failed!" ++ ansi.reset, .{});
    };
    defer sharedContext.deinit();

    if (options.options.text) {
        try sharedContext.loadSource(options.positionals[0]);
    } else {
        sharedContext.load(options.positionals[0]) catch |err| {
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
    }

    const ret = try sharedContext.get(if (options.options.text) "_" else options.positionals[0]);

    const printedValue = try Interpreter.printValue(arena, ret.value.?);

    std.debug.print("{s}\n", .{printedValue});

    if (false) return error.Unexpected;
}
