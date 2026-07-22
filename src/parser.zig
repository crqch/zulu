const std = @import("std");

const ast = @import("ast.zig");
const Expression = ast.Expression;
const MatchPattern = ast.MatchPattern;
const TypeAst = ast.TypeAst;
const Bop = ast.Bop;
const lexer = @import("lexer.zig");
const Token = lexer.Token;
const TokenType = lexer.TokenType;
const SharedContext = @import("./shared.zig");

const Parser = @This();

allocator: std.mem.Allocator,
current: usize = 0,
tokens: []Token,
sharedContext: ?*SharedContext,

const Precedence = struct {
    pub const none: u8 = 0;
    pub const arrow: u8 = 5; //           =>
    pub const assignment: u8 = 10; //     =
    pub const typeAscription: u8 = 15; // :
    pub const tuple: u8 = 20; //          ,
    pub const logic_or: u8 = 30; //       or
    pub const logic_and: u8 = 40; //      and
    pub const equality: u8 = 50; //       ==, !=
    pub const comparison: u8 = 60; //     <, >, <=, >=
    pub const term: u8 = 70; //           +, -
    pub const factor: u8 = 80; //         *, /
    pub const unary: u8 = 90; //          !, -
    pub const call: u8 = 100; //          (), application
    pub const memberAccess: u8 = 110; //  .
};

pub const ParserError = error{
    EOF_NOT_REACHED,
    EXPECTED_VARIABLE_AT_DECLARATION,
    LAMBDA_UNRESOLVED,
    EXPECTED_VARIABLE_AT_BINDING,
    EXPECTED_EXPRESSION,
    PARENTHESES_UNMATCHED,
    UNKNOWN_ESCAPE_CHARACTER,
    NOT_A_BINARY_OPERATION,
    OUT_OF_MEMORY,
    UNEXPECTED_TOKEN,
    PATTERN_EXPECTED,
    EXPECTED_PROPERTY_NAME,
    EXPECTED_MODULE_NAME,
    EXPECTED_MODULE_END,
    FILE_NOT_FOUND,
    ENVIRONMENT_NOT_FOUND,
    COMPILE_ERROR,
};

const PrefixParselet = *const fn (self: *Parser) ParserError!*Expression;

const InfixParselet = struct {
    precedence: u8,
    led: *const fn (self: *Parser, left: *Expression, precedence: u8) ParserError!*Expression,
};

pub fn init(allocator: std.mem.Allocator, tokens: []Token, sharedContext: ?*SharedContext) Parser {
    return Parser{ .allocator = allocator, .tokens = tokens, .sharedContext = sharedContext };
}

pub fn parse(self: *Parser) ParserError!*Expression {
    const expr = try self.parseExpression(Precedence.none);
    if (!self.matchToken(.EOF)) return error.EOF_NOT_REACHED;
    return expr;
}

fn parseExpression(self: *Parser, minBp: u8) ParserError!*Expression {
    var left = try self.nud();

    while (self.current < self.tokens.len) {
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
        .KW_MATCH => self.matchNud(),
        .KW_MOD => self.moduleNud(),
        .KW_IMPORT => self.importNud(),
        .KW_ENV => self.envNud(),
        else => error.EXPECTED_EXPRESSION,
    };
}

fn importNud(self: *Parser) ParserError!*Expression {
    const token = self.tokens[self.current];
    try self.expect(.STRING);

    const filePath = try self.stringOfLexeme(token.lexeme);

    if (self.sharedContext) |sharedContext| {
        sharedContext.load(filePath) catch |err| {
            self.current -= 1;
            switch (err) {
                error.FileNotFound => return ParserError.FILE_NOT_FOUND,
                else => return ParserError.COMPILE_ERROR,
            }
        };
    } else {
        return ParserError.ENVIRONMENT_NOT_FOUND;
    }

    if (self.matchToken(.AT)) {
        const block = try self.parseExpression(Precedence.none);
        return try self.newExpression(.{ .UseEnvironment = .{
            .environment = try self.newExpression(.{ .Import = filePath }),
            .block = block,
        } });
    }

    return try self.newExpression(.{ .Import = filePath });
}

