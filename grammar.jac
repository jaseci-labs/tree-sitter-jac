"""Tree-sitter grammar for the Jac programming language, authored in Jac OSP.

The grammar is built as an **object-spatial graph**: every tree-sitter rule
construct is a `node`, structure is expressed with ordered child edges, and a
node ability (`emit`) serializes the graph to `src/grammar.json`, which
`tree-sitter generate` consumes to produce `src/parser.c`.

Why OSP fits: a tree-sitter grammar is an ordered, nested (and, via rule
references, cyclic) structure -- exactly the shape object-spatial graphs model
well, now that out-edge ordering is a guaranteed OSP semantic (connection
order; jaseci-labs/jaseci#6785). `seq(A, B, C)` connects three child edges in
order, and `[self -->]` reads them back in that same order at emit time.

Source of truth: the language's own EBNF, auto-extracted from the jaclang
parser by `grammar_extract_pass` and published as `jaclang/jac.spec`. This file
is a hand-tuned translation of that spec into tree-sitter rules.

Build:  jac run grammar.jac        # writes src/grammar.json
        tree-sitter generate src/grammar.json
"""

import json;
import os;

# ===========================================================================
# Grammar node types
#
# Each node mirrors a node in the tree-sitter grammar.json schema. Structural
# children hang off ordered out-edges (generic `++>`); a node's own scalar
# data (a literal value, a field name, a precedence level) lives in `has`
# fields. `emit` folds the subgraph rooted at the node into grammar.json.
# ===========================================================================

"""Base type for every grammar construct; `emit` returns its grammar.json."""
node GNode {
    def emit -> dict abs;
}

"""A literal string token (an anonymous terminal), e.g. "obj"."""
node Lit(GNode) {
    has value: str;
    def emit -> dict { return {"type": "STRING", "value": self.value}; }
}

"""A regular-expression token."""
node Pat(GNode) {
    has value: str;
    def emit -> dict { return {"type": "PATTERN", "value": self.value}; }
}

"""A reference to another rule by name (the $.<name> of grammar.js)."""
node Sym(GNode) {
    has name: str;
    def emit -> dict { return {"type": "SYMBOL", "name": self.name}; }
}

"""The empty match."""
node Blank(GNode) {
    def emit -> dict { return {"type": "BLANK"}; }
}

"""Ordered sequence: A B C (children are the ordered members)."""
node Seq(GNode) {
    def emit -> dict {
        members = [];
        for k in [self -->] { members.append(k.emit()); }
        return {"type": "SEQ", "members": members};
    }
}

"""Alternatives: A | B | C (children are the ordered members)."""
node Choice(GNode) {
    def emit -> dict {
        members = [];
        for k in [self -->] { members.append(k.emit()); }
        return {"type": "CHOICE", "members": members};
    }
}

"""Zero or more: A* (one child)."""
node Rep(GNode) {
    def emit -> dict { return {"type": "REPEAT", "content": [self -->][0].emit()}; }
}

"""One or more: A+ (one child)."""
node Rep1(GNode) {
    def emit -> dict { return {"type": "REPEAT1", "content": [self -->][0].emit()}; }
}

"""Lexer-level token: treat the contained subrule as a single terminal."""
node Tok(GNode) {
    def emit -> dict { return {"type": "TOKEN", "content": [self -->][0].emit()}; }
}

"""Token that must immediately follow the previous one (no extras between)."""
node ITok(GNode) {
    def emit -> dict {
        return {"type": "IMMEDIATE_TOKEN", "content": [self -->][0].emit()};
    }
}

"""Attach a field name to a child (for queries / tree navigation)."""
node Field(GNode) {
    has name: str;
    def emit -> dict {
        return {"type": "FIELD", "name": self.name, "content": [self -->][0].emit()};
    }
}

"""Rename a node in the output tree."""
node Alias(GNode) {
    has name: str, named: bool = True;
    def emit -> dict {
        return {
            "type": "ALIAS",
            "value": self.name,
            "named": self.named,
            "content": [self -->][0].emit()
        };
    }
}

"""Precedence wrapper. `kind` selects PREC / PREC_LEFT / PREC_RIGHT / PREC_DYNAMIC."""
node Prec(GNode) {
    has kind: str, level: int;
    def emit -> dict {
        return {"type": self.kind, "value": self.level, "content": [self -->][0].emit()};
    }
}

# ===========================================================================
# Builder DSL
#
# Each helper spawns the node and connects its children in order, then returns
# the node -- so call sites compose inline and read like the EBNF, exactly as
# `seq`/`choice`/`repeat`/... do in grammar.js. Ordered out-edges are what make
# the hidden spawn+connect faithful to member order.
# ===========================================================================

def lit(value: str) -> GNode { return Lit(value=value); }

def pat(value: str) -> GNode { return Pat(value=value); }

def sym(name: str) -> GNode { return Sym(name=name); }

def blank() -> GNode { return Blank(); }

def seq(*members: GNode) -> GNode {
    n = Seq();
    for m in members { n ++> m; }
    return n;
}

