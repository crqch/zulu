const std = @import("std");

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

    EOF,
};

const Location = struct { line: usize, column: usize };

const Token = struct { type: TokenType, lexeme: []const u8, location: Location };

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

        try self.addToken(.IDENT);
    }

    fn string(self: *Lexer) !void {
        while (!self.isAtEnd() and self.peek() != '"') self.skip();

        if (self.isAtEnd() and self.source[self.current - 1] != '"') return error.UNTERMINATED_STRING_LITERAL;

        self.skip();

        try self.addToken(.STRING);
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

test "lexer - arithmetic operators and numbers" {
    const TestCase = struct {
        source: []const u8,
        expected: []const struct {
            .kind= TokenType,
            
        },
    };

    const cases = [_]TestCase{
        .{
            .source = "2 + 2 * 54 + .2",
            .expected = &.{
                .{ .kind = .NUMBER, .lexeme = "2" },
                .{ .kind = .PLUS, .lexeme = "+" },
                .{ .kind = .NUMBER, .lexeme = "2" },
                .{ .kind = .ASTERISK, .lexeme = "*" },
                .{ .kind = .NUMBER, .lexeme = "54" },
                .{ .kind = .PLUS, .lexeme = "+" },
                .{ .kind = .NUMBER, .lexeme = ".2" },
                .{ .kind = .EOF, .lexeme = "" },
            },
        },
        .{
            .source = "10.5 - 3",
            .expected = &.{
                .{ .kind = .NUMBER, .lexeme = "10.5" },
                .{ .kind = .MINUS, .lexeme = "-" },
                .{ .kind = .NUMBER, .lexeme = "3" },
                .{ .kind = .EOF, .lexeme = "" },
            },
        },
    };

    for (cases) |case| {
        var lexer = try Lexer.init(case.source);
        defer lexer.deinit();
        const tokens = lexer.scanTokens();

        for (case.expected, tokens) |expected_token, token| {
            try testing.expectEqual(expected_token.kind, token.kind);

            try testing.expectEqualStrings(expected_token.lexeme, token.lexeme);
        }
    }
}
