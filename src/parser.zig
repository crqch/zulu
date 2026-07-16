const std = @import("std");

const ast = @import("ast.zig");
const Expression = ast.Expression;
const Bop = ast.Bop;
const lexer = @import("lexer.zig");
const Token = lexer.Token;
const TokenType = lexer.TokenType;

const Parser = @This();

allocator: std.mem.Allocator,
current: usize = 0,
tokens: []Token,

const Precedence = struct {
    pub const none: u8 = 0;
    pub const assignment: u8 = 10; // =
    pub const logic_or: u8 = 20; //   or
    pub const logic_and: u8 = 30; //  and
    pub const equality: u8 = 40; //   ==, !=
    pub const comparison: u8 = 50; // <, >, <=, >=
    pub const term: u8 = 60; //       +, -
    pub const factor: u8 = 70; //     *, /
    pub const unary: u8 = 80; //      !, -
    pub const call: u8 = 90; //       (), application
};

pub const ParserError = error{
    EOF_NOT_REACHED,
    EXPECTED_VARIABLE_AT_DECLARATION,
    LAMBDA_UNRESOLVED,
    EXPECTED_EXPRESSION,
    PARENTHESES_UNMATCHED,
    UNKNOWN_ESCAPE_CHARACTER,
    NOT_A_BINARY_OPERATION,
    OUT_OF_MEMORY,
    UNEXPECTED_TOKEN,
};

const PrefixParselet = *const fn (self: *Parser) ParserError!*Expression;

const InfixParselet = struct {
    precedence: u8,
    led: *const fn (self: *Parser, left: *Expression, precedence: u8) ParserError!*Expression,
};

pub fn init(allocator: std.mem.Allocator, tokens: []Token) Parser {
    return Parser{ .allocator = allocator, .tokens = tokens };
}

pub fn parse(self: *Parser) ParserError!*Expression {
    const expr = try self.parseExpression(Precedence.none);
    if (!self.matchToken(.EOF)) return error.EOF_NOT_REACHED;
    return expr;
}

fn parseExpression(self: *Parser, minBp: u8) ParserError!*Expression {
    var left = try self.nud();

    while (true) {
        if (self.isAtPrimaryStart() and Precedence.call > minBp) {
            left = try self.applicationLed(left);
            continue;
        }
        const entry = led(self.tokens[self.current].type) orelse break;
        if (entry.precedence <= minBp) break;
        self.current += 1;
        left = try entry.led(self, left, entry.precedence);
    }
    return left;
}

fn nud(self: *Parser) ParserError!*Expression {
    const token = self.tokens[self.current];
    self.current += 1;
    return switch (token.type) {
        .NUMBER => self.numberNud(),
        .STRING => self.stringNud(),
        .IDENT => self.identNud(),
        .KW_TRUE, .KW_FALSE => self.boolNud(),
        .MINUS => self.unaryMinusNud(),
        .BANG => self.notNud(),
        .LPAR => self.groupNud(),
        .LBRA => self.lambdaNud(),
        .KW_IF => self.ifNud(),
        else => error.EXPECTED_EXPRESSION,
    };
}

fn numberNud(self: *Parser) ParserError!*Expression {
    return try self.newExpression(Expression{
        .Number = self.previousToken().lexeme,
    });
}

fn stringNud(self: *Parser) ParserError!*Expression {
    return try self.newExpression(Expression{
        .String = try self.stringOfLexeme(self.previousToken().lexeme),
    });
}

fn identNud(self: *Parser) ParserError!*Expression {
    return try self.newExpression(Expression{
        .Variable = self.previousToken().lexeme,
    });
}

fn boolNud(self: *Parser) ParserError!*Expression {
    return try self.newExpression(Expression{
        .Boolean = self.previousToken().type == .KW_TRUE,
    });
}

fn unaryMinusNud(self: *Parser) ParserError!*Expression {
    return try self.newExpression(Expression{ .UnaryMinus = try self.parseExpression(Precedence.unary) });
}

fn notNud(self: *Parser) ParserError!*Expression {
    return try self.newExpression(Expression{
        .Not = try self.parseExpression(Precedence.unary),
    });
}

fn groupNud(self: *Parser) ParserError!*Expression {
    const innerExpression = try self.parseExpression(Precedence.none);

    self.expect(.RPAR) catch return ParserError.PARENTHESES_UNMATCHED;
    return innerExpression;
}

fn lambdaNud(self: *Parser) ParserError!*Expression {
    self.slide(.SEMICOLON) catch return ParserError.LAMBDA_UNRESOLVED;
    const semicolonIndex = self.current - 1;
    var lambda = try self.parseExpression(Precedence.none);

    self.expect(.RBRA) catch return ParserError.LAMBDA_UNRESOLVED;
    const endIndex = self.current;

    self.current = semicolonIndex - 1;

    while (self.tokens[self.current].type != .LBRA) : (self.current -= 1) {
        self.expect(.IDENT) catch return ParserError.LAMBDA_UNRESOLVED;
        self.current -= 1;
        lambda = try self.newExpression(Expression{ .Lambda = .{
            .block = lambda,
            .identifier = self.tokens[self.current].lexeme,
            .type = null,
        } });
    }

    self.current = endIndex;
    return lambda;
}

fn expect(self: *Parser, tokenType: TokenType) ParserError!void {
    if (self.current >= self.tokens.len or self.tokens[self.current].type != tokenType) return ParserError.UNEXPECTED_TOKEN;
    self.current += 1;
}

