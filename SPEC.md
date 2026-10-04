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

body = array_body | object_body ;

value = scalar | container ;
salar = string | number | boolean | "null" ;
container = array | object ;

object = "{" , [ white_space ], [ object_body ] , [ white_space ] , "}" ;
entry = [ "." ] , key , [ white_space ] , separator , [ white_space ] , value ;
key = indentifier | quoted_string ;
separator = "=" | ":" ;

array = "[" , [ white_space ] , [ array_body ] , [ white_space ] , "]" | "{" , [ white_space ] , [ array_body ] , [ white_space ] , "}" ;

indentifier = { character - ( separator | "," | "[" | "]" | "{" | "}" | "#" | "/" | white_space ) } ; 

number = [ "-" | "+" ] , digit , { digit } , [ "." , { digit } ] , [ exponent ] ;
exponent = ( "e" | "E" ) , [ "-", "+" ] , digit , { digit } ; 

boolean = "true" | "false" ;
white_space = { "" | "\t" | "\n" | "\r" | comment }
comment = ( "#" | "//" ), { character - "\n" } , "\n" ;
hex_digit       = "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" | "a" | "b" | "c" | "d" | "e" | "f" ;
digit           = "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" ;
character = ? all unicode characters ? ;
```