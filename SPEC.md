## DJSON Language Specification

### 1. Introduction

DJSON is a data-serialization format designed to be human-readable and writable while maintaining strict compatibility with the JSON data model. It features implicit root objects, optimal commas, and "bare" (unquoted) strings to reduce visual noise.

### 2. Data Model

DJSON supports the following types:

- *Null*: Represented by the keyword `null`.
- *Boolean*: Represented by keywords `true` or `false`.
- *Integer*: 64 signed integers.
- *Float*: 64-bit IEEE 754 floating-point numbers.
- *String*: UTF-8 encoded sequences of characters.
- *Array*: An ordered list of values.
- *Object*: An ordered mapping of unique string keys to values.

### 3. Syntax

### 3.1. Structure

A DJSON document can be

1. A single **Value** (e.g., a single array `[...]` or object `{...}`).
2. A **Body** representing an implicit top-level object (the default).

### 3.2. Body

A Body consists of a sequence of **Entries** or **Bare Values**

- A Body cannot mix Keyed Entries and Bare Values.
- If the first item is a Keyed Entry, the container is an **Object**.
- If the first item is a Bare Value, the container is an **Array**.

### 3.3. Entries (Key-Value Pairs)

Entries are defined as: `[.]key [= | :] value`

- **Dots**: A leading dot `.` is optional for keys.
- **Separators**: Both `=` and `:` are valid separators. `:` is only treated as a separator if followed by a whitespace,
a quote, or a bracket (to allow string like `12:00` to remain unquoted).
- **Termination**: Entries must be separated by a newline, a comma `,`, or both.

### 3.4 Values

**Scalars**

- **Keywords**: `true`, `false`, `null`.
- **Numbers**: Standard decimal notation. Leading zeros (eg. `007`) are treated as Ids.
    - **Decimal**: `1234`, `1_000_000`.
    - **Hex/Bin/Oct**: `0xFF`, `0b1010`, `0o77`.
    - **Underscore**: `_` is permitted as a visual separator in any numeric type.
    - **Leading Zeros**: `007` is treated as a String (ID protection).
- **Unquoted Strings**: Characters until a separator, newline, or comment, Leading/trailing whitespace is trimmed.
- **Quoted Strings**: Surrounded by `"`. Supports standard JSON escapes: `\"`, `\\`, `\/`, `\b`, `\f`, `\n`, `\r`, `\t`, and `\uXXXX` (including surrogate pairs).

**Containers**

- **Braces `{}`**: Can be represent an Object or an Array depending on the contents (see 3.2).
- **Brackets `[]`**: Explicitly forces the container to be an Array.
- **Nesting**: Maximum depth is 256.

### 3.5 Comments

- **Line Comments**: Start with `#` or `//`
- Comments must either start at the beginning of a line or be preceded by whitespace.
- Comments continue, until the the end of the line.

### Lexical Classification

When a value is not quoted, it is classified in the following priority:

1. `true` / `false` / `null` keywords.
2. **Number**: If it matches numeric pattern and does not have invalid leading zeros.
3. **String**: All other cases. 

### EBNF Grammer

```ebnf
document = [ white_space ] , ( explicit_value | body ) , [ white_space ] ;

body = { entry | bare_value } ;

value = scalar | container ;
scalar = string | number | boolean | "null" ;
container = array | object ;

object = "{" , [ white_space ], [ body ] , [ white_space ] , "}" ;
entry = [ "." ] , key , [ white_space ] , separator , [ white_space ] , value ;
key = identifier | quoted_string ;
separator = "=" | ":" ;

array = "[" , [ white_space ] , [ body ] , [ white_space ] , "]" 
      | "{" , [ white_space ] , [ body ] , [ white_space ] , "}" ;

bare_value = value ;

identifier = { character - ( separator | "," | "[" | "]" | "{" | "}" | "#" | "/" | white_space ) } ; 

number = [ "-" | "+" ] , ( hex_lit | bin_lit | oct_lit | dec_lit ) ;
dec_lit = digit , { digit | "_" } , [ "." , { digit | "_" } ] , [ exponent ] ;
hex_lit = "0" , ( "x" | "X" ) , hex_digit , { hex_digit | "_" } ;
bin_lit = "0" , ( "b" | "B" ) , bin_digit , { bin_digit | "_" } ;
oct_lit = "0" , ( "o" | "O" ) , oct_digit , { oct_digit | "_" } ;

exponent = ( "e" | "E" ) , [ "-" | "+" ] , digit , { digit | "_" } ; 

string = quoted_string | raw_string | identifier ;
quoted_string = '"' , { character - '"' | escape_seq } , '"' ;
raw_string = '"""' , { character } , '"""' ;

white_space = { " " | "\t" | "\n" | "\r" | comment } ;
comment = ( "#" | "//" ), { character - "\n" } , ( "\n" | ? EOF ? ) ;

hex_digit = "0"..."9" | "a"..."f" | "A"..."F" ;
bin_digit = "0" | "1" ;
oct_digit = "0"..."7" ;
digit     = "0"..."9" ;
character = ? all unicode characters ? ;
```