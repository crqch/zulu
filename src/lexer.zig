const std = @import("std");

const Lexer = @This();
const SharedContext = @import("./shared.zig");

allocator: std.mem.Allocator,
column: usize = 1,
current: usize = 0,
line: usize = 1,
source: []const u8,
start: usize = 0,
tokens: std.ArrayList(Token),
shared_context: ?*SharedContext,

const Location = struct { line: usize, column: usize };

pub const TokenType = enum {
    plus,
    minus,
    slash,
    asterisk,
    at,
    dot,
    comma,
    not_eq,
    eq,
    gt,
    lt,
    bang,
    pipe,
    semicolon,
    colon,

    gt_eq,
    lt_eq,
    not_eq_eq,
    eq_eq,
    slash_slash,

    arrow,

    lpar,
    rpar,
    lbra,
    rbra,
    lcur,
    rcur,

    ident,
    number,
    string,

    kw_and,
    kw_or,

    kw_true,
    kw_false,
    kw_if,
    kw_else,
    kw_match,
    kw_module,
    kw_type,
    kw_import,
    kw_of,
    kw_env,

    eof,
};

pub const Token = struct { type: TokenType, lexeme: []const u8, location: Location };

pub const LexerError = error{
    UnmatchedToken,
    UnterminatedStringLiteral,
    UnterminatedIdentLiteral,
    OutOfMemory,
};

const keywords = std.StaticStringMap(TokenType).initComptime(.{
    .{ "true", .kw_true },
    .{ "false", .kw_false },
    .{ "and", .kw_and },
    .{ "or", .kw_or },
    .{ "if", .kw_if },
    .{ "else", .kw_else },
    .{ "match", .kw_match },
    .{ "module", .kw_module },
    .{ "type", .kw_type },
    .{ "import", .kw_import },
    .{ "@env", .kw_env },
    .{ "of", .kw_of },
});

pub fn init(allocator: std.mem.Allocator, shared_context: ?*SharedContext, source: []const u8) !Lexer {
    return Lexer{
        .allocator = allocator,
        .shared_context = shared_context,
        .tokens = std.ArrayList(Token).initCapacity(allocator, 0) catch return LexerError.OutOfMemory,
        .source = source,
    };
}

pub fn deinit(self: *Lexer) void {
    self.tokens.deinit(self.allocator);
}

fn reallocateIdentifer(self: *Lexer, ident: []const u8) ![]const u8 {
    if (self.shared_context) |shared_context| {
        return try shared_context.allocator.dupe(u8, ident);
    }
    return ident;
}

pub fn scanTokens(self: *Lexer) LexerError![]Token {
    while (!self.isAtEnd()) {
        self.start = self.current;
        try self.scanToken();
    }

    self.start = self.current;
    try self.addToken(.eof);

    return self.tokens.items;
}

pub fn printTokens(self: *Lexer) LexerError![]const u8 {
    var buffer = std.ArrayList(u8).initCapacity(self.allocator, 0) catch return LexerError.OutOfMemory;

    for (self.tokens.items) |token| {
        switch (token.type) {
            .ident, .number, .string => {
                buffer.print(self.allocator, "{s} ( {s} )\n", .{ @tagName(token.type), token.lexeme }) catch return LexerError.OutOfMemory;
            },
            else => {
                buffer.print(self.allocator, "{s}\n", .{@tagName(token.type)}) catch return LexerError.OutOfMemory;
            },
        }
    }

    return buffer.items;
}

