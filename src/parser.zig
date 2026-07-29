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
shared_context: ?*SharedContext,

const Precedence = struct {
    pub const none: u8 = 0;
    pub const arrow: u8 = 5; //           =>
    pub const assignment: u8 = 10; //     =
    pub const type_ascription: u8 = 15; // :
    pub const tuple: u8 = 20; //          ,
    pub const logic_or: u8 = 30; //       or
    pub const logic_and: u8 = 40; //      and
    pub const equality: u8 = 50; //       ==, !=
    pub const comparison: u8 = 60; //     <, >, <=, >=
    pub const term: u8 = 70; //           +, -
    pub const factor: u8 = 80; //         *, /
    pub const unary: u8 = 90; //          !, -
    pub const call: u8 = 100; //          (), application
    pub const member_access: u8 = 110; //  .
};

pub const ParserError = error{
    EofNotReached,
    ExpectedVariableAtDeclaration,
    LambdaUnresolved,
    ExpectedVariableAtBinding,
    ExpectedExpression,
    ParanthesesUnmatched,
    UnknownEscapeCharacter,
    NotABinaryOperation,
    OutOfMemory,
    UnexpectedToken,
    PatternExpected,
    ExpectedPropertyName,
    ExpectedModuleName,
    ExpectedModuleEnd,
    FileNotFound,
    EnvironmentNotFound,
    CompileError,
};

const PrefixParselet = *const fn (self: *Parser) ParserError!*Expression;

const InfixParselet = struct {
    precedence: u8,
    led: *const fn (self: *Parser, left: *Expression, precedence: u8) ParserError!*Expression,
};

pub fn init(allocator: std.mem.Allocator, tokens: []Token, shared_context: ?*SharedContext) Parser {
    return Parser{ .allocator = allocator, .tokens = tokens, .shared_context = shared_context };
}

pub fn parse(self: *Parser) ParserError!*Expression {
    const expr = try self.parseExpression(Precedence.none);
    if (!self.matchToken(.eof)) return ParserError.EofNotReached;
    return expr;
}

fn parseExpression(self: *Parser, min_bp: u8) ParserError!*Expression {
    var left = try self.nud();

    while (self.current < self.tokens.len) {
        if (self.isAtPrimaryStart() and Precedence.call > min_bp) {
            left = try self.applicationLed(left);
            continue;
        }
        const entry = led(self.tokens[self.current].type) orelse break;
        if (entry.precedence <= min_bp) break;
        self.current += 1;
        left = try entry.led(self, left, entry.precedence);
    }
    return left;
}

fn nud(self: *Parser) ParserError!*Expression {
    const token = self.tokens[self.current];
    self.current += 1;
    return switch (token.type) {
        .number => self.numberNud(),
        .string => self.stringNud(),
        .ident => self.identNud(),
        .kw_true, .kw_false => self.boolNud(),
        .minus => self.unaryMinusNud(),
        .bang => self.notNud(),
        .lpar => self.groupNud(),
        .lbra => self.lambdaNud(),
        .kw_if => self.ifNud(),
        .kw_match => self.matchNud(),
        .kw_module => self.moduleNud(),
        .kw_type => self.typeNud(),
        .kw_import => self.importNud(),
        .kw_env => self.envNud(),
        else => ParserError.ExpectedExpression,
    };
}

fn typeNud(self: *Parser) ParserError!*Expression {
    const ident_token = self.tokens[self.current];
    try self.expect(.ident);
    try self.expect(.eq);

    var types = std.ArrayList(*TypeAst).initCapacity(self.allocator, 1) catch return ParserError.OutOfMemory;

    // optional pipe before first type
    _ = self.matchToken(.pipe);

    while (true) {
        types.append(self.allocator, try self.parseType()) catch return ParserError.OutOfMemory;
        if (!self.matchToken(.pipe)) break;
    }

    try self.expect(.semicolon);
    const index = self.current;

    const block = self.parseExpression(Precedence.none) catch |err| {
        if (err == ParserError.ExpectedExpression) {
            self.current = index;

            return self.newExpression(.{ .type_declaration = .{
                .identifier = ident_token.lexeme,
                .types_ast = types.items,
                .block = try self.newExpression(.current_environment),
            } });
        }

        return err;
    };

    return self.newExpression(.{ .type_declaration = .{
        .identifier = ident_token.lexeme,
        .types_ast = types.items,
        .block = block,
    } });
}