fn moduleNud(self: *Parser) ParserError!*Expression {
    if (!self.matchToken(.IDENT)) return ParserError.EXPECTED_MODULE_NAME;
    const moduleName = self.tokens[self.current - 1].lexeme;

    try self.expect(.LCUR);

    const moduleExpression = try self.parseExpression(Precedence.none);

    var expr = moduleExpression;

    while (expr.* == .Declaration) expr = expr.Declaration.block;

    expr.* = .CurrentEnvironment;

    self.expect(.RCUR) catch return ParserError.EXPECTED_MODULE_END;

    const restExpression = self.parseExpression(Precedence.none) catch |err| {
        if (err == ParserError.EXPECTED_EXPRESSION) return try self.newExpression(.{
            .Module = .{
                .identifier = moduleName,
                .block = moduleExpression,
                .rest = try self.newExpression(.{ .Unit = {} }),
            },
        });
        return err;
    };

    return try self.newExpression(Expression{
        .Module = .{
            .identifier = moduleName,
            .block = moduleExpression,
            .rest = restExpression,
        },
    });
}

fn matchNud(self: *Parser) ParserError!*Expression {
    const scrutinee = try self.parseExpression(Precedence.none);

    var patternsArray = std.ArrayList(ast.MatchCase).initCapacity(self.allocator, 0) catch return ParserError.OUT_OF_MEMORY;

    while (self.matchToken(.PIPE)) {
        const pattern = try self.parsePattern();

        try self.expect(.ARROW);

        const block = try self.parseExpression(Precedence.none);

        patternsArray.append(self.allocator, .{
            .pattern = pattern,
            .block = block,
        }) catch return ParserError.OUT_OF_MEMORY;
    }

    if (scrutinee.* == .TypeAscription) {
        return try self.newExpression(.{ .Match = .{
            .scrutinee = scrutinee.TypeAscription.expression,
            .cases = patternsArray.items,
            .explicitScrutineeType = scrutinee.TypeAscription.explicitType,
        } });
    }

    return try self.newExpression(.{ .Match = .{
        .scrutinee = scrutinee,
        .cases = patternsArray.items,
        .explicitScrutineeType = null,
    } });
}

fn parsePattern(self: *Parser) ParserError!*MatchPattern {
    var leftPattern = try self.parsePrimaryPattern();

    if (self.matchToken(.COMMA)) {
        var tupleElements = std.ArrayList(*MatchPattern).initCapacity(self.allocator, 0) catch return ParserError.OUT_OF_MEMORY;
        tupleElements.append(self.allocator, leftPattern) catch return ParserError.OUT_OF_MEMORY;

        while (true) {
            const nextPattern = try self.parsePrimaryPattern();
            tupleElements.append(self.allocator, nextPattern) catch return ParserError.OUT_OF_MEMORY;

            if (!self.matchToken(.COMMA)) break;
        }

        leftPattern = try self.newMatchPattern(.{
            .Tuple = .{ .binds = tupleElements.items },
        });
    }

    return leftPattern;
}

fn parsePrimaryPattern(self: *Parser) ParserError!*MatchPattern {
    const token = self.tokens[self.current];
    if (self.matchToken(.IDENT)) {
        if (std.mem.eql(u8, token.lexeme, "_")) {
            return try self.newMatchPattern(.Wildcard);
        }
        return try self.newMatchPattern(.{ .Identifier = token.lexeme });
    } else if (self.matchToken(.LPAR)) {
        const pattern = try self.parsePattern();
        try self.expect(.RPAR);
        return pattern;
    }
    return ParserError.PATTERN_EXPECTED;
}

