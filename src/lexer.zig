const std = @import("std");

const TokenType = enum { PLUS, MINUS, ASTERISK, SLASH, EQ, NUMBER, EOF };

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

        try self.addToken(.EOF);

        return self.tokens.items;
    }

    fn scanToken(self: *Lexer) !void {
        const char = self.advance();
        switch (char) {
            '+', '-', '/', '*', '=' => {
                return try self.addToken(switch (char) {
                    '+' => .PLUS,
                    '-' => .MINUS,
                    '*' => .ASTERISK,
                    '/' => .SLASH,
                    '=' => .EQ,
                    else => .EOF,
                });
            },
            else => {
                if (std.ascii.isDigit(char)) try self.digit() else if (std.ascii.isWhitespace(char)) {
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

    fn digit(self: *Lexer) !void {
        while (std.ascii.isDigit(self.peek())) self.skip();
        try self.addToken(.NUMBER);
    }

    fn peek(self: *Lexer) u8 {
        return self.source[self.current];
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