fn importNud(self: *Parser) ParserError!*Expression {
    const token = self.tokens[self.current];
    try self.expect(.string);

    const file_path = try self.stringOfLexeme(token.lexeme);

    if (self.shared_context) |shared_context| {
        shared_context.load(file_path) catch |err| {
            self.current -= 1;
            switch (err) {
                error.FileNotFound => return ParserError.FileNotFound,
                else => return ParserError.CompileError,
            }
        };
    } else {
        return ParserError.EnvironmentNotFound;
    }

    if (self.matchToken(.at)) {
        const block = try self.parseExpression(Precedence.none);
        return try self.newExpression(.{ .use_environment = .{
            .environment = try self.newExpression(.{ .import = file_path }),
            .block = block,
        } });
    }

    return try self.newExpression(.{ .import = file_path });
}

fn moduleNud(self: *Parser) ParserError!*Expression {
    if (!self.matchToken(.ident)) return ParserError.ExpectedModuleName;
    const module_name = self.tokens[self.current - 1].lexeme;

    try self.expect(.lcur);

    const module_expression = try self.parseExpression(Precedence.none);

    var expr = module_expression;

    while (expr.* == .declaration or expr.* == .type_declaration) {
        if (expr.* == .declaration) expr = expr.declaration.block else expr = expr.type_declaration.block;
    }

    expr.* = .current_environment;

    self.expect(.rcur) catch return ParserError.ExpectedModuleEnd;
    const index = self.current;

    const rest_expression = self.parseExpression(Precedence.none) catch |err| {
        if (err == ParserError.ExpectedExpression) {
            self.current = index;
            return try self.newExpression(.{
                .module = .{
                    .identifier = module_name,
                    .block = module_expression,
                    .rest = try self.newExpression(.{ .unit = {} }),
                },
            });
        }
        return err;
    };

    return try self.newExpression(Expression{
        .module = .{
            .identifier = module_name,
            .block = module_expression,
            .rest = rest_expression,
        },
    });
}

fn matchNud(self: *Parser) ParserError!*Expression {
    const scrutinee = try self.parseExpression(Precedence.none);

    var patterns = std.ArrayList(ast.MatchCase).initCapacity(self.allocator, 0) catch return ParserError.OutOfMemory;

    while (self.matchToken(.pipe)) {
        const pattern = try self.parsePattern();

        try self.expect(.arrow);

        const block = try self.parseExpression(Precedence.none);

        patterns.append(self.allocator, .{
            .pattern = pattern,
            .block = block,
        }) catch return ParserError.OutOfMemory;
    }

    if (scrutinee.* == .type_ascription) {
        return try self.newExpression(.{ .match = .{
            .scrutinee = scrutinee.type_ascription.expression,
            .cases = patterns.items,
            .explicit_scrutinee_type = scrutinee.type_ascription.explicit_type,
        } });
    }

    return try self.newExpression(.{ .match = .{
        .scrutinee = scrutinee,
        .cases = patterns.items,
        .explicit_scrutinee_type = null,
    } });
}

