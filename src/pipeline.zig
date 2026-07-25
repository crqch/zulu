const std = @import("std");

const zulu = @import("./root.zig");
const Options = zulu.Options;
const ansi = zulu.ansi;
const ReturnValue = zulu.SharedContext.ReturnType;
const SharedContext = zulu.SharedContext;
const Lexer = zulu.Lexer;
const LexerError = zulu.Lexer.LexerError;
const Parser = zulu.Parser;
const ParserError = zulu.Parser.ParserError;
const AstPrinter = zulu.AstPrinter;
const TypeChecker = zulu.TypeChecker;
const TypeError = zulu.TypeChecker.TypeError;
const Interpreter = zulu.Interpreter;
const InterpreterError = zulu.Interpreter.InterpreterError;

const Token = zulu.Token;
const Expression = zulu.Expression;

const Pipeline = @This();
allocator: std.mem.Allocator,
options: Options,
type_arena: std.heap.ArenaAllocator,
type_checker: TypeChecker,

pub fn init(allocator: std.mem.Allocator, options: Options) Pipeline {
    var type_arena = std.heap.ArenaAllocator.init(allocator);
    const type_allocator = type_arena.allocator();
    const type_checker = TypeChecker.init(type_allocator, null);

    return Pipeline{
        .allocator = allocator,
        .options = options,
        .type_arena = type_arena,
        .type_checker = type_checker,
    };
}

pub fn deinit(self: *Pipeline) void {
    self.type_arena.deinit();
}