fn newMatchPattern(self: *Parser, data: MatchPattern) ParserError!*MatchPattern {
    const matchPattern = self.allocator.create(MatchPattern) catch return ParserError.OUT_OF_MEMORY;
    matchPattern.* = data;
    return matchPattern;
}

fn envNud(self: *Parser) ParserError!*Expression {
    return try self.newExpression(.CurrentEnvironment);
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
    const innerExpression = self.parseExpression(Precedence.none) catch |err| {
        if (err == ParserError.EXPECTED_EXPRESSION) return try self.newExpression(.Unit);
        return err;
    };

    self.expect(.RPAR) catch return ParserError.PARENTHESES_UNMATCHED;
    return innerExpression;
}

fn lambdaNud(self: *Parser) ParserError!*Expression {
    const beginIndex = self.current;

    self.slide(.SEMICOLON) catch return ParserError.LAMBDA_UNRESOLVED;
    var lambda = try self.parseExpression(Precedence.none);

    self.expect(.RBRA) catch return ParserError.LAMBDA_UNRESOLVED;
    const endIndex = self.current;

    var binds = std.ArrayList(*Expression).initCapacity(self.allocator, 1) catch return ParserError.OUT_OF_MEMORY;

    self.current = beginIndex;
    while (!self.matchToken(.SEMICOLON)) {
        binds.append(self.allocator, try self.parseExpression(200)) catch return ParserError.OUT_OF_MEMORY;
    }

    var i = binds.items.len - 1;
    while (i >= 0) : (i -= 1) {
        const bind = binds.items[i];

        if (bind.* != .Variable and (bind.* != .TypeAscription or bind.TypeAscription.expression.* != .Variable)) return ParserError.EXPECTED_VARIABLE_AT_BINDING;

        if (bind.* == .Variable) {
            lambda = try self.newExpression(Expression{ .Lambda = .{
                .block = lambda,
                .identifier = bind.Variable,
                .inferredType = null,
                .explicitArgumentType = null,
            } });
        } else {
            lambda = try self.newExpression(Expression{ .Lambda = .{
                .block = lambda,
                .identifier = bind.TypeAscription.expression.Variable,
                .inferredType = null,
                .explicitArgumentType = bind.TypeAscription.explicitType,
            } });
        }
        if (i == 0) break;
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
        .COMMA => .{ .precedence = Precedence.tuple, .led = tupleLed },
        .COLON => .{ .precedence = Precedence.typeAscription, .led = typeAscriptionLed },
        .DOT => .{ .precedence = Precedence.memberAccess, .led = memberAccessLed },
        else => null,
    };
}