def choice(*members: GNode) -> GNode {
    n = Choice();
    for m in members { n ++> m; }
    return n;
}

def opt(r: GNode) -> GNode { return choice(r, blank()); }

def rep(r: GNode) -> GNode { n = Rep(); n ++> r; return n; }

def rep1(r: GNode) -> GNode { n = Rep1(); n ++> r; return n; }

def tok(r: GNode) -> GNode { n = Tok(); n ++> r; return n; }

def itok(r: GNode) -> GNode { n = ITok(); n ++> r; return n; }

def field(name: str, r: GNode) -> GNode { n = Field(name=name); n ++> r; return n; }

def alias(r: GNode, name: str, named: bool = True) -> GNode {
    n = Alias(name=name, named=named);
    n ++> r;
    return n;
}

def prec(level: int, r: GNode) -> GNode {
    n = Prec(kind="PREC", level=level);
    n ++> r;
    return n;
}

def precl(level: int, r: GNode) -> GNode {
    n = Prec(kind="PREC_LEFT", level=level);
    n ++> r;
    return n;
}

def precr(level: int, r: GNode) -> GNode {
    n = Prec(kind="PREC_RIGHT", level=level);
    n ++> r;
    return n;
}

def precd(level: int, r: GNode) -> GNode {
    n = Prec(kind="PREC_DYNAMIC", level=level);
    n ++> r;
    return n;
}

"""Comma-separated list of one or more `r` (no trailing comma)."""
def comma_sep1(r: GNode) -> GNode { return seq(r, rep(seq(lit(","), r))); }

"""Comma-separated list of zero or more `r`."""
def comma_sep(r: GNode) -> GNode { return opt(comma_sep1(r)); }

# ===========================================================================
# Grammar assembly
#
# A `Rule` is a named node with exactly one child (its body). The `Grammar`
# root connects to its rules in order -- and order matters: tree-sitter treats
# the FIRST rule as the start symbol, so ordered edges carry meaning even here.
# ===========================================================================

node Rule {
    has name: str;
    def body_json -> dict { return [self -->][0].emit(); }
}

node Grammar {
    has name: str;
    def rules_json -> dict {
        rules = {};
        for r in [self -->] { rules[r.name] = r.body_json(); }
        return rules;
    }
}

"""Spawn a named rule whose body is `body`."""
def rule(g: Grammar, name: str, body: GNode) -> None {
    r = Rule(name=name);
    r ++> body;
    g ++> r;
}

# ===========================================================================
# Convenience builders for repeated EBNF shapes.
# ===========================================================================

"""(NAME | KWESC_NAME) -- the two identifier forms. References the SHARED
`_name_ref` rule rather than inlining the 2-way choice at ~50 sites, so
tree-sitter shares those states instead of duplicating them. The rule is
HIDDEN (leading `_`): hidden rules still share parse states, but are elided
from the syntax tree, so `identifier`/`kwesc_name` surface directly under the
parent field (e.g. `has_var name: (identifier)`) instead of being buried one
level down under a `name_ref` node -- which keeps the queries flat."""
def name_ref() -> GNode { return sym("_name_ref"); }

"""access_tag ::= (":" ("pub" | "priv" | "protect")?)?"""
def access_tag() -> GNode {
    return opt(seq(lit(":"), opt(choice(lit("pub"), lit("priv"), lit("protect")))));
}

"""Decorators `(@expr)*`. References the SHARED `decorator_list` rule (rep1,
defined in build_decls) wrapped in opt, so the decorator-prefix states are
built once rather than duplicated across every decl that can carry them."""
def decorators() -> GNode { return opt(sym("decorator_list")); }

"""A `{ ... }` code block. References the SHARED `block_body` rule (defined in
build_stmts) so tree-sitter builds the statement-list state machine ONCE,
instead of duplicating it at every block site (which exploded the parse
table). `block_body` is rep1 (non-empty); `opt` handles the empty `{}`."""
def block() -> GNode {
    return seq(lit("{"), opt(sym("block_body")), lit("}"));
}

# ===========================================================================
# Tokens
# ===========================================================================