fn parsePattern(self: *Parser) ParserError!*MatchPattern {
    var left_pattern = try self.parsePrimaryPattern();

    if (self.matchToken(.comma)) {
        var tuple_elements = std.ArrayList(*MatchPattern).initCapacity(self.allocator, 0) catch return ParserError.OutOfMemory;
        tuple_elements.append(self.allocator, left_pattern) catch return ParserError.OutOfMemory;

        while (true) {
            const next_pattern = try self.parsePrimaryPattern();
            tuple_elements.append(self.allocator, next_pattern) catch return ParserError.OutOfMemory;

            if (!self.matchToken(.comma)) break;
        }

        left_pattern = try self.newMatchPattern(.{
            .tuple = .{ .binds = tuple_elements.items },
        });
    }

    return left_pattern;
}

fn parsePrimaryPattern(self: *Parser) ParserError!*MatchPattern {
    const token = self.tokens[self.current];
    if (self.matchToken(.ident)) {
        if (std.mem.eql(u8, token.lexeme, "_")) {
            return try self.newMatchPattern(.wildcard);
        }
        if (std.ascii.isUpper(token.lexeme[0])) {
            const pattern: *MatchPattern = self.parsePattern() catch |err| {
                if (err == ParserError.PatternExpected) {
                    return try self.newMatchPattern(.{ .constructor = .{
                        .name = token.lexeme,
                        .payload = null,
                    } });
                }
                return err;
            };

            return try self.newMatchPattern(.{ .constructor = .{
                .name = token.lexeme,
                .payload = pattern,
            } });
        }
        return try self.newMatchPattern(.{ .identifier = token.lexeme });
    } else if (self.matchToken(.lpar)) {
        const pattern = try self.parsePattern();
        try self.expect(.rpar);
        return pattern;
    }
    return ParserError.PatternExpected;
}

fn newMatchPattern(self: *Parser, data: MatchPattern) ParserError!*MatchPattern {
    const match_pattern = self.allocator.create(MatchPattern) catch return ParserError.OutOfMemory;
    match_pattern.* = data;
    return match_pattern;
}

fn envNud(self: *Parser) ParserError!*Expression {
    return try self.newExpression(.current_environment);
}

fn numberNud(self: *Parser) ParserError!*Expression {
    return try self.newExpression(Expression{
        .number = self.previousToken().lexeme,
    });
}

fn stringNud(self: *Parser) ParserError!*Expression {
    return try self.newExpression(Expression{
        .string = try self.stringOfLexeme(self.previousToken().lexeme),
    });
}

fn identNud(self: *Parser) ParserError!*Expression {
    const lexeme = self.previousToken().lexeme;
    const first_char = lexeme[0];
    if (first_char >= 'A' and first_char <= 'Z') {
        return try self.newExpression(Expression{
            .constructor = .{
                .name = lexeme,
                .payload = null,
            },
        });
    }

    if (first_char == '@' and lexeme.len > 1 and lexeme[1] == '"') {
        return try self.newExpression(Expression{
            .variable = lexeme[2 .. lexeme.len - 1],
        });
    }

    return try self.newExpression(Expression{
        .variable = lexeme,
    });
}

fn boolNud(self: *Parser) ParserError!*Expression {
    return try self.newExpression(Expression{
        .boolean = self.previousToken().type == .kw_true,
    });
}

fn unaryMinusNud(self: *Parser) ParserError!*Expression {
    return try self.newExpression(Expression{ .unary_minus = try self.parseExpression(Precedence.unary) });
}

fn notNud(self: *Parser) ParserError!*Expression {
    return try self.newExpression(Expression{
        .not = try self.parseExpression(Precedence.unary),
    });
}

fn groupNud(self: *Parser) ParserError!*Expression {
    const inner_expression = self.parseExpression(Precedence.none) catch |err| {
        if (err == ParserError.ExpectedExpression) return try self.newExpression(.unit);
        return err;
    };

    self.expect(.rpar) catch return ParserError.ParanthesesUnmatched;
    return inner_expression;
}

