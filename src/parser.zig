const std = @import("std");
const ast = @import("ast.zig");
const Expression = ast.Expression;
const Bop = ast.Bop;
const lexer = @import("lexer.zig");
const Token = lexer.Token;
const TokenType = lexer.TokenType;

pub const ParserError = error{
    EOF_NOT_REACHED,
    EXPECTED_VARIABLE_AT_DECLARATION,
    EXPECTED_LEFT_PARENTHESES,
    EXPECTED_RIGHT_PARENTHESES,
    EXPECTED_ELSE_KEYWORD,
    LAMBDA_UNRESOLVED,
    EXPECTED_EXPRESSION,
    PARENTHESES_UNMATCHED,
    UNKNOWN_ESCAPE_CHARACTER,
    EXPECTED_BOP,
    NOT_A_BINARY_OPERATION,
} || std.mem.Allocator.Error;

pub const Parser = struct {
    allocator: std.mem.Allocator,
    tokens: []Token,
    current: usize = 0,

    pub fn init(allocator: std.mem.Allocator, tokens: []Token) Parser {
        return Parser{ .allocator = allocator, .tokens = tokens };
    }

    pub fn parse(self: *Parser) ParserError!*Expression {
        const expr = try self.declaration();
        if (!self.matchToken(.EOF)) return error.EOF_NOT_REACHED;
        return expr;
    }

    fn matchToken(self: *Parser, tokenType: TokenType) bool {
        if (self.current == self.tokens.len) return false;
        if (self.tokens[self.current].type == tokenType) {
            self.current += 1;
            return true;
        }
        return false;
    }

    fn backMatchToken(self: *Parser, tokenType: TokenType) bool {
        if (self.current == 0) return false;
        if (self.tokens[self.current].type == tokenType) {
            self.current -= 1;
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
            tokenType == .IDENT;
    }

    fn previousToken(self: *Parser) Token {
        return self.tokens[self.current - 1];
    }

    fn freshExpression(self: *Parser) ParserError!*Expression {
        return try self.allocator.create(Expression);
    }

    fn slide(self: *Parser, tokenType: TokenType) bool {
        while (!self.matchToken(tokenType)) {
            self.current += 1;
        }
        return self.previousToken().type == tokenType;
    }

    fn declaration(self: *Parser) ParserError!*Expression {
        const expr = try self.ifElse();

        if (self.matchToken(.SEMICOLON)) {
            if (isEquality(expr)) {
                const leftNode = try getBopLeftNode(expr);
                if (leftNode.* != Expression.Variable) return error.EXPECTED_VARIABLE_AT_DECLARATION;
                const ident = expr.BinaryOperation.left.Variable;
                const expression = expr.BinaryOperation.right;
                const block = try self.declaration();

                expr.* = Expression{
                    .Declaration = .{
                        .identifier = ident,
                        .block = block,
                        .expression = expression,
                    },
                };
            }
        }

        return expr;
    }

    fn ifElse(self: *Parser) ParserError!*Expression {
        if (self.matchToken(.KW_IF)) {
            if (!self.matchToken(.LPAR)) return error.EXPECTED_LEFT_PARENTHESES;
            const expression = try self.logical();
            if (!self.matchToken(.RPAR)) return error.EXPECTED_RIGHT_PARENTHESES;
            const satisfyBlock = try self.logical();
            if (!self.matchToken(.KW_ELSE)) return error.EXPECTED_ELSE_KEYWORD;
            const elseBlock = try self.ifElse();

            const fresh = try self.freshExpression();

            fresh.* = Expression{
                .Condition = .{
                    .expression = expression,
                    .satisfyBlock = satisfyBlock,
                    .elseBlock = elseBlock,
                },
            };

            return fresh;
        }

        return try self.logical();
    }

    fn logical(self: *Parser) ParserError!*Expression {
        var left = try self.equality();

        while (self.matchToken(.KW_AND) or self.matchToken(.KW_OR)) {
            const previous = self.previousToken().type;
            const bop = try bopOfToken(previous);

            const right = try self.equality();
            const fresh = try self.freshExpression();
            fresh.* = Expression{ .BinaryOperation = .{
                .left = left,
                .operation = bop,
                .right = right,
            } };

            left = fresh;
        }
        return left;
    }

    fn equality(self: *Parser) ParserError!*Expression {
        var left = try self.comparison();

        while (self.matchToken(.EQEQ) or self.matchToken(.EQ) or self.matchToken(.NOTEQ) or self.matchToken(.NOTEQEQ)) {
            const previous = self.previousToken().type;

            const right = try self.comparison();
            const bop = try bopOfToken(previous);

            const fresh = try self.freshExpression();

            fresh.* = Expression{ .BinaryOperation = .{
                .left = left,
                .operation = bop,
                .right = right,
            } };

            left = fresh;
        }

        return left;
    }

    fn comparison(self: *Parser) ParserError!*Expression {
        var left = try self.term();

        while (self.matchToken(.GT) or self.matchToken(.GTEQ) or self.matchToken(.LT) or self.matchToken(.LTEQ)) {
            const previous = self.previousToken().type;
            const bop = try bopOfToken(previous);

            const right = try self.term();
            const fresh = try self.freshExpression();
            fresh.* = Expression{ .BinaryOperation = .{
                .left = left,
                .operation = bop,
                .right = right,
            } };

            left = fresh;
        }
        return left;
    }

    fn term(self: *Parser) ParserError!*Expression {
        var left = try self.factor();

        while (self.matchToken(.PLUS) or self.matchToken(.MINUS)) {
            const previous = self.previousToken().type;
            const bop = try bopOfToken(previous);

            const right = try self.factor();

            const fresh = try self.freshExpression();

            fresh.* = Expression{ .BinaryOperation = .{
                .left = left,
                .operation = bop,
                .right = right,
            } };

            left = fresh;
        }

        return left;
    }

    fn factor(self: *Parser) ParserError!*Expression {
        var left = try self.application();

        while (self.matchToken(.ASTERISK) or self.matchToken(.SLASH)) {
            const previous = self.previousToken().type;
            const bop = try bopOfToken(previous);

            const right = try self.application();

            const fresh = try self.freshExpression();

            fresh.* = Expression{ .BinaryOperation = .{
                .left = left,
                .operation = bop,
                .right = right,
            } };

            left = fresh;
        }
        return left;
    }

    fn application(self: *Parser) ParserError!*Expression {
        var left = try self.lambda();

        while (self.isAtPrimaryStart()) {
            const right = try self.lambda();

            const fresh = try self.freshExpression();
            fresh.* = Expression{ .Application = .{
                .callee = left,
                .value = right,
            } };

            left = fresh;
        }

        return left;
    }

    fn lambda(self: *Parser) ParserError!*Expression {
        if (self.matchToken(.LBRA)) {
            var idents = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);

            while (self.matchToken(.IDENT)) {
                try idents.append(self.allocator, self.previousToken().lexeme);
            }

            if (!self.matchToken(.SEMICOLON)) return error.LAMBDA_UNRESOLVED;

            var block = try self.declaration();
            if (!self.matchToken(.RBRA)) return error.LAMBDA_UNRESOLVED;

            const items = idents.items;
            var i = items.len;
            while (i > 0) : (i -= 1) {
                const ident = items[i - 1];
                const fresh = try self.freshExpression();
                fresh.* = Expression{ .Lambda = .{
                    .identifier = ident,
                    .block = block,
                    .type = null,
                } };
                block = fresh;
            }

            return block;
        }

        return self.primary();
    }

    fn primary(self: *Parser) ParserError!*Expression {
        var expr = try self.freshExpression();
        const token = self.tokens[self.current];
        if (self.matchToken(.MINUS)) {
            if (self.matchToken(.NUMBER)) {
                const num = self.previousToken();
                expr.* = Expression{
                    .Number = try std.fmt.allocPrint(self.allocator, "-{s}", .{num.lexeme}),
                };
            } else {
                return error.EXPECTED_EXPRESSION;
            }
        } else if (self.matchToken(.BANG)) {
            const rest = try self.primary();

            expr.* = Expression{
                .Not = rest,
            };
        } else if (self.matchToken(.NUMBER)) {
            expr.* = Expression{
                .Number = token.lexeme,
            };
        } else if (self.matchToken(.STRING)) {
            const value = try self.stringOfLexeme(token.lexeme);

            expr.* = Expression{
                .String = value,
            };
        } else if (self.matchToken(.IDENT)) {
            expr.* = Expression{
                .Variable = token.lexeme,
            };
        } else if (self.matchToken(.KW_TRUE) or self.matchToken(.KW_FALSE)) {
            expr.* = Expression{
                .Boolean = token.type == .KW_TRUE,
            };
        } else if (self.matchToken(.LPAR)) {
            expr = try self.declaration();
            if (!self.matchToken(.RPAR)) return error.PARENTHESES_UNMATCHED;
        } else {
            return error.EXPECTED_EXPRESSION;
        }

        return expr;
    }

    fn stringOfLexeme(self: *Parser, lexeme: []const u8) ParserError![]u8 {
        var string = try std.ArrayList(u8).initCapacity(self.allocator, 0);
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
                try string.append(self.allocator, char);
            } else {
                if (c == '\\') {
                    escape = true;
                    continue;
                }
                try string.append(self.allocator, c);
            }
        }

        return string.items;
    }
};

fn isEquality(expression: *Expression) bool {
    return expression.* == .BinaryOperation and expression.BinaryOperation.operation == Bop.EQ;
}

fn getBopLeftNode(expression: *Expression) ParserError!*Expression {
    if (expression.* != .BinaryOperation) return error.EXPECTED_BOP;
    return expression.BinaryOperation.left;
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