def build_tokens(g: Grammar) -> None {
    rule(g, "identifier", tok(pat("[a-zA-Z_][a-zA-Z0-9_]*")));
    rule(g, "kwesc_name", tok(pat("`[a-zA-Z_][a-zA-Z0-9_]*")));
    rule(g, "_name_ref", choice(sym("identifier"), sym("kwesc_name")));
    rule(g, "integer", tok(choice(
        pat("0[xX][0-9a-fA-F_]+"),
        pat("0[bB][01_]+"),
        pat("0[oO][0-7_]+"),
        pat("[0-9][0-9_]*")
    )));
    rule(g, "float", tok(choice(
        pat("[0-9][0-9_]*\\.[0-9_]*([eE][-+]?[0-9_]+)?"),
        pat("\\.[0-9][0-9_]*([eE][-+]?[0-9_]+)?"),
        pat("[0-9][0-9_]*[eE][-+]?[0-9_]+")
    )));
    # NOTE: f-strings and JSX text need an external C scanner for full fidelity
    # (interpolation / context-sensitive lexing). v0.1 treats strings -- incl.
    # f/r/b-prefixed -- as opaque tokens; interpolated exprs are not yet split
    # out. Tracked as the external-scanner follow-up.
    rule(g, "string", tok(seq(
        opt(pat("[rRbBfF]+")),
        choice(
            pat("\"\"\"([^\"]|\"[^\"]|\"\"[^\"])*\"\"\""),
            pat("'''([^']|'[^']|''[^'])*'''"),
            pat("\"([^\"\\\\\\n]|\\\\.)*\""),
            pat("'([^'\\\\\\n]|\\\\.)*'")
        )
    )));
    rule(g, "bool", choice(lit("True"), lit("False")));
    rule(g, "null", lit("None"));
    rule(g, "ellipsis", lit("..."));
    rule(g, "comment", tok(pat("#.*")));
    rule(g, "pyinline", tok(pat("::py::")));
    bt = [];
    for t in [
        "str", "int", "float", "list", "tuple", "set", "dict", "bool", "bytes",
        "any", "type", "i8", "u8", "i16", "u16", "i32", "u32", "i64", "u64",
        "f32", "f64"
    ] { bt.append(lit(t)); }
    rule(g, "builtin_type", choice(*bt));
    sr = [];
    for s in [
        "self", "super", "here", "root", "visitor", "props", "init", "postinit"
    ] { sr.append(lit(s)); }
    rule(g, "special_ref", choice(*sr));
}

# ===========================================================================
# Expressions
#
# The jac.spec precedence cascade is realized the idiomatic tree-sitter way:
# one `expression` supertype and a `binary_expression` whose alternatives carry
# `prec` levels read straight off the spec's ordering (higher binds tighter).
# ===========================================================================

