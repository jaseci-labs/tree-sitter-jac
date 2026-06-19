; Text objects (nvim-treesitter-textobjects).

; Functions / abilities
(ability) @function.outer
(ability (block_body) @function.inner)
(lambda_expression) @function.outer

; Archetypes / enums behave as "classes"
(archetype) @class.outer
(enum) @class.outer

; Implementation blocks
(impl) @function.outer
(impl (block_body) @function.inner)

; Parameters / arguments
(param) @parameter.inner
(param) @parameter.outer
(argument) @parameter.inner
(argument) @parameter.outer

; Calls
(call_expression) @call.outer
(call_expression (argument_list) @call.inner)

; Conditionals
(if_statement) @conditional.outer
(match_statement) @conditional.outer
(switch_statement) @conditional.outer

; Loops
(for_statement) @loop.outer
(while_statement) @loop.outer

; Comments
(comment) @comment.outer
