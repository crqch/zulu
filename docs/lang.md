# Language specification (rough)

Zulu is a statically typed, globally inferred functional language.

## Concrete Syntax

- Tokens:

  - Types:
    `PLUS, MINUS, SLASH, ASTERISK, EQ, GT, LT, GTEQ, LTEQ, EQEQ, SLASHSLASH, DOT, SEMICOLON`
    `LPAR, RPAR, LBRA, RBRA`
    `IDENT, NUMBER, STRING`

  - Identifiers
    - Need to start from a [letter;_;@]
    - Can include digits
    - Can include _, #, @, '
    - _ is treated as a wildcard

  - Constructors
    - Need to begin with an upper case character
    - Can include digits, _, #, @

  - Numbers
    - In base 10, need to start from a digit with optional sign [-;+]
    - In other bases, can specify the base using 0[b;x;o;d][content]
    - In base 10 can put a decimal point for decimal values.
    - Leading 0 can be omitted: `0.14` = `.14`

  - String literals
    - A terminated `"` string of text.
    - Can include newlines
    - Special characters escaped with `\`
    - Templating using `#{expr}`, `expr` needs to have a string prototype

  - Keywords
    - Character strings reserved from identifiers

    - `true false if else`

- Math expressions

  Just like in C:

  - `38 + 4`
  - `44 - 2`
  - `84 / 2`
  - `21 * 2`

- Comparison operators

  - `4 > 2`
  - `4 < 2`
  - `4 >= 2`
  - `4 <= 2`
  - `4 = 2`
  - `2 = 2.0 // true`
  - `2 == 2.0 // false`

- Variable declaration and closures

  Variable declarations are left-associative

  - `ident=expr;expr`
    e.g
  - `x = 10; x > 8`
  - `x = 10; ( x > 8 )`
  - `x = 10; ( x=12; x > 11 )`
  - `x = 10;x = 12;x > 11`

  Lambdas

  - `[x; x * x]`
  - `[x; x * x] 2`
  - `[x y; x * y]`
  - `[f x y; f x * f y]`
  - `[f x y; f x * f y] [x; x * x] 2 3`

  - `sq=[x; x * x];[f x y; f x * f y] sq 2 3`

  To make a lambda recursive, there should be a declaration to an identifier starting with `@` character:

  `@fib=[x; if (x < 1) 1 else fib (x - 1) + fib (x - 2)];@fib 10`

TODO