def build_expr(g: Grammar) -> None {
    rule(g, "expression", choice(
        sym("binary_expression"),
        sym("unary_expression"),
        sym("ternary_expression"),
        sym("lambda_expression"),
        sym("connect_expression"),
        sym("_primary_expression")
    ));

    # (operator, precedence) for left-associative binary operators.
    binops = [
        ["|>", 6], ["<|", 7], ["or", 8], ["and", 9],
        ["==", 11], ["!=", 11], ["<", 11], [">", 11], ["<=", 11], [">=", 11],
        ["in", 11], ["is", 11],
        ["|", 12], ["^", 13], ["&", 14], ["<<", 15], [">>", 15],
        ["+", 16], ["-", 16], ["*", 17], ["/", 17], ["//", 17], ["%", 17],
        ["@", 17], ["by", 4],
        # atomic pipes (jac.spec: atomic_pipe / atomic_pipe_back). Both
        # left-assoc and bind between connect_expression (20) and
        # spawn_expression (23): `:>` looser than `<:`, matching the spec's
        # `atomic_pipe ::= atomic_pipe_back (":>" atomic_pipe_back)*` cascade.
        [":>", 21], ["<:", 22]
    ];
    # NOTE: `as` is intentionally NOT a binary (cast) operator here. It is the
    # binding keyword in except/with/import clauses; treating it as an operator
    # too creates pervasive conflicts. Cast `x as T` is deferred. (v0.1)
    alts = [];
    for op in binops {
        alts.append(precl(op[1], seq(
            field("left", sym("expression")),
            field("operator", lit(op[0])),
            field("right", sym("expression"))
        )));
    }
    # multi-word comparison operators
    for words in [["not", "in"], ["is", "not"]] {
        alts.append(precl(11, seq(
            field("left", sym("expression")),
            field("operator", seq(lit(words[0]), lit(words[1]))),
            field("right", sym("expression"))
        )));
    }
    # right-associative: ** and walrus
    alts.append(precr(18, seq(
        field("left", sym("expression")),
        field("operator", lit("**")),
        field("right", sym("expression"))
    )));
    alts.append(precr(3, seq(
        field("left", sym("expression")),
        field("operator", lit(":=")),
        field("right", sym("expression"))
    )));
    rule(g, "binary_expression", choice(*alts));

    # Prefix operators. `|>` / `:>` are the prefix pipe-call forms
    # (jac.spec `pipe_call`), e.g. `x = :> uuid4()` -- distinct from their
    # binary (atomic-)pipe roles, disambiguated by the absence of a left operand.
    uops = [];
    for u in ["not", "~", "-", "+", "*", "**", "&", "|>", ":>"] { uops.append(lit(u)); }
    rule(g, "unary_expression", precr(19, seq(
        field("operator", choice(*uops)),
        field("operand", sym("expression"))
    )));

    rule(g, "ternary_expression", precr(1, seq(
        field("consequence", sym("expression")),
        lit("if"),
        field("condition", sym("expression")),
        lit("else"),
        field("alternative", sym("expression"))
    )));

    # flow/wait prefix and await/spawn/ref/unpack prefixes
    rule(g, "concurrent_expression", prec(2, seq(
        choice(lit("flow"), lit("wait")), sym("expression")
    )));

    # Lower precedence than ternary so the body greedily absorbs a trailing
    # `if/else` (`lambda: a if b else c` -> body is `(a if b else c)`).
    rule(g, "lambda_expression", precr(-1, seq(
        lit("lambda"),
        # jac.spec: `("(" func_params ")" | lambda_params)` -- params may be
        # parenthesized (`lambda (x: int) -> int { ... }`) or bare
        # (`lambda x: int : expr`).
        opt(choice(sym("parameter_list"), sym("lambda_params"))),
        opt(seq(lit("->"), sym("expression"))),
        choice(seq(lit(":"), sym("expression")), block())
    )));
    rule(g, "lambda_params", comma_sep1(sym("param")));

    # ---- primary / atoms -------------------------------------------------
    rule(g, "_primary_expression", choice(
        sym("_atom"),
        sym("call_expression"),
        sym("index_expression"),
        sym("attribute_expression"),
        sym("await_expression"),
        sym("spawn_expression"),
        sym("edge_reference")
    ));
    rule(g, "_atom", choice(
        name_ref(),
        sym("integer"),
        sym("float"),
        sym("string"),
        sym("multistring"),
        sym("bool"),
        sym("null"),
        sym("ellipsis"),
        sym("builtin_type"),
        sym("special_ref"),
        sym("parenthesized_expression"),
        sym("list"),
        sym("dict"),
        sym("set"),
        sym("comprehension")
    ));
    rule(g, "multistring", prec(2, seq(sym("string"), rep1(sym("string")))));

    rule(g, "parenthesized_expression", seq(
        lit("("), opt(comma_sep1(sym("expression"))), opt(lit(",")), lit(")")
    ));

    rule(g, "attribute_expression", precl(28, seq(
        field("object", sym("_primary_expression")),
        choice(lit("."), lit(".>"), lit("<."), lit("?.")),
        field("attr", name_ref())
    )));
    rule(g, "call_expression", precl(28, seq(
        field("function", sym("_primary_expression")),
        sym("argument_list")
    )));
    rule(g, "argument_list", seq(
        lit("("), opt(comma_sep1(sym("argument"))), opt(lit(",")), lit(")")
    ));
    rule(g, "argument", choice(
        seq(field("name", name_ref()), lit("="), sym("expression")),
        seq(lit("**"), sym("expression")),
        seq(lit("*"), sym("expression")),
        # bare expression, optionally a generator expression `f(x for x in y)`
        seq(sym("expression"), opt(sym("comprehension_clauses")))
    ));
    rule(g, "index_expression", precl(28, seq(
        field("object", sym("_primary_expression")),
        opt(lit("?")),
        lit("["), sym("slice"), lit("]")
    )));
    rule(g, "slice", choice(
        seq(opt(sym("expression")), lit(":"), opt(sym("expression")),
            opt(seq(lit(":"), opt(sym("expression"))))),
        comma_sep1(sym("expression"))
    ));
    rule(g, "await_expression", prec(26, seq(lit("await"), sym("expression"))));
    rule(g, "spawn_expression", precl(23, seq(
        sym("expression"), lit("spawn"), sym("expression")
    )));
}

# ===========================================================================
# Collections & comprehensions
# ===========================================================================

def build_collections(g: Grammar) -> None {
    rule(g, "list", seq(
        lit("["), opt(comma_sep1(sym("expression"))), opt(lit(",")), lit("]")
    ));
    rule(g, "set", seq(
        lit("{"), comma_sep1(sym("expression")), opt(lit(",")), lit("}")
    ));
    rule(g, "dict", seq(
        lit("{"), opt(comma_sep1(sym("dict_entry"))), opt(lit(",")), lit("}")
    ));
    rule(g, "dict_entry", choice(
        seq(lit("**"), sym("expression")),
        seq(field("key", sym("expression")), lit(":"), field("value", sym("expression")))
    ));
    rule(g, "comprehension", choice(
        sym("list_comprehension"), sym("dict_comprehension"), sym("set_comprehension")
    ));
    rule(g, "list_comprehension", seq(
        lit("["), sym("expression"), sym("comprehension_clauses"), lit("]")
    ));
    rule(g, "set_comprehension", seq(
        lit("{"), sym("expression"), sym("comprehension_clauses"), lit("}")
    ));
    rule(g, "dict_comprehension", seq(
        lit("{"), sym("expression"), lit(":"), sym("expression"),
        sym("comprehension_clauses"), lit("}")
    ));
    # jac.spec: comprehension_clauses ::= compr_clause+ where each clause is a
    # `for X in Y` followed by zero+ trailing `if`s. Clauses INTERLEAVE
    # (`for a in b if c for d in e`), so this is rep1 of (for + ifs), not "all
    # fors then all ifs".
    rule(g, "comprehension_clauses", rep1(seq(sym("for_in_clause"), rep(sym("if_clause")))));
    # The target is a primary-expression list (jac.spec uses `atomic_chain`),
    # NOT a full expression -- a full expression would swallow the `in`
    # separator as a binary `in` comparison (`for (i in y)`). Comma-separated to
    # allow tuple targets `for k, v in ...`.
    # prec 2 (> ternary's 1) so a trailing `if` reduces the iterable and
    # attaches as a comprehension filter instead of starting an (else-less)
    # ternary on the iterable.
    rule(g, "for_in_clause", precr(2, seq(
        opt(lit("async")), lit("for"),
        field("left", comma_sep1(sym("_primary_expression"))),
        lit("in"), field("right", sym("expression"))
    )));
    rule(g, "if_clause", seq(lit("if"), sym("expression")));
}

