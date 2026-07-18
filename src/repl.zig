const std = @import("std");

const zulu = @import("zulu");
const ansi = zulu.ansi;
const SharedContext = zulu.SharedContext;
const Options = zulu.Options;
const Interpreter = zulu.Interpreter;

const Repl = @This();

io: std.Io,
allocator: std.mem.Allocator,
options: Options,
sharedContext: SharedContext,

pub fn init(io: std.Io, allocator: std.mem.Allocator, options: Options) !Repl {
    return Repl{
        .io = io,
        .allocator = allocator,
        .options = options,
        .sharedContext = try SharedContext.init(allocator, io, options),
    };
}

pub fn run(self: *Repl) !void {
    var stdinBuffer: [4096]u8 = undefined;
    var stdoutBuffer: [4096]u8 = undefined;

    var stdinReader = std.Io.File.stdin().reader(self.io, &stdinBuffer);
    const stdin = &stdinReader.interface;

    var stdoutWriter = std.Io.File.stdout().writer(self.io, &stdoutBuffer);
    const stdout = &stdoutWriter.interface;

    defer self.sharedContext.deinit();

    try stdout.flush();

    try stdout.writeAll(ansi.bold ++ ansi.green ++ "ZULU repl. Type 'exit' to quit.\n" ++ ansi.reset);

    while (true) {
        try stdout.writeAll(ansi.blue ++ "zul-repl> " ++ ansi.reset);

        try stdout.flush();

        const input = stdin.takeDelimiterExclusive('\n') catch |err| {
            if (err == error.EndOfStream) {
                try stdout.writeAll(ansi.red ++ ansi.bold ++ "\rEOF detected. Exiting REPL session\n");

                try stdout.flush();

                break;
            }
            break;
        };

        _ = stdin.takeByte() catch {};

        const line = std.mem.trimEnd(u8, input, "\r");

        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "exit")) break;

        var arena = std.heap.ArenaAllocator.init(self.allocator);

        const ret = self.sharedContext.pipeline.run(&self.sharedContext, "repl", line, self.options) catch {
            arena.deinit();
            continue;
        };

        if (ret) |r| {
            if (r.value) |val| {
                const printedValue = Interpreter.printValue(arena.allocator(), val) catch {
                    arena.deinit();
                    continue;
                };

                try stdout.print("{s}\n", .{printedValue});
                try stdout.flush();
            }
        }

        arena.deinit();
    }
}
