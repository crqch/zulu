const std = @import("std");
const testing = @import("std").testing;

const TokenType = enum {
    PLUS,
    MINUS,
    SLASH,
    ASTERISK,
    DOT,
    EQ,
    GT,
    LT,
    SEMICOLON,

    GTEQ,
    LTEQ,
    EQEQ,
    SLASHSLASH,

    LPAR,
    RPAR,
    LBRA,
    RBRA,

    IDENT,
    NUMBER,
    STRING,

    KW_TRUE,
    KW_FALSE,
    KW_IF,
    KW_ELSE,

    EOF,
};

const Location = struct { line: usize, column: usize };

const Token = struct { type: TokenType, lexeme: []const u8, location: Location };

const keywords = std.StaticStringMap(TokenType).initComptime(.{
    .{ "true", .KW_TRUE },
    .{ "false", .KW_FALSE },
    .{ "if", .KW_IF },
    .{ "else", .KW_ELSE },
});

pub const Lexer = struct {
    allocator: std.mem.Allocator,
    tokens: std.ArrayList(Token),
    source: []const u8,
    start: usize = 0,
    current: usize = 0,
    line: usize = 1,
    column: usize = 1,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) !Lexer {
        return Lexer{ .allocator = allocator, .tokens = try std.ArrayList(Token).initCapacity(allocator, 0), .source = source };
    }

    pub fn deinit(self: *Lexer) void {
        self.tokens.deinit(self.allocator);
    }

    pub fn scanTokens(self: *Lexer) ![]Token {
        while (!self.isAtEnd()) {
            self.start = self.current;
            try self.scanToken();
        }

        self.start = self.current;
        try self.addToken(.EOF);

        return self.tokens.items;
    }

    fn scanToken(self: *Lexer) !void {
        const char = self.advance();
        switch (char) {
            '+', '-', '/', '*', '=', '(', ')', '[', ']', ';', '>', '<' => {
                return try self.addToken(switch (char) {
                    '+' => .PLUS,
                    '-' => .MINUS,
                    '*' => .ASTERISK,
                    '/' => if (self.match('/')) .SLASHSLASH else .SLASH,
                    '>' => if (self.match('=')) .GTEQ else .GT,
                    '<' => if (self.match('=')) .LTEQ else .LT,
                    '=' => if (self.match('=')) .EQEQ else .EQ,
                    '(' => .LPAR,
                    ')' => .RPAR,
                    '[' => .LBRA,
                    ']' => .RBRA,
                    ';' => .SEMICOLON,
                    else => .EOF,
                });
            },
            else => {
                if (std.ascii.isDigit(char) or char == '.') {
                    try self.number(char);
                } else if (isValidIdentChar(char)) {
                    try self.identifier();
                } else if (char == '"') {
                    try self.string();
                } else if (std.ascii.isWhitespace(char)) {
                    if (char == '\n') {
                        self.line += 1;
                        self.column = 1;
                    } else {
                        self.column += 1;
                    }
                } else return error.UNMATCHED_TOKEN;
            },
        }
    }

    fn number(self: *Lexer, char: u8) !void {
        var point = char == '.';
        while (!self.isAtEnd() and std.ascii.isDigit(self.peek())) self.skip();

        if (!self.isAtEnd() and self.peek() == '.') {
            if (point) return error.UNMATCHED_TOKEN;
            point = true;
            self.skip();
            while (std.ascii.isDigit(self.peek())) self.skip();
        }

        if (!self.isAtEnd() and self.peek() == '.') return error.UNMATCHED_TOKEN;

        try self.addToken(.NUMBER);
    }

    fn identifier(self: *Lexer) !void {
        while (!self.isAtEnd() and (isValidIdentChar(self.peek()) or std.ascii.isDigit(self.peek()))) self.skip();
        const lower = try lowerOfString(self.allocator, self.source[self.start..self.current]);
        defer self.allocator.free(lower);

        const tokenType = keywords.get(lower) orelse .IDENT;
        try self.addToken(tokenType);
    }

    fn string(self: *Lexer) !void {
        var height: usize = 0;
        while (!self.isAtEnd() and (self.peek() != '"' or self.escapeCharacter())) {
            if (self.peek() == '\n') height += 1;
            self.skip();
        }

        if (self.isAtEnd() and self.source[self.current - 1] != '"') return error.UNTERMINATED_STRING_LITERAL;

        self.skip();

        try self.addToken(.STRING);

        self.line += height;
    }

    fn escapeCharacter(self: *Lexer) bool {
        if (self.current < 1) return false;
        return self.source[self.current - 1] == '\\';
    }

    fn peek(self: *Lexer) u8 {
        return self.source[self.current];
    }

    fn match(self: *Lexer, char: u8) bool {
        if (self.peek() == char) {
            self.current += 1;
            return true;
        }
        return false;
    }

    fn advance(self: *Lexer) u8 {
        self.current += 1;
        return self.source[self.current - 1];
    }

    fn skip(self: *Lexer) void {
        self.current += 1;
    }

    fn addToken(self: *Lexer, tp: TokenType) !void {
        try self.tokens.append(self.allocator, Token{ .type = tp, .lexeme = self.source[self.start..self.current], .location = Location{ .column = self.column, .line = self.line } });
        self.column += self.current - self.start;
    }

    fn isAtEnd(self: *Lexer) bool {
        return self.current == self.source.len;
    }
};