# ===========================================================================
# Graph / object-spatial operators
# ===========================================================================

def build_edges(g: Grammar) -> None {
    rule(g, "connect_expression", precl(20, seq(
        field("left", sym("expression")),
        field("op", sym("connect_op")),
        field("right", sym("expression"))
    )));
    rule(g, "connect_op", choice(
        lit("++>"), lit("<++"), lit("<++>"),
        seq(lit("+>:"), sym("expression"), opt(seq(lit(":"), sym("expression"))), lit(":+>")),
        seq(lit("<+:"), sym("expression"), opt(seq(lit(":"), sym("expression"))), lit(":<+"))
    ));
    rule(g, "edge_reference", seq(
        lit("["),
        opt(choice(lit("edge"), lit("node"))),
        opt(sym("expression")),
        rep1(seq(sym("edge_op"), opt(sym("edge_filter")))),
        opt(sym("edge_filter")),
        lit("]")
    ));
    rule(g, "edge_op", choice(
        lit("-->"), lit("<--"), lit("<-->"),
        seq(lit("->:"), opt(name_ref()), opt(seq(lit(":"), opt(comma_sep1(sym("expression"))))), lit(":->")),
        seq(lit("<-:"), opt(name_ref()), opt(seq(lit(":"), opt(comma_sep1(sym("expression"))))), lit(":<-"))
    ));
    rule(g, "edge_filter", seq(
        lit("["),
        opt(seq(lit("?"), opt(seq(lit(":"), sym("expression"))))),
        opt(comma_sep1(sym("expression"))),
        lit("]")
    ));
}

# ===========================================================================
# Statements
# ===========================================================================

def build_stmts(g: Grammar) -> None {
    # Every statement self-terminates (own `;`, or ends in a block), so the
    # block body is just a sequence of statements -- no per-statement opt(";"),
    # which would otherwise fight each statement's own terminator.
    rule(g, "block_body", rep1(sym("statement")));
    rule(g, "statement", choice(
        sym("if_statement"),
        sym("while_statement"),
        sym("for_statement"),
        sym("try_statement"),
        sym("with_statement"),
        sym("match_statement"),
        sym("switch_statement"),
        sym("return_statement"),
        sym("yield_statement"),
        sym("raise_statement"),
        sym("assert_statement"),
        sym("delete_statement"),
        sym("control_statement"),
        sym("visit_statement"),
        sym("report_statement"),
        sym("disengage_statement"),
        sym("global_statement"),
        sym("nonlocal_statement"),
        sym("import_statement"),
        sym("global_var"),
        sym("has_statement"),
        sym("ability"),
        sym("archetype"),
        sym("expression_statement"),
        sym("empty_statement")
    ));
    # A lone `;` (e.g. an empty `else { ; }` / `except E { ; }` body).
    rule(g, "empty_statement", lit(";"));
    # A single rule covering expression / assignment / augmented-assignment.
    # Parsing the leading expression once, then an OPTIONAL assignment tail,
    # avoids a GLR conflict over the whole expression grammar (which exploded
    # the parse table). The next token (`=`/`:`/augop vs `;`) decides the tail.
    augops = [];
    for a in ["+=", "-=", "*=", "/=", "//=", "%=", "**=", "@=", "&=", "|=",
              "^=", "<<=", ">>="] { augops.append(lit(a)); }
    rule(g, "expression_statement", seq(
        field("left", sym("expression")),
        opt(choice(
            # `x: T`, `x: T = v` -- a type annotation, optionally with value(s).
            seq(
                lit(":"), field("type", sym("expression")),
                opt(rep1(seq(lit("="), field("right", sym("expression")))))
            ),
            # `x = v`, `x = v = w` -- plain (chained) assignment, no annotation.
            rep1(seq(lit("="), field("right", sym("expression")))),
            seq(field("operator", choice(*augops)), field("right", sym("expression")))
        )),
        lit(";")
    ));

    rule(g, "if_statement", seq(
        lit("if"), field("condition", sym("expression")), block(),
        opt(choice(sym("elif_clause"), sym("else_clause")))
    ));
    rule(g, "elif_clause", seq(
        lit("elif"), field("condition", sym("expression")), block(),
        opt(choice(sym("elif_clause"), sym("else_clause")))
    ));
    rule(g, "else_clause", seq(lit("else"), block()));
    rule(g, "while_statement", seq(
        lit("while"), field("condition", sym("expression")), block(), opt(sym("else_clause"))
    ));
    rule(g, "for_statement", seq(
        opt(lit("async")), lit("for"),
        choice(
            seq(field("target", sym("expression")), lit("in"), field("iter", sym("expression"))),
            seq(field("target", sym("expression")), lit("="), sym("expression"),
                lit("to"), sym("expression"), lit("by"), sym("expression"))
        ),
        block(), opt(sym("else_clause"))
    ));
    rule(g, "try_statement", seq(
        lit("try"), block(),
        opt(seq(lit("awaiting"), block())),
        rep(sym("except_clause")),
        opt(sym("else_clause")),
        opt(seq(lit("finally"), block()))
    ));
    rule(g, "except_clause", seq(
        lit("except"), sym("expression"), opt(seq(lit("as"), name_ref())), block()
    ));
    rule(g, "with_statement", seq(
        opt(lit("async")), lit("with"),
        comma_sep1(seq(sym("expression"), opt(seq(lit("as"), sym("expression"))))),
        block()
    ));
    rule(g, "return_statement", seq(lit("return"), opt(sym("expression")), lit(";")));
    rule(g, "yield_statement", seq(
        lit("yield"), opt(lit("from")), opt(sym("expression")), lit(";")
    ));
    rule(g, "raise_statement", seq(
        lit("raise"), opt(sym("expression")), opt(seq(lit("from"), sym("expression"))), lit(";")
    ));
    rule(g, "assert_statement", seq(
        lit("assert"), sym("expression"), opt(seq(lit(","), sym("expression"))), lit(";")
    ));
    rule(g, "delete_statement", seq(lit("del"), sym("expression"), lit(";")));
    rule(g, "control_statement", seq(choice(lit("break"), lit("continue"), lit("skip")), lit(";")));
    rule(g, "disengage_statement", seq(lit("disengage"), lit(";")));
    # prec.right so the optional trailing `;` is consumed here rather than left
    # to stand alone as an empty_statement.
    rule(g, "visit_statement", precr(1, seq(
        lit("visit"), opt(seq(lit(":"), sym("expression"), lit(":"))),
        sym("expression"), opt(choice(sym("else_clause"), lit(";")))
    )));
    rule(g, "report_statement", seq(lit("report"), sym("expression"), lit(";")));
    rule(g, "global_statement", seq(lit("global"), comma_sep1(name_ref()), lit(";")));
    rule(g, "nonlocal_statement", seq(lit("nonlocal"), comma_sep1(name_ref()), lit(";")));
}

