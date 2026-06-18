; Comments
(comment) @comment

; Literals
(integer) @number
(float) @number.float
(string) @string
(bool) @boolean
(null) @constant.builtin
(ellipsis) @constant.builtin
(builtin_type) @type.builtin
(special_ref) @variable.builtin

; Identifiers
(identifier) @variable
(kwesc_name) @variable

; Declarations
(archetype name: (identifier) @type)
(enum name: (identifier) @type)
(ability name: (identifier) @function)
(has_var name: (identifier) @property)
(param (identifier) @variable.parameter)

; Calls & attributes
(call_expression function: (identifier) @function.call)
(attribute_expression attr: (identifier) @property)
(argument name: (identifier) @variable.parameter)

; Declaration keywords
[
  "obj" "node" "edge" "walker" "class" "enum"
  "has" "can" "def" "impl" "test" "sem" "glob"
  "static" "override" "abs" "async"
] @keyword

; Control flow
[
  "if" "elif" "else" "while" "for" "in" "to" "by"
  "try" "except" "finally" "awaiting" "with"
  "match" "case" "switch" "default"
  "return" "yield" "raise" "assert" "del"
  "break" "continue" "skip" "disengage"
  "visit" "report" "spawn"
] @keyword

; Import keywords
[ "import" "include" "from" "as" ] @keyword.import

; Object-spatial / context keywords
[ "entry" "exit" "cl" "sv" "na" "lambda" "global" "nonlocal" "flow" "wait" "await" ] @keyword

; Access modifiers
[ "pub" "priv" "protect" ] @keyword.modifier

; Operators
[
  "=" ":=" "+" "-" "*" "/" "//" "%" "**" "@"
  "==" "!=" "<" ">" "<=" ">=" "&" "|" "^" "~" "<<" ">>"
  "+=" "-=" "*=" "/=" "//=" "%=" "**=" "@=" "&=" "|=" "^=" "<<=" ">>="
  "and" "or" "not" "is"
  "|>" "<|" ":>" "<:"
] @operator

; Graph / edge operators
[ "-->" "<--" "<-->" "++>" "<++" "<++>" "->:" ":->" "<-:" ":<-" "+>:" ":+>" "<+:" ":<+" ] @operator

; Decorators
(decorator? "@" @attribute)

; Punctuation
[ "(" ")" "[" "]" "{" "}" ] @punctuation.bracket
[ "," ";" ":" "." "->" ] @punctuation.delimiter
