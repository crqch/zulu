const std = @import("std");
const zulu = @import("zulu");

const lexer_tests = @import("./lexer.zig");
const parser_tests = @import("./parser.zig");
const typechecker_tests = @import("./typechecker.zig");

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

pub fn main(init: std.process.Init) !void {
    enableAnsiColors();

    std.debug.print(ansi.bold ++ ansi.blue ++ "Running tests" ++ ansi.reset ++ "\n", .{});

    const allocator = init.arena.allocator();
    const io = init.io;

    std.debug.print(ansi.bold ++ ansi.blue ++ "Lexer module tests" ++ ansi.reset ++ "\n", .{});

    var lexer_tester = try lexer_tests.Testing.init(allocator, io);
    try lexer_tester.runTests();

    std.debug.print(ansi.bold ++ ansi.blue ++ "Parser module tests" ++ ansi.reset ++ "\n", .{});

    var parser_tester = try parser_tests.Testing.init(allocator, io);
    try parser_tester.runTests();

    std.debug.print(ansi.bold ++ ansi.blue ++ "Typechecker module tests" ++ ansi.reset ++ "\n", .{});

    var typechecker_tester = try typechecker_tests.Testing.init(allocator, io);
    try typechecker_tester.runTests();
}