# ===========================================================================
# Patterns (match / switch)
# ===========================================================================

def build_patterns(g: Grammar) -> None {
    rule(g, "match_statement", seq(
        lit("match"), sym("expression"), lit("{"), rep(sym("match_case")), lit("}")
    ));
    rule(g, "match_case", seq(
        lit("case"), sym("pattern"), opt(seq(lit("if"), sym("expression"))),
        lit(":"), rep(sym("statement"))
    ));
    rule(g, "pattern", seq(
        sym("or_pattern"), opt(seq(lit("as"), name_ref()))
    ));
    rule(g, "or_pattern", seq(sym("closed_pattern"), rep(seq(lit("|"), sym("closed_pattern")))));
    rule(g, "closed_pattern", choice(
        sym("bool"), sym("null"), sym("integer"), sym("float"), sym("string"),
        sym("sequence_pattern"), sym("mapping_pattern"), sym("class_pattern"),
        sym("capture_pattern")
    ));
    # Use a dotted name (not a full `expression`) so patterns don't overlap the
    # expression grammar (which collided with `atom`).
    rule(g, "dotted_pattern_name", seq(name_ref(), rep(seq(lit("."), name_ref()))));
    rule(g, "capture_pattern", sym("dotted_pattern_name"));
    rule(g, "sequence_pattern", seq(
        lit("["), comma_sep(choice(seq(lit("*"), name_ref()), sym("pattern"))), opt(lit(",")), lit("]")
    ));
    rule(g, "mapping_pattern", seq(
        lit("{"),
        comma_sep(choice(
            seq(lit("**"), name_ref()),
            seq(choice(sym("integer"), sym("float"), sym("string"), sym("dotted_pattern_name")),
                lit(":"), sym("pattern"))
        )),
        opt(lit(",")), lit("}")
    ));
    rule(g, "class_pattern", seq(
        sym("dotted_pattern_name"), lit("("),
        comma_sep(choice(seq(name_ref(), lit("="), sym("pattern")), sym("pattern"))),
        opt(lit(",")), lit(")")
    ));
    rule(g, "switch_statement", seq(
        lit("switch"), sym("expression"), lit("{"), rep(sym("switch_case")), lit("}")
    ));
    rule(g, "switch_case", seq(
        choice(lit("default"), seq(lit("case"), sym("pattern"))),
        lit(":"), rep(sym("statement"))
    ));
}

