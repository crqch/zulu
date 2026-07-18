const std = @import("std");

const zulu = @import("./root.zig");
const Options = zulu.Options;
const ansi = zulu.ansi;
const ReturnValue = zulu.SharedContext.ReturnType;
const SharedContext = zulu.SharedContext;
const Lexer = zulu.Lexer;
const Parser = zulu.Parser;
const AstPrinter = zulu.AstPrinter;
const TypeChecker = zulu.TypeChecker;
const TypeError = zulu.TypeChecker.TypeError;
const Interpreter = zulu.Interpreter;
const Token = zulu.Token;
const Expression = zulu.Expression;

const Pipeline = @This();
allocator: std.mem.Allocator,
options: Options,
typeArena: std.heap.ArenaAllocator,
typeChecker: TypeChecker,

pub fn init(allocator: std.mem.Allocator, options: Options) Pipeline {
    var typeArena = std.heap.ArenaAllocator.init(allocator);
    const typeAllocator = typeArena.allocator();
    const typeChecker = TypeChecker.init(typeAllocator, null);

    return Pipeline{
        .allocator = allocator,
        .options = options,
        .typeArena = typeArena,
        .typeChecker = typeChecker,
    };
}

pub fn deinit(self: *Pipeline) void {
    self.typeArena.deinit();
}