fn isValidIdentChar(char: u8) bool {
    return (std.ascii.isAlphabetic(char) or char == '@' or char == '!' or char == '#' or char == '_');
}

fn lowerOfString(allocator: std.mem.Allocator, str: []const u8) ![]u8 {
    var t = try allocator.alloc(u8, str.len);

    for (str, 0..) |char, i| {
        t[i] = std.ascii.toLower(char);
    }

    return t;
}

const Testing = struct {
    cases: []const TestCase,

    pub const TestCase = struct {
        source: []const u8,
        expected: []const struct {
            type: TokenType,
            lexeme: []const u8,
        },
    };

    pub fn init(_cases: []const TestCase) Testing {
        return Testing{ .cases = _cases };
    }

    pub fn runTests(self: *Testing) !void {
        for (self.cases) |case| {
            var lexer = try Lexer.init(std.testing.allocator, case.source);
            defer lexer.deinit();
            const tokens = try lexer.scanTokens();

            for (case.expected, tokens) |expected_token, token| {
                try testing.expectEqual(expected_token.type, token.type);

                try testing.expectEqualStrings(expected_token.lexeme, token.lexeme);
            }
        }
    }
};

test "lexer - arithmetic operators and numbers" {
    var tsting = Testing.init(&[_]Testing.TestCase{
        .{
            .source = "2 + 2 * 54 + .2",
            .expected = &.{
                .{ .type = .NUMBER, .lexeme = "2" },
                .{ .type = .PLUS, .lexeme = "+" },
                .{ .type = .NUMBER, .lexeme = "2" },
                .{ .type = .ASTERISK, .lexeme = "*" },
                .{ .type = .NUMBER, .lexeme = "54" },
                .{ .type = .PLUS, .lexeme = "+" },
                .{ .type = .NUMBER, .lexeme = ".2" },
                .{ .type = .EOF, .lexeme = "" },
            },
        },
        .{
            .source = "10.5 - 3",
            .expected = &.{
                .{ .type = .NUMBER, .lexeme = "10.5" },
                .{ .type = .MINUS, .lexeme = "-" },
                .{ .type = .NUMBER, .lexeme = "3" },
                .{ .type = .EOF, .lexeme = "" },
            },
        },
    });

    try tsting.runTests();
}