# ===========================================================================
# Declarations (archetypes, abilities, has, enum, test, glob, impl, type)
#
# NOTE: jac.spec hoists the obj/node/.../def/can dispatch keyword out of the
# `archetype`/`ability` rules (an extraction artifact). The real .jac surface
# carries the keyword in the declaration, so it is re-added here.
# ===========================================================================

def build_decls(g: Grammar) -> None {
    rule(g, "decorator_list", rep1(seq(lit("@"), sym("expression"))));
    rule(g, "type_annotation", sym("expression"));
    rule(g, "param", seq(
        opt(choice(lit("*"), lit("**"))),
        choice(name_ref(), sym("special_ref")),
        opt(seq(lit(":"), sym("type_annotation"))),
        opt(seq(lit("="), sym("expression")))
    ));
    rule(g, "parameter_list", seq(
        lit("("), comma_sep(choice(lit("*"), lit("/"), sym("param"))), opt(lit(",")), lit(")")
    ));
    rule(g, "func_signature", choice(
        seq(sym("parameter_list"), opt(seq(lit("->"), field("return_type", sym("type_annotation"))))),
        seq(lit("->"), field("return_type", sym("type_annotation")))
    ));

    rule(g, "archetype", seq(
        decorators(),
        opt(lit("async")),
        field("kind", choice(lit("obj"), lit("node"), lit("edge"), lit("walker"), lit("class"))),
        access_tag(),
        field("name", name_ref()),
        opt(sym("type_params")),
        opt(seq(lit("("), opt(comma_sep1(sym("expression"))), lit(")"))),
        choice(seq(lit("{"), rep(sym("archetype_member")), lit("}")), lit(";"))
    ));
    rule(g, "archetype_member", choice(
        sym("has_statement"),
        sym("ability"),
        sym("archetype"),
        sym("enum"),
        sym("impl"),
        sym("with_entry"),
        seq(sym("string"), opt(lit(";")))
    ));
    rule(g, "with_entry", seq(
        lit("with"), opt(choice(lit("entry"), lit("exit"))), block()
    ));

    rule(g, "ability", seq(
        decorators(),
        opt(lit("override")),
        opt(lit("static")),
        opt(lit("async")),
        field("kind", choice(lit("def"), lit("can"))),
        access_tag(),
        opt(field("name", name_ref())),
        opt(sym("type_params")),
        opt(choice(sym("event_clause"), sym("func_signature"))),
        choice(block(), seq(opt(lit("abs")), lit(";")), seq(lit("by"), sym("expression"), lit(";")))
    ));
    # Ability event signature: `with <NodeType> entry|exit` (object-spatial
    # dispatch), e.g. `can create with Root entry { ... }`. The trailing
    # entry/exit keyword can't be part of the expression, so it is consumed
    # explicitly after it.
    rule(g, "event_clause", seq(
        lit("with"), sym("expression"), opt(choice(lit("entry"), lit("exit")))
    ));

    rule(g, "has_statement", seq(
        opt(lit("static")), lit("has"), access_tag(),
        comma_sep1(sym("has_var")), lit(";")
    ));
    rule(g, "has_var", seq(
        field("name", name_ref()), lit(":"), field("type", sym("type_annotation")),
        opt(choice(seq(lit("="), sym("expression")), seq(lit("by"), lit("postinit"))))
    ));

    rule(g, "enum", seq(
        decorators(), lit("enum"), access_tag(), field("name", name_ref()),
        opt(seq(lit(":"), sym("expression"))),
        choice(
            seq(lit("{"), comma_sep(sym("enum_member")), opt(lit(",")), lit("}")),
            lit(";")
        )
    ));
    rule(g, "enum_member", seq(name_ref(), opt(seq(lit("="), sym("expression")))));

    rule(g, "test", seq(
        decorators(), lit("test"), opt(sym("string")), block()
    ));

    rule(g, "global_var", seq(
        lit("glob"), access_tag(),
        comma_sep1(seq(
            field("name", name_ref()),
            opt(seq(lit(":"), sym("type_annotation"))),
            opt(rep1(seq(lit("="), sym("expression"))))
        )),
        lit(";")
    ));

    # The impl target is a dotted name PATH (`Class.method`, `Walker.entry`,
    # `Obj.init`), NOT a general expression -- using `expression` made
    # `impl X.f(params)` greedily parse as a call_expression, so the func
    # signature's `(` collided and every signature-bearing impl failed.
    rule(g, "impl", seq(
        decorators(), lit("impl"),
        field("target", sym("impl_target")),
        opt(choice(seq(lit("with"), sym("expression")), sym("func_signature"))),
        choice(block(), seq(lit("by"), sym("expression"), lit(";")), lit(";"))
    ));
    rule(g, "impl_target", precl(1, seq(
        sym("impl_target_name"),
        rep(seq(lit("."), sym("impl_target_name")))
    )));
    # impl_target_name (jac.spec): NAME/KWESC plus a few contextual keywords
    # that name abilities/ctors. Keyword extraction (word: identifier) keeps
    # these usable as ordinary identifiers elsewhere.
    rule(g, "impl_target_name", choice(
        name_ref(),
        lit("init"), lit("postinit"), lit("entry"), lit("exit"), lit("default")
    ));

    rule(g, "type_alias", seq(
        lit("type"), access_tag(), field("name", name_ref()),
        opt(sym("type_params")), lit("="), sym("type_annotation"), lit(";")
    ));
    rule(g, "type_params", seq(
        lit("["),
        comma_sep1(seq(name_ref(), opt(seq(lit(":"), sym("expression"))),
                       opt(seq(lit("="), sym("expression"))))),
        lit("]")
    ));

    rule(g, "sem_def", precr(1, seq(
        lit("sem"), sym("impl_target"), choice(lit("="), lit("is")), rep(sym("string")), opt(lit(";"))
    )));
}