fn lambdaNud(self: *Parser) ParserError!*Expression {
    const begin_index = self.current;

    self.slide(.semicolon) catch return ParserError.LambdaUnresolved;
    var lambda = try self.parseExpression(Precedence.none);

    self.expect(.rbra) catch return ParserError.LambdaUnresolved;
    const end_index = self.current;

    var binds = std.ArrayList(*Expression).initCapacity(self.allocator, 1) catch return ParserError.OutOfMemory;

    self.current = begin_index;
    while (!self.matchToken(.semicolon)) {
        binds.append(self.allocator, try self.parseExpression(200)) catch return ParserError.OutOfMemory;
    }

    var i = binds.items.len - 1;
    while (i >= 0) : (i -= 1) {
        const bind = binds.items[i];

        if (bind.* != .variable and (bind.* != .type_ascription or bind.type_ascription.expression.* != .variable)) return ParserError.ExpectedVariableAtBinding;

        if (bind.* == .variable) {
            lambda = try self.newExpression(Expression{ .lambda = .{
                .block = lambda,
                .identifier = bind.variable,
                .inferred_type = null,
                .explicit_argument_type = null,
            } });
        } else {
            lambda = try self.newExpression(Expression{ .lambda = .{
                .block = lambda,
                .identifier = bind.type_ascription.expression.variable,
                .inferred_type = null,
                .explicit_argument_type = bind.type_ascription.explicit_type,
            } });
        }
        if (i == 0) break;
    }

    self.current = end_index;
    return lambda;
}

fn expect(self: *Parser, token_type: TokenType) ParserError!void {
    if (self.current >= self.tokens.len or self.tokens[self.current].type != token_type) return ParserError.UnexpectedToken;
    self.current += 1;
}

fn ifNud(self: *Parser) ParserError!*Expression {
    try self.expect(.lpar);
    const condition = try self.parseExpression(Precedence.none);
    try self.expect(.rpar);
    const satisfy_block = try self.parseExpression(Precedence.none);
    try self.expect(.kw_else);
    const else_block = try self.parseExpression(Precedence.none);

    return try self.newExpression(.{
        .condition = .{
            .expression = condition,
            .satisfy_block = satisfy_block,
            .else_block = else_block,
        },
    });
}

fn newExpression(self: *Parser, expr: Expression) ParserError!*Expression {
    const fresh_expr = self.allocator.create(Expression) catch return ParserError.OutOfMemory;
    fresh_expr.* = expr;

    return fresh_expr;
}

fn led(token_type: TokenType) ?InfixParselet {
    return switch (token_type) {
        .asterisk, .slash => .{ .precedence = Precedence.factor, .led = binOpLed },
        .plus, .minus => .{ .precedence = Precedence.term, .led = binOpLed },
        .gt, .gt_eq, .lt, .lt_eq => .{ .precedence = Precedence.comparison, .led = binOpLed },
        .eq_eq, .not_eq, .not_eq_eq => .{ .precedence = Precedence.equality, .led = binOpLed },
        .eq => .{ .precedence = Precedence.assignment, .led = binOpLed },
        .kw_and => .{ .precedence = Precedence.logic_and, .led = binOpLed },
        .kw_or => .{ .precedence = Precedence.logic_or, .led = binOpLed },
        .comma => .{ .precedence = Precedence.tuple, .led = tupleLed },
        .colon => .{ .precedence = Precedence.type_ascription, .led = typeAscriptionLed },
        .dot => .{ .precedence = Precedence.member_access, .led = memberAccessLed },
        else => null,
    };
}

fn memberAccessLed(self: *Parser, left: *Expression, min_bp: u8) ParserError!*Expression {
    _ = min_bp;
    if (!self.matchToken(.ident)) return ParserError.ExpectedPropertyName;

    const property_name = self.previousToken().lexeme;

    return try self.newExpression(Expression{ .member_access = .{
        .object = left,
        .member = property_name,
    } });
}