fn scanToken(self: *Lexer) LexerError!void {
    const char = self.advance();
    switch (char) {
        '+',
        '-',
        '/',
        '*',
        '@',
        '=',
        ':',
        '!',
        '|',
        '(',
        ')',
        '[',
        ']',
        '{',
        '}',
        ',',
        ';',
        '>',
        '<',
        '.',
        => {
            if (char == '.') {
                if (!self.isAtEnd() and std.ascii.isDigit(self.peek())) {
                    try self.number(char);
                    return;
                } else {
                    return try self.addToken(.dot);
                }
            }

            if (char == '@') {
                if (!self.isAtEnd() and (isValidIdentChar(self.peek()) or self.peek() == '"')) {
                    try self.identifier();
                    return;
                } else {
                    return try self.addToken(.at);
                }
            }

            return try self.addToken(switch (char) {
                '+' => .plus,
                '-' => .minus,
                '*' => .asterisk,
                ',' => .comma,
                '|' => .pipe,
                ':' => .colon,
                '/' => if (self.match('/')) .slash_slash else .slash,
                '>' => if (self.match('=')) .gt_eq else .gt,
                '<' => if (self.match('=')) .lt_eq else .lt,
                '=' => if (self.match('=')) .eq_eq else if (self.match('>')) .arrow else .eq,
                '!' => if (self.match('='))
                    (if (self.match('=')) .not_eq_eq else .not_eq)
                else
                    .bang,
                '(' => .lpar,
                ')' => .rpar,
                '[' => .lbra,
                ']' => .rbra,
                '{' => .lcur,
                '}' => .rcur,
                ';' => .semicolon,
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
            } else return LexerError.UnmatchedToken;
        },
    }
}

fn identifier(self: *Lexer) LexerError!void {
    if (self.peek() == '"') {
        self.skip();
        while (!self.isAtEnd() and self.peek() != '"' and self.peek() != '\n') self.skip();
        if (self.isAtEnd() or self.source[self.current] != '"') return LexerError.UnterminatedIdentLiteral;
        self.skip();
    } else {
        while (!self.isAtEnd() and (isValidIdentChar(self.peek()) or std.ascii.isDigit(self.peek()))) self.skip();
    }
    const lower = try lowerOfString(self.allocator, self.source[self.start..self.current]);
    defer self.allocator.free(lower);

    const token_type = keywords.get(lower) orelse .ident;
    try self.addToken(token_type);
    try self.maintainToken();
}

fn number(self: *Lexer, char: u8) LexerError!void {
    var point = char == '.';
    while (!self.isAtEnd() and std.ascii.isDigit(self.peek())) self.skip();

    if (!self.isAtEnd() and self.peek() == '.') {
        if (point) return LexerError.UnmatchedToken;
        point = true;
        self.skip();
        while (!self.isAtEnd() and std.ascii.isDigit(self.peek())) self.skip();
    }

    if (!self.isAtEnd() and self.peek() == '.') return LexerError.UnmatchedToken;

    try self.addToken(.number);
}

fn string(self: *Lexer) LexerError!void {
    var height: usize = 0;
    while (!self.isAtEnd() and (self.peek() != '"' or self.escapeCharacter())) {
        if (self.peek() == '\n') height += 1;
        self.skip();
    }

    if (self.isAtEnd() and self.source[self.current - 1] != '"') return LexerError.UnterminatedStringLiteral;

    self.skip();

    try self.addToken(.string);
    try self.maintainToken();

    self.line += height;
}

fn maintainToken(self: *Lexer) !void {
    if (self.tokens.pop()) |last_token| {
        const new_lexeme = try self.reallocateIdentifer(last_token.lexeme);
        try self.tokens.append(self.allocator, Token{
            .type = last_token.type,
            .lexeme = new_lexeme,
            .location = last_token.location,
        });
    }
}

fn addToken(self: *Lexer, tp: TokenType) LexerError!void {
    self.tokens.append(self.allocator, Token{ .type = tp, .lexeme = self.source[self.start..self.current], .location = Location{ .column = self.column, .line = self.line } }) catch return LexerError.OutOfMemory;
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
    return (std.ascii.isAlphabetic(char) or char == '@' or char == '#' or char == '\'' or char == '_');
}

fn lowerOfString(allocator: std.mem.Allocator, str: []const u8) LexerError![]u8 {
    var t = allocator.alloc(u8, str.len) catch return LexerError.OutOfMemory;

    for (str, 0..) |char, i| {
        t[i] = std.ascii.toLower(char);
    }

    return t;
}