# ===========================================================================
# Imports & module structure
# ===========================================================================

def build_imports(g: Grammar) -> None {
    # prec.right so the optional trailing `;` after the `{ ... }` items form is
    # shifted into THIS statement rather than left dangling (a benign
    # shift/reduce on the optional terminator).
    rule(g, "import_statement", precr(1, seq(
        choice(lit("import"), lit("include")),
        opt(lit("type")),
        opt(seq(lit("from"), sym("import_path"))),
        choice(
            # The `{ ... }` items form ends in a block, so (like every other
            # block-bodied construct in Jac) it self-terminates and the trailing
            # `;` is optional -- real Jac omits it after `import from x { ... }`.
            seq(sym("import_items"), opt(lit(";"))),
            seq(sym("import_path"), opt(seq(lit("as"), name_ref())), lit(";"))
        )
    )));
    # precl(2) so extending the path (`a` + `.b`) binds TIGHTER than reducing
    # the enclosing `import_path` relative branch (precr 1) -- otherwise a
    # `...pkg.sub` path reduces after the first segment and orphans `.sub`.
    rule(g, "dotted_name", choice(
        name_ref(),
        precl(2, seq(sym("dotted_name"), lit("."), name_ref()))
    ));
    # Leading relative-import dots: `.`, `..`, `...` (and longer runs).
    # Explicit left-recursion + prec.left resolves the dot shift/reduce without
    # a GLR dynamic conflict. The dots only ever precede the path (never follow
    # a NAME), so they never clash with `dotted_name`'s own `.` separators.
    rule(g, "relative_prefix", choice(
        choice(lit("."), lit("...")),
        precl(1, seq(sym("relative_prefix"), choice(lit("."), lit("..."))))
    ));
    rule(g, "import_path", choice(
        sym("string"),
        sym("dotted_name"),
        precr(1, seq(sym("relative_prefix"), opt(choice(sym("string"), sym("dotted_name")))))
    ));
    rule(g, "import_items", seq(
        lit("{"),
        comma_sep1(seq(choice(lit("*"), name_ref()), opt(seq(lit("as"), name_ref())))),
        opt(lit(",")), lit("}")
    ));

    rule(g, "module_code", seq(
        lit("with"), opt(choice(lit("entry"), lit("exit"))),
        opt(seq(lit(":"), name_ref())), block()
    ));
    rule(g, "context_block", seq(
        field("context", choice(lit("cl"), lit("sv"), lit("na"))),
        choice(seq(lit("{"), rep(sym("element")), lit("}")), sym("element"))
    ));

    rule(g, "element", choice(
        sym("import_statement"),
        sym("archetype"),
        sym("ability"),
        sym("enum"),
        sym("test"),
        sym("global_var"),
        sym("impl"),
        sym("sem_def"),
        sym("type_alias"),
        sym("module_code"),
        sym("context_block"),
        sym("pyinline"),
        sym("string"),
        lit(";")
    ));
}

def build -> Grammar {
    g = Grammar(name="jac");
    rule(g, "source_file", rep(sym("element")));
    build_imports(g);
    build_decls(g);
    build_stmts(g);
    build_patterns(g);
    build_expr(g);
    build_collections(g);
    build_edges(g);
    build_tokens(g);
    return g;
}

with entry {
    g = build();
    out = {
        "name": g.name,
        "word": "identifier",
        "extras": [pat("\\s").emit(), sym("comment").emit()],
        "conflicts": [
            ["param"],
            ["capture_pattern", "class_pattern"],
            # Comprehension element vs. for-clause target: in `[<e> for <t> in ...]`
            # both `<e>` and the comma-separated `<t>` are expression-like, so
            # GLR must keep both interpretations until the `for`/`in` resolves it.
            ["expression", "for_in_clause"]
        ],
        "externals": [],
        "inline": [],
        "supertypes": [],
        "rules": g.rules_json()
    };
    here = os.path.dirname(os.path.abspath(__file__));
    dest = os.path.join(here, "src", "grammar.json");
    f = open(dest, "w");
    f.write(json.dumps(out, indent=2));
    f.write("\n");
    f.close();
    print(f"wrote {dest}");
}