fn applicationLed(self: *Parser, left: *Expression) ParserError!*Expression {
    const right = try self.parseExpression(Precedence.call + 1);

    if (left.* == .constructor) {
        left.constructor.payload = right;

        return left;
    }

    return try self.newExpression(Expression{ .application = .{
        .callee = left,
        .value = right,
    } });
}

fn binOpLed(self: *Parser, left: *Expression, min_bp: u8) ParserError!*Expression {
    const bop = try bopOfToken(self.previousToken().type);
    const right = try self.parseExpression(min_bp + 1);

    if (bop == .eq and self.matchToken(.semicolon)) {
        if (left.* != .variable and left.* != .type_ascription) return ParserError.ExpectedVariableAtDeclaration;
        var ident: ?[]const u8 = null;
        var tp: ?*TypeAst = null;

        const index = self.current;

        if (left.* == .type_ascription) {
            if (left.type_ascription.expression.* != .variable) return ParserError.ExpectedVariableAtDeclaration;
            ident = left.type_ascription.expression.variable;
            tp = left.type_ascription.explicit_type;

            self.allocator.destroy(left);
        }

        if (left.* == .variable) {
            ident = left.variable;
        }

        const block = self.parseExpression(Precedence.none) catch |err| {
            self.current = index;
            if (err == ParserError.ExpectedExpression)
                return try self.newExpression(.{
                    .declaration = .{
                        .identifier = ident.?,
                        .expression = right,
                        .block = try self.newExpression(.{ .current_environment = {} }),
                        .explicit_type = tp,
                    },
                });
            return err;
        };

        return try self.newExpression(.{
            .declaration = .{
                .identifier = ident.?,
                .expression = right,
                .block = block,
                .explicit_type = tp,
            },
        });
    }

    return try self.newExpression(.{
        .binary_operation = .{
            .operation = bop,
            .left = left,
            .right = right,
        },
    });
}

fn typeAscriptionLed(self: *Parser, left: *Expression, min_bp: u8) ParserError!*Expression {
    _ = min_bp;
    const explicit_type = try self.parseType();

    return try self.newExpression(.{
        .type_ascription = .{
            .expression = left,
            .explicit_type = explicit_type,
        },
    });
}

fn parseType(self: *Parser) ParserError!*TypeAst {
    const left = try self.parseLambda();

    if (self.matchToken(.kw_of)) {
        if (left.* != .identifier or !(left.identifier[0] >= 'A' and left.identifier[0] <= 'Z')) return ParserError.UnexpectedToken;

        const right = try self.parseLambda();

        return try self.newTypeAst(.{ .constructor = .{
            .name = left.identifier,
            .payload = right,
        } });
    }

    if (left.* == .identifier and left.identifier[0] >= 'A' and left.identifier[0] <= 'Z') {
        return try self.newTypeAst(.{ .constructor = .{
            .name = left.identifier,
            .payload = null,
        } });
    }

    return left;
}

fn parseLambda(self: *Parser) ParserError!*TypeAst {
    const left = try self.parseTupleType();

    if (self.matchToken(.arrow)) {
        const right = try self.parseLambda();

        return try self.newTypeAst(.{
            .function = .{
                .argument = left,
                .returns = right,
            },
        });
    }

    return left;
}

fn parseTupleType(self: *Parser) ParserError!*TypeAst {
    var types = std.ArrayList(*TypeAst).initCapacity(self.allocator, 1) catch return ParserError.OutOfMemory;

    types.append(self.allocator, try self.parsePrimaryType()) catch return ParserError.OutOfMemory;

    while (self.matchToken(.asterisk)) {
        types.append(self.allocator, try self.parsePrimaryType()) catch return ParserError.OutOfMemory;
    }

    if (types.items.len == 1) {
        defer types.deinit(self.allocator);
        return types.items[0];
    }

    return try self.newTypeAst(.{ .tuple = types.items });
}