test "lexer - variable declarations and closures" {
    var tsting = Testing.init(&[_]Testing.TestCase{
        .{
            .source = "x=10;y=20;x+y*4",
            .expected = &.{
                .{ .type = .IDENT, .lexeme = "x" },
                .{ .type = .EQ, .lexeme = "=" },
                .{ .type = .NUMBER, .lexeme = "10" },
                .{ .type = .SEMICOLON, .lexeme = ";" },

                .{ .type = .IDENT, .lexeme = "y" },
                .{ .type = .EQ, .lexeme = "=" },
                .{ .type = .NUMBER, .lexeme = "20" },
                .{ .type = .SEMICOLON, .lexeme = ";" },

                .{ .type = .IDENT, .lexeme = "x" },
                .{ .type = .PLUS, .lexeme = "+" },
                .{ .type = .IDENT, .lexeme = "y" },
                .{ .type = .ASTERISK, .lexeme = "*" },
                .{ .type = .NUMBER, .lexeme = "4" },
                .{ .type = .EOF, .lexeme = "" },
            },
        },
        .{
            .source = "x=10;y=20;z=x>=y",
            .expected = &.{
                .{ .type = .IDENT, .lexeme = "x" },
                .{ .type = .EQ, .lexeme = "=" },
                .{ .type = .NUMBER, .lexeme = "10" },
                .{ .type = .SEMICOLON, .lexeme = ";" },

                .{ .type = .IDENT, .lexeme = "y" },
                .{ .type = .EQ, .lexeme = "=" },
                .{ .type = .NUMBER, .lexeme = "20" },
                .{ .type = .SEMICOLON, .lexeme = ";" },

                .{ .type = .IDENT, .lexeme = "z" },
                .{ .type = .EQ, .lexeme = "=" },
                .{ .type = .IDENT, .lexeme = "x" },
                .{ .type = .GTEQ, .lexeme = ">=" },
                .{ .type = .IDENT, .lexeme = "y" },
                .{ .type = .EOF, .lexeme = "" },
            },
        },
        .{
            .source = "[f x y;f x * f y] [x; x*x] 2 4",
            .expected = &.{
                .{ .type = .LBRA, .lexeme = "[" },
                .{ .type = .IDENT, .lexeme = "f" },
                .{ .type = .IDENT, .lexeme = "x" },
                .{ .type = .IDENT, .lexeme = "y" },
                .{ .type = .SEMICOLON, .lexeme = ";" },
                .{ .type = .IDENT, .lexeme = "f" },
                .{ .type = .IDENT, .lexeme = "x" },
                .{ .type = .ASTERISK, .lexeme = "*" },
                .{ .type = .IDENT, .lexeme = "f" },
                .{ .type = .IDENT, .lexeme = "y" },
                .{ .type = .RBRA, .lexeme = "]" },

                .{ .type = .LBRA, .lexeme = "[" },
                .{ .type = .IDENT, .lexeme = "x" },
                .{ .type = .SEMICOLON, .lexeme = ";" },
                .{ .type = .IDENT, .lexeme = "x" },
                .{ .type = .ASTERISK, .lexeme = "*" },
                .{ .type = .IDENT, .lexeme = "x" },
                .{ .type = .RBRA, .lexeme = "]" },
                .{ .type = .NUMBER, .lexeme = "2" },
                .{ .type = .NUMBER, .lexeme = "4" },

                .{ .type = .EOF, .lexeme = "" },
            },
        },
    });

    try tsting.runTests();
}

test "lexer - string literals" {
    var tsting = Testing.init(&[_]Testing.TestCase{
        .{
            .source = "\"test\"",
            .expected = &.{
                .{ .type = .STRING, .lexeme = "\"test\"" },
                .{ .type = .EOF, .lexeme = "" },
            },
        },
        .{
            .source = "\"test\n\\n\\\"<-- this is a \\\" inside a string literal!\"",
            .expected = &.{
                .{ .type = .STRING, .lexeme = "\"test\n\\n\\\"<-- this is a \\\" inside a string literal!\"" },
                .{ .type = .EOF, .lexeme = "" },
            },
        },
    });

    try tsting.runTests();
}

test "lexer - identifiers and keywords" {
    var tsting = Testing.init(&[_]Testing.TestCase{
        .{
            .source = "test @x _x !x #x x#test x!@##",
            .expected = &.{
                .{ .type = .IDENT, .lexeme = "test" },
                .{ .type = .IDENT, .lexeme = "@x" },
                .{ .type = .IDENT, .lexeme = "_x" },
                .{ .type = .IDENT, .lexeme = "!x" },
                .{ .type = .IDENT, .lexeme = "#x" },
                .{ .type = .IDENT, .lexeme = "x#test" },
                .{ .type = .IDENT, .lexeme = "x!@##" },
                .{ .type = .EOF, .lexeme = "" },
            },
        },
        .{
            .source = "test else if true x @yz false",
            .expected = &.{
                .{ .type = .IDENT, .lexeme = "test" },
                .{ .type = .KW_ELSE, .lexeme = "else" },
                .{ .type = .KW_IF, .lexeme = "if" },
                .{ .type = .KW_TRUE, .lexeme = "true" },
                .{ .type = .IDENT, .lexeme = "x" },
                .{ .type = .IDENT, .lexeme = "@yz" },
                .{ .type = .KW_FALSE, .lexeme = "false" },
                .{ .type = .EOF, .lexeme = "" },
            },
        },
        .{
            .source = "test ELSE IF TruE",
            .expected = &.{
                .{ .type = .IDENT, .lexeme = "test" },
                .{ .type = .KW_ELSE, .lexeme = "ELSE" },
                .{ .type = .KW_IF, .lexeme = "IF" },
                .{ .type = .KW_TRUE, .lexeme = "TruE" },
                .{ .type = .EOF, .lexeme = "" },
            },
        },
    });

    try tsting.runTests();
}
