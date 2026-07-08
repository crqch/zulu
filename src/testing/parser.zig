const std = @import("std");
const zulu = @import("zulu");
const Parser = zulu.Parser;
const Lexer = zulu.Lexer;
const AstPrinter = zulu.AstPrinter;

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

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Testing {
        return Testing{
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn runTests(self: *Testing) !void {
        std.log.info("\nRunning OK tests...\n", .{});
        const okTests = try self.runOkTests();
        std.log.info("\nRunning FAIL tests...\n", .{});
        const failTests = try self.runFailTests();

        var allTests = TestsStats{
            .fail = 0,
            .pass = 0,
        };

        allTests.add(okTests);
        allTests.add(failTests);

        std.log.info("\nSummary of tests\nClass\tpassed\tfailed\nOK\t{d}\t{d}\nFAIL\t{d}\t{d}\nALL\t{d}\t{d}", .{
            okTests.pass,
            okTests.fail,

            failTests.pass,
            failTests.fail,

            allTests.pass,
            allTests.fail,
        });
    }

    fn runOkTests(self: *Testing) !TestsStats {
        var stats = TestsStats{
            .fail = 0,
            .pass = 0,
        };

        var path = try std.fmt.allocPrint(self.allocator, "tests/parser/ok", .{});

        var dir = try std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true });
        defer dir.close(self.io);

        var dir_iterator = dir.iterate();

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

                    switch (try self.runOkTest(filePath)) {
                        .pass => stats.pass += 1,
                        .fail => stats.fail += 1,
                    }

                    self.allocator.free(filePath);
                },
                else => {},
            }
        }

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

    fn runOkTest(self: *Testing, filePath: []const u8) !TestStatus {
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

        const parsedAst = try AstPrinter.prettyPrint(testAllocator, expr.*);
        const trimmedParsedAst = std.mem.trim(u8, parsedAst, " \n");

        const expectedAst = iterator.next() orelse return error.NO_EXPECTED_AST;

        const trimmedExpectedAst = std.mem.trim(u8, expectedAst, " \n");

        if (std.mem.eql(u8, trimmedParsedAst, trimmedExpectedAst)) {
            std.log.info("[+] {s}", .{filePath});
            return .pass;
        } else {
            std.log.err("[-] {s}\n\tGot ast:\n{s}\n\n\tExpected ast:\n{s}", .{ filePath, trimmedParsedAst, trimmedExpectedAst });
            return .fail;
        }
    }

    fn runFailTests(self: *Testing) !TestsStats {
        var stats = TestsStats{
            .fail = 0,
            .pass = 0,
        };

        var path = try std.fmt.allocPrint(self.allocator, "tests/parser/fail", .{});

        var dir = try std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true });
        defer dir.close(self.io);

        var dir_iterator = dir.iterate();

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

                    switch (try self.runFailTest(filePath)) {
                        .pass => stats.pass += 1,
                        .fail => stats.fail += 1,
                    }

                    self.allocator.free(filePath);
                },
                else => {},
            }
        }

        return stats;
    }

    fn runFailTest(self: *Testing, filePath: []const u8) !TestStatus {
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

        const expr = parser.parse() catch |err| {
            if (std.mem.eql(u8, @errorName(err), trimmedError)) {
                std.log.info("[+] {s}", .{filePath});
                return .pass;
            } else {
                std.log.err("[-] {s}\n\tGot error:\n{s}\n\n\tExpected error:\n{s}", .{
                    filePath,
                    @errorName(err),
                    trimmedError,
                });
                return .fail;
            }
        };

        const parsedAst = try AstPrinter.prettyPrint(testAllocator, expr.*);
        const trimmedParsedAst = std.mem.trim(u8, parsedAst, " \n");

        std.log.err("[-] {s}\n\tGot ast:\n{s}\n\n\tExpected error:\n{s}", .{
            filePath,
            trimmedParsedAst,
            trimmedError,
        });

        return .fail;
    }
};
