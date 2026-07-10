const std = @import("std");
const zulu = @import("zulu");

const parser_tests = @import("./parser.zig");

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

    var parser_tester = try parser_tests.Testing.init(allocator, io);
    try parser_tester.runTests();
}