fn memberAccessLed(self: *Parser, left: *Expression, minBp: u8) ParserError!*Expression {
    _ = minBp;
    if (!self.matchToken(.IDENT)) return ParserError.EXPECTED_PROPERTY_NAME;

    const propertyName = self.previousToken().lexeme;

    return try self.newExpression(Expression{ .MemberAccess = .{
        .object = left,
        .member = propertyName,
    } });
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
        if (left.* != .Variable and left.* != .TypeAscription) return ParserError.EXPECTED_VARIABLE_AT_DECLARATION;
        var ident: ?[]const u8 = null;
        var tp: ?*TypeAst = null;

        const index = self.current;

        if (left.* == .TypeAscription) {
            if (left.TypeAscription.expression.* != .Variable) return ParserError.EXPECTED_VARIABLE_AT_DECLARATION;
            ident = left.TypeAscription.expression.Variable;
            tp = left.TypeAscription.explicitType;

            self.allocator.destroy(left);
        }

        if (left.* == .Variable) {
            ident = left.Variable;
        }

        const block = self.parseExpression(Precedence.none) catch |err| {
            self.current = index;
            if (err == ParserError.EXPECTED_EXPRESSION)
                return try self.newExpression(.{
                    .Declaration = .{
                        .identifier = ident.?,
                        .expression = right,
                        .block = try self.newExpression(.{ .CurrentEnvironment = {} }),
                        .explicitType = tp,
                    },
                });
            return err;
        };

        return try self.newExpression(.{
            .Declaration = .{
                .identifier = ident.?,
                .expression = right,
                .block = block,
                .explicitType = tp,
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

fn typeAscriptionLed(self: *Parser, left: *Expression, minBp: u8) ParserError!*Expression {
    _ = minBp;
    const explicitType = try self.parseType();

    return try self.newExpression(.{
        .TypeAscription = .{
            .expression = left,
            .explicitType = explicitType,
        },
    });
}

fn parseType(self: *Parser) ParserError!*TypeAst {
    const left = try self.parseTupleType();

    if (self.matchToken(.ARROW)) {
        const right = try self.parseType();

        return try self.newTypeAst(.{
            .Function = .{
                .argument = left,
                .returnType = right,
            },
        });
    }

    return left;
}

fn parseTupleType(self: *Parser) ParserError!*TypeAst {
    var types = std.ArrayList(*TypeAst).initCapacity(self.allocator, 1) catch return ParserError.OUT_OF_MEMORY;

    types.append(self.allocator, try self.parsePrimaryType()) catch return ParserError.OUT_OF_MEMORY;

    while (self.matchToken(.ASTERISK)) {
        types.append(self.allocator, try self.parsePrimaryType()) catch return ParserError.OUT_OF_MEMORY;
    }

    if (types.items.len == 1) {
        defer types.deinit(self.allocator);
        return types.items[0];
    }

    return try self.newTypeAst(.{ .Tuple = types.items });
}

fn parsePrimaryType(self: *Parser) ParserError!*TypeAst {
    const token = self.tokens[self.current];

    if (self.matchToken(.LPAR)) {
        const groupType = try self.parseType();

        try self.expect(.RPAR);

        return groupType;
    }

    if (self.matchToken(.IDENT)) {
        if (std.mem.eql(u8, token.lexeme, "_")) {
            return try self.newTypeAst(.{ .Wildcard = {} });
        }
        return try self.newTypeAst(.{ .Identifier = token.lexeme });
    }

    return ParserError.UNEXPECTED_TOKEN;
}

fn newTypeAst(self: *Parser, typeAst: TypeAst) ParserError!*TypeAst {
    const fresh = self.allocator.create(TypeAst) catch return ParserError.OUT_OF_MEMORY;

    fresh.* = typeAst;

    return fresh;
}

fn tupleLed(self: *Parser, left: *Expression, minBp: u8) ParserError!*Expression {
    var expressionsArray = std.ArrayList(*Expression).initCapacity(self.allocator, 0) catch return ParserError.OUT_OF_MEMORY;

    expressionsArray.append(self.allocator, left) catch return ParserError.OUT_OF_MEMORY;

    self.current -= 1;

    while (self.matchToken(.COMMA)) {
        const saved_pos = self.current;

        const next = self.parseExpression(minBp) catch |err| {
            if (err == ParserError.EXPECTED_EXPRESSION) {
                self.current = saved_pos;
                break;
            }
            return err;
        };
        expressionsArray.append(self.allocator, next) catch return ParserError.OUT_OF_MEMORY;
    }

    return try self.newExpression(.{
        .Tuple = expressionsArray.items,
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
    if (self.current >= self.tokens.len) return false;
    const token = self.tokens[self.current];
    const tokenType = token.type;
    return tokenType == .NUMBER or
        tokenType == .STRING or
        tokenType == .KW_TRUE or
        tokenType == .KW_FALSE or
        tokenType == .KW_IF or
        tokenType == .LPAR or
        tokenType == .LBRA or
        tokenType == .BANG or
        tokenType == .IDENT or
        tokenType == .KW_ENV or
        tokenType == .KW_MOD;
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