pub fn run(self: *Pipeline, sharedContext: *SharedContext, filePath: []const u8, source: []const u8, options: Options) !?ReturnValue {
    var lexer = try Lexer.init(self.allocator, source);
    defer lexer.deinit();

    var typeChecker = TypeChecker.init(self.typeArena.allocator(), sharedContext);

    const tokens = lexer.scanTokens() catch |err| {
        printErrorLocation("Lexer Error", filePath);
        switch (err) {
            error.UNMATCHED_TOKEN => {
                const char = if (lexer.current > 0) lexer.source[lexer.current - 1] else '?';
                std.debug.print("Unexpected character '{c}' at line {}, column {}.\n", .{ char, lexer.line, lexer.column });
                printSourceHighlight(source, lexer.line, lexer.column, 1);
            },
            error.UNTERMINATED_STRING_LITERAL => {
                std.debug.print("Unterminated string literal starting at line {}, column {}.\n", .{ lexer.line, lexer.column });
                printSourceHighlight(source, lexer.line, lexer.column, 1);
            },
            else => {
                std.debug.print("Unexpected scanning error: {s}\n", .{@errorName(err)});
            },
        }
        return err;
    };

    if (options.@"debug-lexer") {
        std.debug.print(ansi.bold ++ ansi.green ++ "Lexer output:\n" ++ ansi.reset, .{});
        const tokensPrinted = try lexer.printTokens();
        std.debug.print("{s}", .{tokensPrinted});
    }

    if (options.@"halt-lexer") {
        return null;
    }

    var parser = Parser.init(self.allocator, tokens, sharedContext);
    const expression = parser.parse() catch |err| {
        printErrorLocation("Parser Error", filePath);
        const token = if (parser.current < parser.tokens.len) parser.tokens[parser.current] else parser.tokens[parser.tokens.len - 1];
        switch (err) {
            error.EOF_NOT_REACHED => {
                std.debug.print("Unexpected token '{s}' at line {}, column {} (extra input after expression).\n", .{ token.lexeme, token.location.line, token.location.column });
            },
            error.EXPECTED_VARIABLE_AT_DECLARATION => {
                std.debug.print("Expected variable identifier in declaration at line {}, column {}.\n", .{ token.location.line, token.location.column });
            },
            error.LAMBDA_UNRESOLVED => {
                std.debug.print("Unresolved lambda syntax at line {}, column {}.\n", .{ token.location.line, token.location.column });
            },
            error.EXPECTED_EXPRESSION => {
                std.debug.print("Expected expression at line {}, column {}.\n", .{ token.location.line, token.location.column });
            },
            error.PARENTHESES_UNMATCHED => {
                std.debug.print("Unmatched parentheses starting at line {}, column {}.\n", .{ token.location.line, token.location.column });
            },
            error.UNKNOWN_ESCAPE_CHARACTER => {
                std.debug.print("Unknown escape character in string literal at line {}, column {}.\n", .{ token.location.line, token.location.column });
            },
            error.NOT_A_BINARY_OPERATION => {
                std.debug.print("Invalid binary operation at line {}, column {}.\n", .{ token.location.line, token.location.column });
            },
            error.OUT_OF_MEMORY => {
                std.debug.print("Out of memory.\n", .{});
            },
            error.UNEXPECTED_TOKEN => {
                if (token.type == .EOF) {
                    std.debug.print("Unexpected end of input at line {}, column {}.\n", .{ token.location.line, token.location.column });
                } else {
                    std.debug.print("Unexpected token '{s}' at line {}, column {}.\n", .{ token.lexeme, token.location.line, token.location.column });
                }
            },
            else => {
                std.debug.print("Unexpected parsing error: {s}\n", .{@errorName(err)});
            },
        }
        printSourceHighlight(source, token.location.line, token.location.column, token.lexeme.len);
        return err;
    };

    if (options.@"debug-parser") {
        std.debug.print(ansi.bold ++ ansi.green ++ "Parser output:\n" ++ ansi.reset, .{});
        const printedExpr = try AstPrinter.prettyPrint(self.allocator, expression.*);
        std.debug.print("{s}\n", .{printedExpr});
    }

    if (options.@"halt-parser") {
        return null;
    }

    const programType = typeChecker.inferType(expression) catch |err| {
        switch (err) {
            TypeError.UNEXPECTED_TYPE => {
                printErrorLocation("Type Error", filePath);
                std.debug.print("Unexpected type\n" ++ ansi.reset, .{});
                if (typeChecker.errorContext) |context| {
                    if (findExprLocation(tokens, context.UNEXPECTED_TYPE.context)) |token| {
                        printSourceHighlight(source, token.location.line, token.location.column, token.lexeme.len);
                    }

                    std.debug.print("Expected one of the following types:\n", .{});
                    for (context.UNEXPECTED_TYPE.expectedType) |expectedType| {
                        std.debug.print(ansi.blue ++ "\t{s}\n" ++ ansi.reset, .{try TypeChecker.PrettyPrinter.prettyPrint(self.typeArena.allocator(), typeChecker.finalizeType(expectedType).*)});
                    }
                    std.debug.print("But got: " ++ ansi.blue ++ "{s}" ++ ansi.reset ++ "\n", .{try TypeChecker.PrettyPrinter.prettyPrint(self.typeArena.allocator(), typeChecker.finalizeType(context.UNEXPECTED_TYPE.foundType).*)});
                }
            },
            else => {
                printErrorLocation("Type Error", filePath);
                std.debug.print("{}\n", .{err});
            },
        }
        return err;
    };
    if (options.@"debug-type") {
        std.debug.print(ansi.bold ++ ansi.green ++ "Typechecker output:\n" ++ ansi.reset, .{});
        const printedType = try TypeChecker.PrettyPrinter.prettyPrint(self.allocator, typeChecker.finalizeType(programType).*);
        std.debug.print("{s}\n", .{printedType});
    }

    if (options.@"halt-type") {
        return null;
    }

    var interpreter = Interpreter.init(self.allocator, sharedContext);

    const value = interpreter.eval(expression) catch |err| {
        printErrorLocation("Runtime Error", filePath);
        switch (err) {
            error.UNBOUND_VARIABLE => {
                std.debug.print("Unbound variable (variable referenced before it was defined).\n", .{});
            },
            error.UNEXPECTED_TYPE => {
                std.debug.print("Unexpected type encountered in operation.\n", .{});
            },
            error.DIVISION_BY_ZERO => {
                std.debug.print("Division by zero.\n", .{});
            },
            error.FLOAT_PARSING_FAILED => {
                std.debug.print("Failed to parse float value.\n", .{});
            },
            error.INT_PARSING_FAILED => {
                std.debug.print("Failed to parse integer value.\n", .{});
            },
            error.ENVIRONMENT_INITALIZATION_ERROR, error.ENVIRONMENT_MAP_ERROR, error.MEMORY_ALLOCATION_FAILED => {
                std.debug.print("Memory allocation or environment initialization failed.\n", .{});
            },
            error.TYPE_PROMOTION_NOT_IMPLEMENTED => {
                std.debug.print("Type promotion not implemented yet.\n", .{});
            },
            error.UNIMPLEMENTED => {
                std.debug.print("Unimplemented feature encountered.\n", .{});
            },
            error.MISSING_MATCH_CASE => {
                std.debug.print("Missing match case.\n", .{});
            },
            error.UNMATCHED_PATTERN => {
                std.debug.print("Pattern unmatched in match.\n", .{});
            },
            error.PROPERTY_NOT_FOUND_ON_OBJECT => {
                std.debug.print("Property not found on object.\n", .{});
            },
            error.MEMBER_ACCESS_ON_NON_ENVIRONMENT => {
                std.debug.print("Member access on non module.\n", .{});
            },
            error.EXPECTED_CURRENT_ENVIRONMENT_ON_MODULE_END => {
                std.debug.print("Expected current environment on module end.\n", .{});
            },
            error.IMPORT_FILE_NOT_FOUND => {
                std.debug.print("Import file not found.\n", .{});
            },
        }
        if (interpreter.last_expression) |last_expr| {
            if (findExprLocation(tokens, last_expr)) |token| {
                printSourceHighlight(source, token.location.line, token.location.column, token.lexeme.len);
            }
        }
        return err;
    };
    return ReturnValue{
        .value = value,
        .type = programType,
    };
}

