const std = @import("std");

const Lexer = @This();

allocator: std.mem.Allocator,
column: usize = 1,
current: usize = 0,
line: usize = 1,
source: []const u8,
start: usize = 0,
tokens: std.ArrayList(Token),

const Location = struct { line: usize, column: usize };

pub const TokenType = enum {
    PLUS,
    MINUS,
    SLASH,
    ASTERISK,
    DOT,
    COMMA,
    NOTEQ,
    EQ,
    GT,
    LT,
    BANG,
    PIPE,
    SEMICOLON,

    GTEQ,
    LTEQ,
    NOTEQEQ,
    EQEQ,
    SLASHSLASH,

    ARROW,

    LPAR,
    RPAR,
    LBRA,
    RBRA,
    LCUR,
    RCUR,

    IDENT,
    NUMBER,
    STRING,

    KW_AND,
    KW_OR,

    KW_TRUE,
    KW_FALSE,
    KW_IF,
    KW_ELSE,
    KW_MATCH,
    KW_MOD,

    EOF,
};

pub const Token = struct { type: TokenType, lexeme: []const u8, location: Location };

pub const LexerError = error{
    UNMATCHED_TOKEN,
    UNTERMINATED_STRING_LITERAL,
    OUT_OF_MEMORY,
};

const keywords = std.StaticStringMap(TokenType).initComptime(.{
    .{ "true", .KW_TRUE },
    .{ "false", .KW_FALSE },
    .{ "and", .KW_AND },
    .{ "or", .KW_OR },
    .{ "if", .KW_IF },
    .{ "else", .KW_ELSE },
    .{ "match", .KW_MATCH },
    .{ "mod", .KW_MOD },
});

pub fn init(allocator: std.mem.Allocator, source: []const u8) !Lexer {
    return Lexer{ .allocator = allocator, .tokens = std.ArrayList(Token).initCapacity(allocator, 0) catch return LexerError.OUT_OF_MEMORY, .source = source };
}

pub fn deinit(self: *Lexer) void {
    self.tokens.deinit(self.allocator);
}

pub fn scanTokens(self: *Lexer) LexerError![]Token {
    while (!self.isAtEnd()) {
        self.start = self.current;
        try self.scanToken();
    }

    self.start = self.current;
    try self.addToken(.EOF);

    return self.tokens.items;
}

pub fn printTokens(self: *Lexer) LexerError![]const u8 {
    var buffer = std.ArrayList(u8).initCapacity(self.allocator, 0) catch return LexerError.OUT_OF_MEMORY;

    for (self.tokens.items) |token| {
        switch (token.type) {
            .IDENT, .NUMBER, .STRING => {
                buffer.print(self.allocator, "{s} ( {s} )\n", .{ @tagName(token.type), token.lexeme }) catch return LexerError.OUT_OF_MEMORY;
            },
            else => {
                buffer.print(self.allocator, "{s}\n", .{@tagName(token.type)}) catch return LexerError.OUT_OF_MEMORY;
            },
        }
    }

    return buffer.items;
}

fn scanToken(self: *Lexer) LexerError!void {
    const char = self.advance();
    switch (char) {
        '+', '-', '/', '*', '=', '!', '|', '(', ')', '[', ']', '{', '}', ',', ';', '>', '<', '.' => {
            if (char == '.') {
                if (!self.isAtEnd() and std.ascii.isDigit(self.peek())) {
                    try self.number(char);
                    return;
                } else {
                    return try self.addToken(.DOT);
                }
            }

            return try self.addToken(switch (char) {
                '+' => .PLUS,
                '-' => .MINUS,
                '*' => .ASTERISK,
                ',' => .COMMA,
                '|' => .PIPE,
                '/' => if (self.match('/')) .SLASHSLASH else .SLASH,
                '>' => if (self.match('=')) .GTEQ else .GT,
                '<' => if (self.match('=')) .LTEQ else .LT,
                '=' => if (self.match('=')) .EQEQ else if (self.match('>')) .ARROW else .EQ,
                '!' => if (self.match('='))
                    (if (self.match('=')) .NOTEQEQ else .NOTEQ)
                else
                    .BANG,
                '(' => .LPAR,
                ')' => .RPAR,
                '[' => .LBRA,
                ']' => .RBRA,
                '{' => .LCUR,
                '}' => .RCUR,
                ';' => .SEMICOLON,
                else => unreachable,
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
            } else return LexerError.UNMATCHED_TOKEN;
        },
    }
}

fn identifier(self: *Lexer) LexerError!void {
    while (!self.isAtEnd() and (isValidIdentChar(self.peek()) or std.ascii.isDigit(self.peek()))) self.skip();
    const lower = try lowerOfString(self.allocator, self.source[self.start..self.current]);
    defer self.allocator.free(lower);

    const tokenType = keywords.get(lower) orelse .IDENT;
    try self.addToken(tokenType);
}

fn number(self: *Lexer, char: u8) LexerError!void {
    var point = char == '.';
    while (!self.isAtEnd() and std.ascii.isDigit(self.peek())) self.skip();

    if (!self.isAtEnd() and self.peek() == '.') {
        if (point) return LexerError.UNMATCHED_TOKEN;
        point = true;
        self.skip();
        while (!self.isAtEnd() and std.ascii.isDigit(self.peek())) self.skip();
    }

    if (!self.isAtEnd() and self.peek() == '.') return LexerError.UNMATCHED_TOKEN;

    try self.addToken(.NUMBER);
}

fn string(self: *Lexer) LexerError!void {
    var height: usize = 0;
    while (!self.isAtEnd() and (self.peek() != '"' or self.escapeCharacter())) {
        if (self.peek() == '\n') height += 1;
        self.skip();
    }

    if (self.isAtEnd() and self.source[self.current - 1] != '"') return LexerError.UNTERMINATED_STRING_LITERAL;

    self.skip();

    try self.addToken(.STRING);

    self.line += height;
}

fn addToken(self: *Lexer, tp: TokenType) LexerError!void {
    self.tokens.append(self.allocator, Token{ .type = tp, .lexeme = self.source[self.start..self.current], .location = Location{ .column = self.column, .line = self.line } }) catch return LexerError.OUT_OF_MEMORY;
    self.column += self.current - self.start;
}

fn advance(self: *Lexer) u8 {
    self.current += 1;
    return self.source[self.current - 1];
}

fn escapeCharacter(self: *Lexer) bool {
    if (self.current < 1) return false;
    return self.source[self.current - 1] == '\\';
}

fn isAtEnd(self: *Lexer) bool {
    return self.current == self.source.len;
}

fn peek(self: *Lexer) u8 {
    return self.source[self.current];
}

fn match(self: *Lexer, char: u8) bool {
    if (self.isAtEnd()) return false;
    if (self.peek() == char) {
        self.current += 1;
        return true;
    }
    return false;
}

fn skip(self: *Lexer) void {
    self.current += 1;
}

fn isValidIdentChar(char: u8) bool {
    return (std.ascii.isAlphabetic(char) or char == '@' or char == '#' or char == '_');
}

fn lowerOfString(allocator: std.mem.Allocator, str: []const u8) LexerError![]u8 {
    var t = allocator.alloc(u8, str.len) catch return LexerError.OUT_OF_MEMORY;

    for (str, 0..) |char, i| {
        t[i] = std.ascii.toLower(char);
    }

    return t;
}