pub fn run(self: *Pipeline, shared_context: *SharedContext, file_path: []const u8, source: []const u8, options: Options) !?ReturnValue {
    var lexer = try Lexer.init(self.allocator, source);
    defer lexer.deinit();

    var type_checker = TypeChecker.init(self.type_arena.allocator(), shared_context);

    const tokens = lexer.scanTokens() catch |err| {
        printErrorLocation("Lexer Error", file_path);
        switch (err) {
            LexerError.UnmatchedToken => {
                const char = if (lexer.current > 0) lexer.source[lexer.current - 1] else '?';
                std.debug.print("Unexpected character '{c}' at line {}, column {}.\n", .{ char, lexer.line, lexer.column });
                printSourceHighlight(source, lexer.line, lexer.column, 1);
            },
            LexerError.UnterminatedStringLiteral => {
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
        const tokens_printed = try lexer.printTokens();
        std.debug.print("{s}", .{tokens_printed});
    }

    if (options.@"halt-lexer") {
        return null;
    }

    var parser = Parser.init(self.allocator, tokens, shared_context);
    const expression = parser.parse() catch |err| {
        printErrorLocation("Parser Error", file_path);
        const token = if (parser.current < parser.tokens.len) parser.tokens[parser.current] else parser.tokens[parser.tokens.len - 1];
        switch (err) {
            ParserError.EofNotReached => {
                std.debug.print("Unexpected token '{s}' at line {}, column {} (extra input after expression).\n", .{ token.lexeme, token.location.line, token.location.column });
            },
            ParserError.ExpectedVariableAtDeclaration => {
                std.debug.print("Expected variable identifier in declaration at line {}, column {}.\n", .{ token.location.line, token.location.column });
            },
            ParserError.LambdaUnresolved => {
                std.debug.print("Unresolved lambda syntax at line {}, column {}.\n", .{ token.location.line, token.location.column });
            },
            ParserError.ExpectedExpression => {
                std.debug.print("Expected expression at line {}, column {}.\n", .{ token.location.line, token.location.column });
            },
            ParserError.ParanthesesUnmatched => {
                std.debug.print("Unmatched parentheses starting at line {}, column {}.\n", .{ token.location.line, token.location.column });
            },
            ParserError.UnknownEscapeCharacter => {
                std.debug.print("Unknown escape character in string literal at line {}, column {}.\n", .{ token.location.line, token.location.column });
            },
            ParserError.NotABinaryOperation => {
                std.debug.print("Invalid binary operation at line {}, column {}.\n", .{ token.location.line, token.location.column });
            },
            ParserError.OutOfMemory => {
                std.debug.print("Out of memory.\n", .{});
            },
            ParserError.UnexpectedToken => {
                if (token.type == .eof) {
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
        const printed_expr = try AstPrinter.prettyPrint(self.allocator, expression.*);
        std.debug.print("{s}\n", .{printed_expr});
    }

    if (options.@"halt-parser") {
        return null;
    }

    const program_type = type_checker.inferType(expression) catch |err| {
        switch (err) {
            TypeError.UnexpectedType => {
                printErrorLocation("Type Error", file_path);
                std.debug.print("Unexpected type\n" ++ ansi.reset, .{});
                if (type_checker.error_context) |context| {
                    if (findExprLocation(tokens, context.unexpected_type.context)) |token| {
                        printSourceHighlight(source, token.location.line, token.location.column, token.lexeme.len);
                    }

                    std.debug.print("Expected one of the following types:\n", .{});
                    for (context.unexpected_type.expected_type) |expectedType| {
                        std.debug.print(ansi.blue ++ "\t{s}\n" ++ ansi.reset, .{try TypeChecker.PrettyPrinter.prettyPrint(self.type_arena.allocator(), type_checker.finalizeType(expectedType))});
                    }
                    std.debug.print("But got: " ++ ansi.blue ++ "{s}" ++ ansi.reset ++ "\n", .{try TypeChecker.PrettyPrinter.prettyPrint(self.type_arena.allocator(), type_checker.finalizeType(context.unexpected_type.found_type))});
                }
            },
            else => {
                printErrorLocation("Type Error", file_path);
                std.debug.print("{}\n", .{err});
            },
        }
        return err;
    };
    if (options.@"debug-type") {
        std.debug.print(ansi.bold ++ ansi.green ++ "Typechecker output:\n" ++ ansi.reset, .{});
        const printed_type = try TypeChecker.PrettyPrinter.prettyPrint(self.allocator, type_checker.finalizeType(program_type));
        std.debug.print("{s}\n", .{printed_type});
    }

    if (options.@"halt-type") {
        return null;
    }

    var interpreter = Interpreter.init(self.allocator, shared_context);

    const value = interpreter.eval(expression) catch |err| {
        printErrorLocation("Runtime Error", file_path);
        switch (err) {
            InterpreterError.DivisionByZero => {
                std.debug.print("Division by zero.\n", .{});
            },
            InterpreterError.FloatParsingFailed => {
                std.debug.print("Failed to parse float value.\n", .{});
            },
            InterpreterError.IntParsingFailed => {
                std.debug.print("Failed to parse integer value.\n", .{});
            },
            InterpreterError.EnvironmentInitializationError, error.EnvironmentMapError, error.MemoryAllocationFailed => {
                std.debug.print("Memory allocation or environment initialization failed.\n", .{});
            },
            InterpreterError.Unimplemented => {
                std.debug.print("Unimplemented feature encountered.\n", .{});
            },
            InterpreterError.UnmatchedPattern => {
                std.debug.print("Pattern unmatched in match.\n", .{});
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
        .type = program_type,
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
        .variable => |v| return findTokenByLexemePtr(tokens, v),
        .constructor => |constructor| return findTokenByLexemePtr(tokens, constructor.name),
        .unit => return null,
        .number => |n| return findTokenByLexemePtr(tokens, n),
        .import => |file_name| return findTokenByLexemePtr(tokens, file_name),
        .string => |s| return findTokenByLexemePtr(tokens, s),
        .boolean => |b| {
            const target_text = if (b) "true" else "false";
            for (tokens) |token| {
                if (std.ascii.eqlIgnoreCase(token.lexeme, target_text)) {
                    return token;
                }
            }
            return null;
        },
        .binary_operation => |bop| return findExprLocation(tokens, bop.left),
        .not => |not| return findExprLocation(tokens, not),
        .unary_minus => |unary_minus| return findExprLocation(tokens, unary_minus),
        .condition => |cond| return findExprLocation(tokens, cond.expression),
        .declaration => |decl| return findTokenByLexemePtr(tokens, decl.identifier),
        .type_declaration => |decl| return findTokenByLexemePtr(tokens, decl.identifier),
        .lambda => |lam| return findTokenByLexemePtr(tokens, lam.identifier),
        .match => |mat| return findExprLocation(tokens, mat.scrutinee),
        .tuple => |val| return findExprLocation(tokens, val[0]),
        .application => |app| return findExprLocation(tokens, app.callee),
        .member_access => |member_access| return findTokenByLexemePtr(tokens, member_access.member),
        .module => |module| return findTokenByLexemePtr(tokens, module.identifier),
        .current_environment => return null,
        .use_environment => |env| return findExprLocation(tokens, env.environment),
        .type_ascription => |type_ascription| return findExprLocation(tokens, type_ascription.expression),
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

fn printErrorLocation(prefix: []const u8, file_path: []const u8) void {
    if (file_path.len > 0 and !std.mem.eql(u8, file_path, "repl") and !std.mem.eql(u8, file_path, "_")) {
        std.debug.print(ansi.bold ++ ansi.red ++ "{s} in {s}: " ++ ansi.reset, .{ prefix, file_path });
    } else {
        std.debug.print(ansi.bold ++ ansi.red ++ "{s}: " ++ ansi.reset, .{prefix});
    }
}