fn findTokenByLexemePtr(tokens: []const Token, lexeme: []const u8) ?Token {
    for (tokens) |token| {
        if (token.lexeme.ptr == lexeme.ptr) {
            return token;
        }
    }
    return null;
}

fn findExprLocation(tokens: []const Token, expr: *Expression) ?Token {
    switch (expr.*) {
        .Variable => |v| return findTokenByLexemePtr(tokens, v),
        .Unit => return null,
        .Number => |n| return findTokenByLexemePtr(tokens, n),
        .Import => |fileName| return findTokenByLexemePtr(tokens, fileName),
        .String => |s| return findTokenByLexemePtr(tokens, s),
        .Boolean => |b| {
            const target_text = if (b) "true" else "false";
            for (tokens) |token| {
                if (std.ascii.eqlIgnoreCase(token.lexeme, target_text)) {
                    return token;
                }
            }
            return null;
        },
        .BinaryOperation => |bop| return findExprLocation(tokens, bop.left),
        .Not => |not| return findExprLocation(tokens, not),
        .UnaryMinus => |unaryMinus| return findExprLocation(tokens, unaryMinus),
        .Condition => |cond| return findExprLocation(tokens, cond.expression),
        .Declaration => |decl| return findTokenByLexemePtr(tokens, decl.identifier),
        .Lambda => |lam| return findTokenByLexemePtr(tokens, lam.identifier),
        .Match => |mat| return findExprLocation(tokens, mat.scrutinee),
        .Tuple => |val| return findExprLocation(tokens, val[0]),
        .Application => |app| return findExprLocation(tokens, app.callee),
        .MemberAccess => |memberAccess| return findTokenByLexemePtr(tokens, memberAccess.member),
        .Module => |module| return findTokenByLexemePtr(tokens, module.identifier),
        .CurrentEnvironment => return null,
    }
}

fn printSourceHighlight(source: []const u8, line_num: usize, col_num: usize, lexeme_len: usize) void {
    var current_line: usize = 1;
    var line_start: usize = 0;
    var line_end: usize = 0;

    for (source, 0..) |char, i| {
        if (current_line == line_num) {
            if (line_start == 0 and i > 0 and source[i - 1] == '\n') {
                line_start = i;
            } else if (i == 0) {
                line_start = 0;
            }
        }
        if (char == '\n') {
            if (current_line == line_num) {
                line_end = i;
                break;
            }
            current_line += 1;
        }
    }
    if (line_end == 0) {
        line_end = source.len;
    }

    const line_content = source[line_start..line_end];

    std.debug.print("\n  | {s}\n", .{line_content});
    std.debug.print("  | ", .{});

    var i: usize = 1;
    while (i < col_num) : (i += 1) {
        std.debug.print(" ", .{});
    }

    std.debug.print(ansi.bold ++ ansi.red, .{});
    var len = lexeme_len;
    if (len == 0) len = 1;
    i = 0;
    while (i < len) : (i += 1) {
        std.debug.print("^", .{});
    }
    std.debug.print(ansi.reset ++ "\n\n", .{});
}

fn printErrorLocation(prefix: []const u8, filePath: []const u8) void {
    if (filePath.len > 0 and !std.mem.eql(u8, filePath, "repl") and !std.mem.eql(u8, filePath, "_")) {
        std.debug.print(ansi.bold ++ ansi.red ++ "{s} in {s}: " ++ ansi.reset, .{ prefix, filePath });
    } else {
        std.debug.print(ansi.bold ++ ansi.red ++ "{s}: " ++ ansi.reset, .{prefix});
    }
}