fn ifNud(self: *Parser) ParserError!*Expression {
    try self.expect(.LPAR);
    const condition = try self.parseExpression(Precedence.none);
    try self.expect(.RPAR);
    const satisfyBlock = try self.parseExpression(Precedence.none);
    try self.expect(.KW_ELSE);
    const elseBlock = try self.parseExpression(Precedence.none);

    return try self.newExpression(.{
        .Condition = .{
            .expression = condition,
            .satisfyBlock = satisfyBlock,
            .elseBlock = elseBlock,
        },
    });
}

fn newExpression(self: *Parser, expr: Expression) ParserError!*Expression {
    const freshExpr = self.allocator.create(Expression) catch return ParserError.OUT_OF_MEMORY;
    freshExpr.* = expr;

    return freshExpr;
}

fn led(tokenType: TokenType) ?InfixParselet {
    return switch (tokenType) {
        .ASTERISK, .SLASH => .{ .precedence = Precedence.factor, .led = binOpLed },
        .PLUS, .MINUS => .{ .precedence = Precedence.term, .led = binOpLed },
        .GT, .GTEQ, .LT, .LTEQ => .{ .precedence = Precedence.comparison, .led = binOpLed },
        .EQEQ, .NOTEQ, .NOTEQEQ => .{ .precedence = Precedence.equality, .led = binOpLed },
        .EQ => .{ .precedence = Precedence.assignment, .led = binOpLed },
        .KW_AND => .{ .precedence = Precedence.logic_and, .led = binOpLed },
        .KW_OR => .{ .precedence = Precedence.logic_or, .led = binOpLed },
        else => null,
    };
}

fn applicationLed(self: *Parser, left: *Expression) ParserError!*Expression {
    const right = try self.parseExpression(Precedence.call + 1);

    return try self.newExpression(Expression{ .Application = .{
        .callee = left,
        .value = right,
    } });
}

fn binOpLed(self: *Parser, left: *Expression, minBp: u8) ParserError!*Expression {
    const bop = try bopOfToken(self.previousToken().type);
    const right = try self.parseExpression(minBp + 1);

    if (bop == .EQ and self.matchToken(.SEMICOLON)) {
        if (left.* != .Variable) return ParserError.EXPECTED_VARIABLE_AT_DECLARATION;

        const block = try self.parseExpression(Precedence.none);

        return try self.newExpression(.{
            .Declaration = .{
                .identifier = left.Variable,
                .expression = right,
                .block = block,
            },
        });
    }

    return try self.newExpression(.{
        .BinaryOperation = .{
            .operation = bop,
            .left = left,
            .right = right,
        },
    });
}

fn matchToken(self: *Parser, tokenType: TokenType) bool {
    if (self.current >= self.tokens.len) return false;
    if (self.tokens[self.current].type == tokenType) {
        self.current += 1;
        return true;
    }
    return false;
}

fn isAtPrimaryStart(self: *Parser) bool {
    const token = self.tokens[self.current];
    const tokenType = token.type;
    return tokenType == .NUMBER or
        tokenType == .STRING or
        tokenType == .KW_TRUE or
        tokenType == .KW_FALSE or
        tokenType == .LPAR or
        tokenType == .LBRA or
        tokenType == .BANG or
        tokenType == .IDENT;
}

fn previousToken(self: *Parser) Token {
    return self.tokens[self.current - 1];
}

fn slide(self: *Parser, tokenType: TokenType) ParserError!void {
    while (self.current < self.tokens.len) {
        if (self.tokens[self.current].type == tokenType) {
            self.current += 1;
            return;
        }
        self.current += 1;
    }
    return ParserError.UNEXPECTED_TOKEN;
}

fn stringOfLexeme(self: *Parser, lexeme: []const u8) ParserError![]u8 {
    var string = std.ArrayList(u8).initCapacity(self.allocator, 0) catch return ParserError.OUT_OF_MEMORY;
    var escape = false;

    for (lexeme[1 .. lexeme.len - 1]) |c| {
        if (escape) {
            var char: u8 = c;
            switch (c) {
                'n' => char = '\n',
                'r' => char = '\r',
                't' => char = '\t',
                '"' => char = '"',
                '\\' => char = '\\',
                else => return error.UNKNOWN_ESCAPE_CHARACTER,
            }
            escape = false;
            string.append(self.allocator, char) catch return ParserError.OUT_OF_MEMORY;
        } else {
            if (c == '\\') {
                escape = true;
                continue;
            }
            string.append(self.allocator, c) catch return ParserError.OUT_OF_MEMORY;
        }
    }

    return string.items;
}

fn bopOfToken(tp: TokenType) ParserError!Bop {
    return switch (tp) {
        .EQ => Bop.EQ,
        .EQEQ => Bop.EQEQ,
        .NOTEQ => Bop.NOTEQ,
        .NOTEQEQ => Bop.NOTEQEQ,
        .GT => Bop.GT,
        .GTEQ => Bop.GTEQ,
        .LT => Bop.LT,
        .LTEQ => Bop.LTEQ,
        .PLUS => Bop.ADD,
        .MINUS => Bop.SUBTRACT,
        .ASTERISK => Bop.MULTIPLY,
        .SLASH => Bop.DIVIDE,
        .KW_AND => Bop.AND,
        .KW_OR => Bop.OR,
        else => return error.NOT_A_BINARY_OPERATION,
    };
}
