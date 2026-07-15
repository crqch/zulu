const std = @import("std");

const zulu = @import("zulu");
const Lexer = zulu.Lexer;
const Parser = zulu.Parser;
const TypeChecker = zulu.TypeChecker;
const AstPrinter = zulu.AstPrinter;

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
        const passTests = try self.runPassTests(&failures);

        std.debug.print("\n" ++ ansi.bold ++ ansi.blue ++ "· Running FAIL tests (parsing invalid programs)..." ++ ansi.reset ++ "\n", .{});
        const failTests = try self.runFailTests(&failures);

        var allTests = TestsStats{
            .fail = 0,
            .pass = 0,
        };

        allTests.add(passTests);
        allTests.add(failTests);

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
        std.debug.print(bold ++ "│" ++ reset ++ " Expected Pass   " ++ bold ++ "│ " ++ green ++ "{d:<12}" ++ reset ++ bold ++ " │ " ++ red ++ "{d:<11}" ++ bold ++ reset ++ " │" ++ reset ++ "\n", .{ passTests.pass, passTests.fail });
        std.debug.print(bold ++ "│" ++ reset ++ " Expected Fail   " ++ bold ++ "│ " ++ green ++ "{d:<12}" ++ reset ++ bold ++ " │ " ++ red ++ "{d:<11}" ++ bold ++ reset ++ " │" ++ reset ++ "\n", .{ failTests.pass, failTests.fail });
        std.debug.print(bold ++ "├─────────────────┼──────────────┼─────────────┤" ++ reset ++ "\n", .{});
        std.debug.print(bold ++ "│" ++ reset ++ " Total           " ++ bold ++ "│ " ++ green ++ "{d:<12}" ++ reset ++ bold ++ " │ " ++ red ++ "{d:<11}" ++ bold ++ reset ++ " │" ++ reset ++ "\n", .{ allTests.pass, allTests.fail });
        std.debug.print(bold ++ "└─────────────────┴──────────────┴─────────────┘" ++ reset ++ "\n", .{});
    }

    fn runPassTests(self: *Testing, failures: *std.ArrayList(Failure)) !TestsStats {
        var stats = TestsStats{
            .fail = 0,
            .pass = 0,
        };

        var path = try std.fmt.allocPrint(self.allocator, "tests/typechecker/pass", .{});
        defer self.allocator.free(path);

        var dir = try std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true });
        defer dir.close(self.io);

        var dir_iterator = dir.iterate();

        std.debug.print("  ", .{});
        while (try dir_iterator.next(self.io)) |entry| {
            switch (entry.kind) {
                .directory => {
                    const savedIterator = dir_iterator;
                    const savedPath = path;

                    path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ savedPath, entry.name });

                    dir = try std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true });

                    dir_iterator = dir.iterate();

                    path = savedPath;

                    dir_iterator = savedIterator;
                },
                .file => {
                    const filePath = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ path, entry.name });
                    defer self.allocator.free(filePath);

                    switch (try self.runPassTest(filePath, failures)) {
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

    fn readFileContents(self: *Testing, filePath: []const u8) ![]const u8 {
        var file = try std.Io.Dir.cwd().openFile(self.io, filePath, .{ .mode = .read_only });
        defer file.close(self.io);

        var fileReader = file.reader(self.io, &.{});

        const maxFileSize = 1024 * 1024 * 10;
        const contents = fileReader.interface.allocRemaining(self.allocator, .limited(maxFileSize));

        return contents;
    }

    fn runPassTest(self: *Testing, filePath: []const u8, failures: *std.ArrayList(Failure)) !TestStatus {
        errdefer std.log.debug("Evaluating test {s}", .{filePath});
        const fileContent = try self.readFileContents(filePath);
        errdefer std.log.debug("Content of the test:\n{s}", .{fileContent});

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const testAllocator = arena.allocator();

        var iterator = std.mem.splitSequence(u8, fileContent, "---");
        const content = iterator.next() orelse return error.NO_CONTENT;
        errdefer std.log.debug("Evaluating content:\n{s}", .{content});

        var lexer = try Lexer.init(testAllocator, content);
        const tokens = try lexer.scanTokens();

        var parser = Parser.init(testAllocator, tokens);

        const expr = try parser.parse();

        const expectedTp = iterator.next() orelse return error.NO_EXPECTED_AST;

        const trimmedExpectedTp = std.mem.trim(u8, expectedTp, " \n");

        var typeChecker = TypeChecker.init(testAllocator);
        const parsedTp = try typeChecker.inferType(expr);

        const printedTp = try TypeChecker.PrettyPrinter.prettyPrint(testAllocator, typeChecker.finalizeType(parsedTp).*);
        const trimmedPrintedTp = std.mem.trim(u8, printedTp, " \n");

        if (std.mem.eql(u8, trimmedPrintedTp, trimmedExpectedTp)) {
            return .pass;
        } else {
            const dup_path = try self.allocator.dupe(u8, filePath);
            const dup_expected = try self.allocator.dupe(u8, trimmedExpectedTp);
            const dup_got = try self.allocator.dupe(u8, trimmedPrintedTp);
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

        var path = try std.fmt.allocPrint(self.allocator, "tests/typechecker/fail", .{});
        defer self.allocator.free(path);

        var dir = try std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true });
        defer dir.close(self.io);

        var dir_iterator = dir.iterate();

        std.debug.print("  ", .{});
        while (try dir_iterator.next(self.io)) |entry| {
            switch (entry.kind) {
                .directory => {
                    const savedIterator = dir_iterator;
                    const savedPath = path;

                    path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ savedPath, entry.name });

                    dir = try std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true });

                    dir_iterator = dir.iterate();

                    path = savedPath;

                    dir_iterator = savedIterator;
                },
                .file => {
                    const filePath = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ path, entry.name });
                    defer self.allocator.free(filePath);

                    switch (try self.runFailTest(filePath, failures)) {
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

    fn runFailTest(self: *Testing, filePath: []const u8, failures: *std.ArrayList(Failure)) !TestStatus {
        errdefer std.log.debug("Evaluating test {s}", .{filePath});
        const fileContent = try self.readFileContents(filePath);
        errdefer std.log.debug("Content of the test:\n{s}", .{fileContent});

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const testAllocator = arena.allocator();

        var iterator = std.mem.splitSequence(u8, fileContent, "---");
        const content = iterator.next() orelse return error.NO_CONTENT;
        errdefer std.log.debug("Evaluating content:\n{s}", .{content});

        var lexer = try Lexer.init(testAllocator, content);
        const tokens = try lexer.scanTokens();

        var parser = Parser.init(testAllocator, tokens);
        const expectedError = iterator.next() orelse return error.NO_EXPECTED_ERROR_CODE;

        const trimmedError = std.mem.trim(u8, expectedError, " \n");

        const expr = try parser.parse();

        var typeChecker = TypeChecker.init(testAllocator);

        const tp = typeChecker.inferType(expr) catch |err| {
            if (std.mem.eql(u8, @errorName(err), trimmedError)) {
                return .pass;
            } else {
                const dup_path = try self.allocator.dupe(u8, filePath);
                const dup_expected = try self.allocator.dupe(u8, trimmedError);
                const dup_got = try self.allocator.dupe(u8, @errorName(err));
                try failures.append(self.allocator, .{
                    .file_path = dup_path,
                    .expected = dup_expected,
                    .got = dup_got,
                });
                return .fail;
            }
        };

        const printedTp = try TypeChecker.PrettyPrinter.prettyPrint(testAllocator, typeChecker.finalizeType(tp).*);
        const trimmedPrintedTp = std.mem.trim(u8, printedTp, " \n");

        const dup_path = try self.allocator.dupe(u8, filePath);
        const dup_expected = try self.allocator.dupe(u8, trimmedError);
        const dup_got = try self.allocator.dupe(u8, trimmedPrintedTp);
        try failures.append(self.allocator, .{
            .file_path = dup_path,
            .expected = dup_expected,
            .got = dup_got,
        });

        return .fail;
    }
};
