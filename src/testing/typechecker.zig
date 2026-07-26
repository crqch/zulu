const std = @import("std");

const zulu = @import("zulu");
const Lexer = zulu.Lexer;
const Parser = zulu.Parser;
const TypeChecker = zulu.TypeChecker;
const AstPrinter = zulu.AstPrinter;
const readFileContents = zulu.readFileContents;

const ansi = zulu.ansi;

pub const Testing = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    const TestStatus = enum {
        fail,
        pass,
    };

    const TestsStats = struct {
        fail: i32,
        pass: i32,

        pub fn add(self: *TestsStats, other: TestsStats) void {
            self.pass += other.pass;
            self.fail += other.fail;
        }
    };

    const Failure = struct {
        file_path: []const u8,
        expected: []const u8,
        got: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Testing {
        return Testing{
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn runTests(self: *Testing) !void {
        var failures: std.ArrayList(Failure) = .empty;
        defer failures.deinit(self.allocator);

        std.debug.print(ansi.bold ++ ansi.blue ++ "· Running PASS tests (parsing valid programs)..." ++ ansi.reset ++ "\n", .{});
        const pass_tests = try self.runPassTests(&failures);

        std.debug.print("\n" ++ ansi.bold ++ ansi.blue ++ "· Running FAIL tests (parsing invalid programs)..." ++ ansi.reset ++ "\n", .{});
        const fail_tests = try self.runFailTests(&failures);

        var all_tests = TestsStats{
            .fail = 0,
            .pass = 0,
        };

        all_tests.add(pass_tests);
        all_tests.add(fail_tests);

        if (failures.items.len > 0) {
            std.debug.print("\n" ++ ansi.bold ++ ansi.red ++ "Failures:" ++ ansi.reset ++ "\n", .{});
            for (failures.items) |fail| {
                std.debug.print("\n" ++ ansi.red ++ "  ✗ " ++ ansi.bold ++ "{s}" ++ ansi.reset ++ "\n" ++
                    "    " ++ ansi.cyan ++ "Expected:" ++ ansi.reset ++ "\n" ++
                    "      {s}\n" ++
                    "    " ++ ansi.red ++ "Got:" ++ ansi.reset ++ "\n" ++
                    "      {s}\n", .{ fail.file_path, fail.expected, fail.got });
            }
        }

        const green = ansi.green;
        const red = ansi.red;
        const reset = ansi.reset;
        const bold = ansi.bold;

        std.debug.print("\n" ++ bold ++ "┌──────────────────────────────────────────────┐" ++ reset ++ "\n", .{});
        std.debug.print(bold ++ "│                 " ++ ansi.cyan ++ "TEST SUMMARY" ++ reset ++ bold ++ "                 │" ++ reset ++ "\n", .{});
        std.debug.print(bold ++ "├─────────────────┬──────────────┬─────────────┤" ++ reset ++ "\n", .{});
        std.debug.print(bold ++ "│" ++ reset ++ " Suite           " ++ bold ++ "│" ++ green ++ " Passed       " ++ reset ++ bold ++ "│" ++ red ++ " Failed      " ++ reset ++ bold ++ "│" ++ reset ++ "\n", .{});
        std.debug.print(bold ++ "├─────────────────┼──────────────┼─────────────┤" ++ reset ++ "\n", .{});
        std.debug.print(bold ++ "│" ++ reset ++ " Expected Pass   " ++ bold ++ "│ " ++ green ++ "{d:<12}" ++ reset ++ bold ++ " │ " ++ red ++ "{d:<11}" ++ bold ++ reset ++ " │" ++ reset ++ "\n", .{ pass_tests.pass, pass_tests.fail });
        std.debug.print(bold ++ "│" ++ reset ++ " Expected Fail   " ++ bold ++ "│ " ++ green ++ "{d:<12}" ++ reset ++ bold ++ " │ " ++ red ++ "{d:<11}" ++ bold ++ reset ++ " │" ++ reset ++ "\n", .{ fail_tests.pass, fail_tests.fail });
        std.debug.print(bold ++ "├─────────────────┼──────────────┼─────────────┤" ++ reset ++ "\n", .{});
        std.debug.print(bold ++ "│" ++ reset ++ " Total           " ++ bold ++ "│ " ++ green ++ "{d:<12}" ++ reset ++ bold ++ " │ " ++ red ++ "{d:<11}" ++ bold ++ reset ++ " │" ++ reset ++ "\n", .{ all_tests.pass, all_tests.fail });
        std.debug.print(bold ++ "└─────────────────┴──────────────┴─────────────┘" ++ reset ++ "\n", .{});
    }

    fn runPassTests(self: *Testing, failures: *std.ArrayList(Failure)) !TestsStats {
        var stats = TestsStats{
            .fail = 0,
            .pass = 0,
        };

        var saved_path = try std.fmt.allocPrint(self.allocator, "tests/typechecker/pass", .{});
        defer self.allocator.free(saved_path);

        var dir = try std.Io.Dir.cwd().openDir(self.io, saved_path, .{ .iterate = true });
        defer dir.close(self.io);

        var saved_iterator = dir.iterate();

        std.debug.print("  ", .{});
        while (try saved_iterator.next(self.io)) |entry| {
            switch (entry.kind) {
                .directory => {
                    const savedIterator = saved_iterator;
                    const savedPath = saved_path;

                    saved_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ savedPath, entry.name });

                    dir = try std.Io.Dir.cwd().openDir(self.io, saved_path, .{ .iterate = true });

                    saved_iterator = dir.iterate();

                    saved_path = savedPath;

                    saved_iterator = savedIterator;
                },
                .file => {
                    const file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ saved_path, entry.name });
                    defer self.allocator.free(file_path);

                    switch (try self.runPassTest(file_path, failures)) {
                        .pass => {
                            std.debug.print(ansi.green ++ "•" ++ ansi.reset, .{});
                            stats.pass += 1;
                        },
                        .fail => {
                            std.debug.print(ansi.red ++ "✗" ++ ansi.reset, .{});
                            stats.fail += 1;
                        },
                    }
                },
                else => {},
            }
        }
        std.debug.print("\n", .{});

        return stats;
    }

    fn runPassTest(self: *Testing, filePath: []const u8, failures: *std.ArrayList(Failure)) !TestStatus {
        errdefer std.log.debug("Evaluating test {s}", .{filePath});
        const file_content = try readFileContents(self.allocator, self.io, filePath);
        errdefer std.log.debug("Content of the test:\n{s}", .{file_content});

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const test_allocator = arena.allocator();

        var iterator = std.mem.splitSequence(u8, file_content, "---");
        const content = iterator.next() orelse return error.NO_CONTENT;
        errdefer std.log.debug("Evaluating content:\n{s}", .{content});

        var lexer = try Lexer.init(test_allocator, null, content);
        const tokens = try lexer.scanTokens();

        var parser = Parser.init(test_allocator, tokens, null);

        const expr = try parser.parse();

        const expected_tp = iterator.next() orelse return error.NO_EXPECTED_AST;

        const trimmed_expected_tp = std.mem.trim(u8, expected_tp, " \n");

        var type_checker = TypeChecker.init(test_allocator, null);
        const parsed_tp = try type_checker.inferType(expr);

        const printed_tp = try TypeChecker.PrettyPrinter.prettyPrint(test_allocator, type_checker.finalizeType(parsed_tp));
        const trimmed_printed_tp = std.mem.trim(u8, printed_tp, " \n");

        if (std.mem.eql(u8, trimmed_printed_tp, trimmed_expected_tp)) {
            return .pass;
        } else {
            const dup_path = try self.allocator.dupe(u8, filePath);
            const dup_expected = try self.allocator.dupe(u8, trimmed_expected_tp);
            const dup_got = try self.allocator.dupe(u8, trimmed_printed_tp);
            try failures.append(self.allocator, .{
                .file_path = dup_path,
                .expected = dup_expected,
                .got = dup_got,
            });
            return .fail;
        }
    }

    fn runFailTests(self: *Testing, failures: *std.ArrayList(Failure)) !TestsStats {
        var stats = TestsStats{
            .fail = 0,
            .pass = 0,
        };

        var saved_path = try std.fmt.allocPrint(self.allocator, "tests/typechecker/fail", .{});
        defer self.allocator.free(saved_path);

        var dir = try std.Io.Dir.cwd().openDir(self.io, saved_path, .{ .iterate = true });
        defer dir.close(self.io);

        var saved_iterator = dir.iterate();

        std.debug.print("  ", .{});
        while (try saved_iterator.next(self.io)) |entry| {
            switch (entry.kind) {
                .directory => {
                    const savedIterator = saved_iterator;
                    const savedPath = saved_path;

                    saved_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ savedPath, entry.name });

                    dir = try std.Io.Dir.cwd().openDir(self.io, saved_path, .{ .iterate = true });

                    saved_iterator = dir.iterate();

                    saved_path = savedPath;

                    saved_iterator = savedIterator;
                },
                .file => {
                    const file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ saved_path, entry.name });
                    defer self.allocator.free(file_path);

                    switch (try self.runFailTest(file_path, failures)) {
                        .pass => {
                            std.debug.print(ansi.green ++ "•" ++ ansi.reset, .{});
                            stats.pass += 1;
                        },
                        .fail => {
                            std.debug.print(ansi.red ++ "✗" ++ ansi.reset, .{});
                            stats.fail += 1;
                        },
                    }
                },
                else => {},
            }
        }
        std.debug.print("\n", .{});

        return stats;
    }

    fn runFailTest(self: *Testing, file_path: []const u8, failures: *std.ArrayList(Failure)) !TestStatus {
        errdefer std.log.debug("Evaluating test {s}", .{file_path});
        const file_content = try readFileContents(self.allocator, self.io, file_path);
        errdefer std.log.debug("Content of the test:\n{s}", .{file_content});

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const test_allocator = arena.allocator();

        var iterator = std.mem.splitSequence(u8, file_content, "---");
        const content = iterator.next() orelse return error.NO_CONTENT;
        errdefer std.log.debug("Evaluating content:\n{s}", .{content});

        var lexer = try Lexer.init(test_allocator, null, content);
        const tokens = try lexer.scanTokens();

        var parser = Parser.init(test_allocator, tokens, null);
        const expected_error = iterator.next() orelse return error.NO_EXPECTED_ERROR_CODE;

        const trimmed_error = std.mem.trim(u8, expected_error, " \n");

        const expr = try parser.parse();

        var type_checker = TypeChecker.init(test_allocator, null);

        const tp = type_checker.inferType(expr) catch |err| {
            if (std.mem.eql(u8, @errorName(err), trimmed_error)) {
                return .pass;
            } else {
                const dup_path = try self.allocator.dupe(u8, file_path);
                const dup_expected = try self.allocator.dupe(u8, trimmed_error);
                const dup_got = try self.allocator.dupe(u8, @errorName(err));
                try failures.append(self.allocator, .{
                    .file_path = dup_path,
                    .expected = dup_expected,
                    .got = dup_got,
                });
                return .fail;
            }
        };

        const printed_tp = try TypeChecker.PrettyPrinter.prettyPrint(test_allocator, type_checker.finalizeType(tp));
        const trimmed_printed_tp = std.mem.trim(u8, printed_tp, " \n");

        const dup_path = try self.allocator.dupe(u8, file_path);
        const dup_expected = try self.allocator.dupe(u8, trimmed_error);
        const dup_got = try self.allocator.dupe(u8, trimmed_printed_tp);
        try failures.append(self.allocator, .{
            .file_path = dup_path,
            .expected = dup_expected,
            .got = dup_got,
        });

        return .fail;
    }
};
