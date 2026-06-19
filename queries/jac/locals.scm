; Scopes
[
  (archetype)
  (ability)
  (lambda_expression)
  (for_statement)
  (while_statement)
  (with_statement)
  (if_statement)
  (match_statement)
] @local.scope

; Definitions
(has_var name: (identifier) @local.definition.field)
(param (identifier) @local.definition.parameter)
(ability name: (identifier) @local.definition.function)
(archetype name: (identifier) @local.definition.type)
(enum name: (identifier) @local.definition.type)
(global_var (identifier) @local.definition.var)

; References
(identifier) @local.reference