fn parsePrimaryType(self: *Parser) ParserError!*TypeAst {
    const token = self.tokens[self.current];

    if (self.matchToken(.lpar)) {
        const group_type = try self.parseType();

        try self.expect(.rpar);

        return group_type;
    }

    if (self.matchToken(.ident)) {
        if (std.mem.eql(u8, token.lexeme, "_")) {
            return try self.newTypeAst(.{ .wildcard = {} });
        }
        return try self.newTypeAst(.{ .identifier = token.lexeme });
    }

    return ParserError.UnexpectedToken;
}

fn newTypeAst(self: *Parser, type_ast: TypeAst) ParserError!*TypeAst {
    const fresh = self.allocator.create(TypeAst) catch return ParserError.OutOfMemory;

    fresh.* = type_ast;

    return fresh;
}

fn tupleLed(self: *Parser, left: *Expression, min_bp: u8) ParserError!*Expression {
    var expressions_array = std.ArrayList(*Expression).initCapacity(self.allocator, 0) catch return ParserError.OutOfMemory;

    expressions_array.append(self.allocator, left) catch return ParserError.OutOfMemory;

    self.current -= 1;

    while (self.matchToken(.comma)) {
        const saved_pos = self.current;

        const next = self.parseExpression(min_bp) catch |err| {
            if (err == ParserError.ExpectedExpression) {
                self.current = saved_pos;
                break;
            }
            return err;
        };
        expressions_array.append(self.allocator, next) catch return ParserError.OutOfMemory;
    }

    return try self.newExpression(.{
        .tuple = expressions_array.items,
    });
}

fn matchToken(self: *Parser, token_type: TokenType) bool {
    if (self.current >= self.tokens.len) return false;
    if (self.tokens[self.current].type == token_type) {
        self.current += 1;
        return true;
    }
    return false;
}

fn isAtPrimaryStart(self: *Parser) bool {
    if (self.current >= self.tokens.len) return false;
    const token = self.tokens[self.current];
    const token_type = token.type;
    return token_type == .number or
        token_type == .string or
        token_type == .kw_true or
        token_type == .kw_false or
        token_type == .kw_if or
        token_type == .lpar or
        token_type == .lbra or
        token_type == .bang or
        token_type == .ident or
        token_type == .kw_type or
        token_type == .kw_env or
        token_type == .kw_module;
}

fn previousToken(self: *Parser) Token {
    return self.tokens[self.current - 1];
}

fn slide(self: *Parser, token_type: TokenType) ParserError!void {
    while (self.current < self.tokens.len) {
        if (self.tokens[self.current].type == token_type) {
            self.current += 1;
            return;
        }
        self.current += 1;
    }
    return ParserError.UnexpectedToken;
}

fn stringOfLexeme(self: *Parser, lexeme: []const u8) ParserError![]u8 {
    var string = std.ArrayList(u8).initCapacity(self.allocator, 0) catch return ParserError.OutOfMemory;
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
                else => return ParserError.UnknownEscapeCharacter,
            }
            escape = false;
            string.append(self.allocator, char) catch return ParserError.OutOfMemory;
        } else {
            if (c == '\\') {
                escape = true;
                continue;
            }
            string.append(self.allocator, c) catch return ParserError.OutOfMemory;
        }
    }

    return string.items;
}

fn bopOfToken(tp: TokenType) ParserError!Bop {
    return switch (tp) {
        .eq => Bop.eq,
        .eq_eq => Bop.eq_eq,
        .not_eq => Bop.not_eq,
        .not_eq_eq => Bop.not_eq_eq,
        .gt => Bop.gt,
        .gt_eq => Bop.gt_eq,
        .lt => Bop.lt,
        .lt_eq => Bop.lt_eq,
        .plus => Bop.add,
        .minus => Bop.subtract,
        .asterisk => Bop.multiply,
        .slash => Bop.divide,
        .kw_and => Bop.and_op,
        .kw_or => Bop.or_op,
        else => return ParserError.NotABinaryOperation,
    };
}
