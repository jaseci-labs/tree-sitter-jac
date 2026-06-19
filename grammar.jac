"""Tree-sitter grammar for the Jac programming language, authored in Jac OSP.

The grammar is built as an **object-spatial graph**: every tree-sitter rule
construct is a pure-data `node`, structure is expressed with ordered child
edges, and an `Emit` **walker** traverses the graph to serialize it to
`src/grammar.json`, which `tree-sitter generate` consumes to produce
`src/parser.c`.

Why OSP fits: a tree-sitter grammar is an ordered, nested (and, via rule
references, cyclic) structure -- exactly the shape object-spatial graphs model
well, now that out-edge ordering is a guaranteed OSP semantic (connection
order; jaseci-labs/jaseci#6785). A rule body is built top-down -- create a node,
then descend into its children: `(p ++> Seq())[0] ++> [A, B, C]` connects three
child edges in order, and `[here -->]` reads them back in that same order. Serialization is a
genuine walker traversal: `Emit` descends on `entry` and builds each node's
`out` on `exit` -- which fires only after all descendants, i.e. post-order --
so the nodes stay pure data and the algorithm travels to the graph.

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

# The node types are PURE DATA: structural children hang off ordered out-edges
# (`++>`), scalar data lives in `has` fields, and the serialized grammar.json is
# written onto `out` by the `Emit` walker (below). Keeping the algorithm out of
# the nodes is what makes this object-spatial: a walker carries the computation
# to the data graph, rather than each node serializing itself.

"""Base type for every grammar construct; the `Emit` walker fills `out`."""
node GNode {
    has out: dict = {};
}

# NOTE: the scalar fields below carry defaults only to satisfy dataclass field
# ordering (the inherited `out` has a default); construction always supplies
# them explicitly.

"""A literal string token (an anonymous terminal), e.g. "obj"."""
node Lit(GNode) { has value: str = ""; }

"""A regular-expression token."""
node Pat(GNode) { has value: str = ""; }

"""A reference to another rule by name (the $.<name> of grammar.js)."""
node Sym(GNode) { has name: str = ""; }

"""The empty match."""
node Blank(GNode) {}

"""Ordered sequence: A B C (children are the ordered members)."""
node Seq(GNode) {}

"""Alternatives: A | B | C (children are the ordered members)."""
node Choice(GNode) {}

"""Zero or more: A* (one child)."""
node Rep(GNode) {}

"""One or more: A+ (one child)."""
node Rep1(GNode) {}

"""Lexer-level token: treat the contained subrule as a single terminal."""
node Tok(GNode) {}

"""Token that must immediately follow the previous one (no extras between)."""
node ITok(GNode) {}

"""Attach a field name to a child (for queries / tree navigation)."""
node Field(GNode) { has name: str = ""; }

"""Rename a node in the output tree."""
node Alias(GNode) { has name: str = "", named: bool = True; }

"""Precedence wrapper. `kind` selects PREC / PREC_LEFT / PREC_RIGHT / PREC_DYNAMIC."""
node Prec(GNode) { has kind: str = "", level: int = 0; }

# ===========================================================================
# Emit walker -- the serializer
#
# `Emit` folds a grammar subgraph into its grammar.json dict. It descends on
# `entry` (`visit [-->]`, one ability that matches every GNode polymorphically)
# and builds each node's `out` on `exit`. Because a node's `exit` fires only
# after all of its descendants have exited, this is a post-order pass: when a
# parent runs, its children's `out` are already populated, so it just folds
# them in. `emit(n)` dispatches the walker and reads the result back.
# ===========================================================================
walker Emit {
    can descend     with GNode  entry { visit [-->]; }

    can emit_lit    with Lit    exit { here.out = {"type": "STRING", "value": here.value}; }
    can emit_pat    with Pat    exit { here.out = {"type": "PATTERN", "value": here.value}; }
    can emit_sym    with Sym    exit { here.out = {"type": "SYMBOL", "name": here.name}; }
    can emit_blank  with Blank  exit { here.out = {"type": "BLANK"}; }
    can emit_seq    with Seq    exit { here.out = {"type": "SEQ", "members": [k.out for k in [here -->]]}; }
    can emit_choice with Choice exit { here.out = {"type": "CHOICE", "members": [k.out for k in [here -->]]}; }
    can emit_rep    with Rep    exit { here.out = {"type": "REPEAT", "content": [here -->][0].out}; }
    can emit_rep1   with Rep1   exit { here.out = {"type": "REPEAT1", "content": [here -->][0].out}; }
    can emit_tok    with Tok    exit { here.out = {"type": "TOKEN", "content": [here -->][0].out}; }
    can emit_itok   with ITok   exit { here.out = {"type": "IMMEDIATE_TOKEN", "content": [here -->][0].out}; }
    can emit_field  with Field  exit {
        here.out = {"type": "FIELD", "name": here.name, "content": [here -->][0].out};
    }
    can emit_alias  with Alias  exit {
        here.out = {"type": "ALIAS", "value": here.name, "named": here.named, "content": [here -->][0].out};
    }
    can emit_prec   with Prec   exit {
        here.out = {"type": here.kind, "value": here.level, "content": [here -->][0].out};
    }
}

"""Serialize a grammar subgraph to its grammar.json dict by walking it."""
def emit(n: GNode) -> dict { n spawn Emit(); return n.out; }

# ===========================================================================
# Leaf constructors & shared fragments
#
# Rules are built TOP-DOWN: create the parent node, then connect its children in
# order. `++>` returns its TARGETS (not the source), so `(parent ++> Child())[0]`
# reads as "connect a fresh child and hand it back" -- the connect-and-descend
# that lets construction walk from the root downward. A run of leaf/ref children
# connects in one fan-out: `parent ++> [a, b, c]`. The leaf constructors below
# mint childless nodes (a literal, a regex, a rule reference, the empty match);
# `comma_sep*` are the only multi-use composite fragments kept as helpers,
# because they appear at ~30 sites.
# ===========================================================================

def lit(value: str) -> GNode { return Lit(value=value); }

def pat(value: str) -> GNode { return Pat(value=value); }

def sym(name: str) -> GNode { return Sym(name=name); }

def blank() -> GNode { return Blank(); }

"""Comma-separated list of one or more `r` (no trailing comma): `r ("," r)*`.
The SAME `r` node is connected under both the outer and the inner sequence (a
shared child), so it serializes by value in each place it appears."""
def comma_sep1(r: GNode) -> GNode {
    outer = Seq();
    outer ++> r;                       # member 1: r
    more  = (outer ++> Rep())[0];      # member 2: a Rep -- descend into it
    inner = (more  ++> Seq())[0];      # Rep's content: a Seq -- descend into it
    inner ++> [lit(","), r];           # that Seq's members: "," then r
    return outer;
}

"""Comma-separated list of zero or more `r`."""
def comma_sep(r: GNode) -> GNode {
    cs = Choice();
    cs ++> [comma_sep1(r), blank()];
    return cs;
}

# ===========================================================================
# Grammar assembly
#
# A `Rule` is a named node with exactly one child (its body). The `Grammar`
# root connects to its rules in order -- and order matters: tree-sitter treats
# the FIRST rule as the start symbol, so ordered edges carry meaning even here.
# ===========================================================================

node Rule {
    has name: str;
    def body_json -> dict { return emit([self -->][0]); }
}

node Grammar {
    has name: str;
    def rules_json -> dict { return {r.name: r.body_json() for r in [self -->]}; }
}

"""Create a named rule attached to the grammar and return it. The body is built
top-down by descending into the returned Rule: `(rule(g, name) ++> Body())[0]`,
or `rule(g, name) ++> leaf` for a single-leaf body."""
def rule(g: Grammar, name: str) -> Rule {
    r = Rule(name=name);
    g ++> r;
    return r;
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
    at = Choice();
    colon = (at ++> Seq())[0];          # member 1: the ":" ...? sequence
    at ++> blank();                     # member 2: empty
    colon ++> lit(":");
    vis_opt = (colon ++> Choice())[0];  # optional visibility keyword
    vis = (vis_opt ++> Choice())[0];
    vis_opt ++> blank();
    vis ++> [lit("pub"), lit("priv"), lit("protect")];
    return at;
}

"""Decorators `(@expr)*`. References the SHARED `decorator_list` rule (rep1,
defined in build_decls) wrapped in opt, so the decorator-prefix states are
built once rather than duplicated across every decl that can carry them."""
def decorators() -> GNode {
    d = Choice();
    d ++> [sym("decorator_list"), blank()];
    return d;
}

"""A `{ ... }` code block. References the SHARED `block_body` rule (defined in
build_stmts) so tree-sitter builds the statement-list state machine ONCE,
instead of duplicating it at every block site (which exploded the parse
table). `block_body` is rep1 (non-empty); the inner opt handles the empty `{}`."""
def block() -> GNode {
    b = Seq();
    b ++> lit("{");
    bb = (b ++> Choice())[0];           # optional block_body
    b ++> lit("}");
    bb ++> [sym("block_body"), blank()];
    return b;
}

# ===========================================================================
# Tokens
# ===========================================================================

def build_tokens(g: Grammar) -> None {
    (rule(g, "identifier") ++> Tok())[0] ++> pat("[a-zA-Z_][a-zA-Z0-9_]*");
    (rule(g, "kwesc_name") ++> Tok())[0] ++> pat("`[a-zA-Z_][a-zA-Z0-9_]*");
    (rule(g, "_name_ref") ++> Choice())[0] ++> [sym("identifier"), sym("kwesc_name")];
    int_t = (rule(g, "integer") ++> Tok())[0];
    (int_t ++> Choice())[0] ++> [
        pat("0[xX][0-9a-fA-F_]+"),
        pat("0[bB][01_]+"),
        pat("0[oO][0-7_]+"),
        pat("[0-9][0-9_]*")
    ];
    flt_t = (rule(g, "float") ++> Tok())[0];
    (flt_t ++> Choice())[0] ++> [
        pat("[0-9][0-9_]*\\.[0-9_]*([eE][-+]?[0-9_]+)?"),
        pat("\\.[0-9][0-9_]*([eE][-+]?[0-9_]+)?"),
        pat("[0-9][0-9_]*[eE][-+]?[0-9_]+")
    ];
    # NOTE: f-strings and JSX text need an external C scanner for full fidelity
    # (interpolation / context-sensitive lexing). v0.1 treats strings -- incl.
    # f/r/b-prefixed -- as opaque tokens; interpolated exprs are not yet split
    # out. Tracked as the external-scanner follow-up.
    # Non-f strings only; f-strings (prefix containing f/F) are tokenized by the
    # external scanner into start/content/interpolation/end (see `fstring`).
    str_seq = ((rule(g, "string") ++> Tok())[0] ++> Seq())[0];
    (str_seq ++> Choice())[0] ++> [pat("[rRbB]+"), blank()];
    (str_seq ++> Choice())[0] ++> [
        pat("\"\"\"([^\"]|\"[^\"]|\"\"[^\"])*\"\"\""),
        pat("'''([^']|'[^']|''[^'])*'''"),
        pat("\"([^\"\\\\\\n]|\\\\.)*\""),
        pat("'([^'\\\\\\n]|\\\\.)*'")
    ];
    (rule(g, "bool") ++> Choice())[0] ++> [lit("True"), lit("False")];
    rule(g, "null") ++> lit("None");
    rule(g, "ellipsis") ++> lit("...");
    (rule(g, "comment") ++> Tok())[0] ++> pat("#.*");
    # `pyinline` (jac.spec PYNLINE) is a whole `::py:: ... ::py::` block. Its
    # body is arbitrary Python that the context-free grammar can't delimit, so
    # it is provided by the external scanner (src/scanner.c) and declared in
    # `externals` below -- no rule here.
    bt = [lit(t) for t in [
        "str", "int", "float", "list", "tuple", "set", "dict", "bool", "bytes",
        "any", "type", "i8", "u8", "i16", "u16", "i32", "u32", "i64", "u64",
        "f32", "f64"
    ]];
    (rule(g, "builtin_type") ++> Choice())[0] ++> bt;
    sr = [lit(s) for s in [
        "self", "super", "here", "root", "visitor", "props", "init", "postinit"
    ]];
    (rule(g, "special_ref") ++> Choice())[0] ++> sr;
}

# ===========================================================================
# Expressions
#
# The jac.spec precedence cascade is realized the idiomatic tree-sitter way:
# one `expression` supertype and a `binary_expression` whose alternatives carry
# `prec` levels read straight off the spec's ordering (higher binds tighter).
# ===========================================================================

def build_expr(g: Grammar) -> None {
    expr = (rule(g, "expression") ++> Choice())[0];
    expr ++> [
        sym("binary_expression"),
        sym("unary_expression"),
        sym("ternary_expression"),
        sym("lambda_expression"),
        sym("connect_expression"),
        sym("concurrent_expression"),
        sym("_primary_expression")
    ];

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
    alts: list[GNode] = [];
    for op in binops {
        be_p = Prec(kind="PREC_LEFT", level=op[1]);
        be_s = (be_p ++> Seq())[0];
        (be_s ++> Field(name="left"))[0] ++> sym("expression");
        (be_s ++> Field(name="operator"))[0] ++> lit(op[0]);
        (be_s ++> Field(name="right"))[0] ++> sym("expression");
        alts.append(be_p);
    }
    # multi-word comparison operators
    for words in [["not", "in"], ["is", "not"]] {
        bw_p = Prec(kind="PREC_LEFT", level=11);
        bw_s = (bw_p ++> Seq())[0];
        (bw_s ++> Field(name="left"))[0] ++> sym("expression");
        ((bw_s ++> Field(name="operator"))[0] ++> Seq())[0] ++> [lit(words[0]), lit(words[1])];
        (bw_s ++> Field(name="right"))[0] ++> sym("expression");
        alts.append(bw_p);
    }
    # right-associative: ** and walrus
    bpow = Prec(kind="PREC_RIGHT", level=18);
    bpow_s = (bpow ++> Seq())[0];
    (bpow_s ++> Field(name="left"))[0] ++> sym("expression");
    (bpow_s ++> Field(name="operator"))[0] ++> lit("**");
    (bpow_s ++> Field(name="right"))[0] ++> sym("expression");
    alts.append(bpow);
    bwal = Prec(kind="PREC_RIGHT", level=3);
    bwal_s = (bwal ++> Seq())[0];
    (bwal_s ++> Field(name="left"))[0] ++> sym("expression");
    (bwal_s ++> Field(name="operator"))[0] ++> lit(":=");
    (bwal_s ++> Field(name="right"))[0] ++> sym("expression");
    alts.append(bwal);
    be = (rule(g, "binary_expression") ++> Choice())[0];
    be ++> alts;

    # Prefix operators. `|>` / `:>` are the prefix pipe-call forms
    # (jac.spec `pipe_call`), e.g. `x = :> uuid4()` -- distinct from their
    # binary (atomic-)pipe roles, disambiguated by the absence of a left operand.
    # NOTE: `**` is intentionally NOT a general prefix operator -- it only ever
    # appears as dict-spread (`{**x}`), call kwargs (`f(**x)`), or a `**param`,
    # each handled by its own rule. Treating it as a unary made `{**x}` match a
    # set element, so `{**base, "k": v}` mis-parsed as a set and broke at `:`.
    uops = [lit(u) for u in ["not", "~", "-", "+", "*", "&", "|>", ":>"]];
    ue = (rule(g, "unary_expression") ++> Prec(kind="PREC_RIGHT", level=19))[0];
    ue_s = (ue ++> Seq())[0];
    ((ue_s ++> Field(name="operator"))[0] ++> Choice())[0] ++> uops;
    (ue_s ++> Field(name="operand"))[0] ++> sym("expression");

    te = (rule(g, "ternary_expression") ++> Prec(kind="PREC_RIGHT", level=1))[0];
    te_s = (te ++> Seq())[0];
    (te_s ++> Field(name="consequence"))[0] ++> sym("expression");
    te_s ++> lit("if");
    (te_s ++> Field(name="condition"))[0] ++> sym("expression");
    te_s ++> lit("else");
    (te_s ++> Field(name="alternative"))[0] ++> sym("expression");

    # flow/wait prefix and await/spawn/ref/unpack prefixes
    conc = (rule(g, "concurrent_expression") ++> Prec(kind="PREC", level=2))[0];
    conc_s = (conc ++> Seq())[0];
    (conc_s ++> Choice())[0] ++> [lit("flow"), lit("wait")];
    conc_s ++> sym("expression");

    # Lower precedence than ternary so the body greedily absorbs a trailing
    # `if/else` (`lambda: a if b else c` -> body is `(a if b else c)`).
    # jac.spec: `("(" func_params ")" | lambda_params)` -- params may be
    # parenthesized (`lambda (x: int) -> int { ... }`) or bare
    # (`lambda x: int : expr`).
    le = (rule(g, "lambda_expression") ++> Prec(kind="PREC_RIGHT", level=-1))[0];
    le_s = (le ++> Seq())[0];
    le_s ++> lit("lambda");
    le_params_opt = (le_s ++> Choice())[0];
    le_ret_opt = (le_s ++> Choice())[0];
    le_body = (le_s ++> Choice())[0];
    (le_params_opt ++> Choice())[0] ++> [sym("parameter_list"), sym("lambda_params")];
    le_params_opt ++> blank();
    (le_ret_opt ++> Seq())[0] ++> [lit("->"), sym("expression")];
    le_ret_opt ++> blank();
    (le_body ++> Seq())[0] ++> [lit(":"), sym("expression")];
    le_body ++> block();
    rule(g, "lambda_params") ++> comma_sep1(sym("param"));

    # ---- primary / atoms -------------------------------------------------
    prim = (rule(g, "_primary_expression") ++> Choice())[0];
    prim ++> [
        sym("_atom"),
        sym("call_expression"),
        sym("index_expression"),
        sym("attribute_expression"),
        sym("filter_expression"),
        sym("await_expression"),
        sym("spawn_expression"),
        sym("edge_reference")
    ];

    # Object-spatial filter comprehension applied to a primary:
    # `nodes(?score > 5)` / `[-->][?:NodeType, val == 1]` (jac.spec
    # filter_compr_inner / filter_compr_bracket).
    fe = (rule(g, "filter_expression") ++> Prec(kind="PREC_LEFT", level=28))[0];
    fe_s = (fe ++> Seq())[0];
    (fe_s ++> Field(name="object"))[0] ++> sym("_primary_expression");
    fe_alt = (fe_s ++> Choice())[0];
    (fe_alt ++> Seq())[0] ++> [lit("("), sym("filter_compr"), lit(")")];
    (fe_alt ++> Seq())[0] ++> [lit("["), sym("filter_compr"), lit("]")];

    fc = (rule(g, "filter_compr") ++> Seq())[0];
    fc ++> lit("?");
    fc_type_opt = (fc ++> Choice())[0];
    fc_comma_opt = (fc ++> Choice())[0];
    fc_cs_opt = (fc ++> Choice())[0];
    (fc_type_opt ++> Seq())[0] ++> [lit(":"), sym("expression")];
    fc_type_opt ++> blank();
    fc_comma_opt ++> [lit(","), blank()];
    fc_cs_opt ++> [comma_sep1(sym("expression")), blank()];

    atom = (rule(g, "_atom") ++> Choice())[0];
    atom ++> [
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
        sym("comprehension"),
        sym("jsx_element"),
        sym("fstring")
    ];

    # Implicit concatenation of adjacent string literals, which may mix plain
    # strings and f-strings (jac.spec multistring).
    mstr = (rule(g, "multistring") ++> Prec(kind="PREC", level=2))[0];
    mstr_s = (mstr ++> Seq())[0];
    (mstr_s ++> Choice())[0] ++> [sym("string"), sym("fstring")];
    ((mstr_s ++> Rep1())[0] ++> Choice())[0] ++> [sym("string"), sym("fstring")];

    # f-strings: the start/content/end tokens come from the external scanner
    # (src/scanner.c); the grammar parses the embedded `{ expression }`
    # interpolations (with optional `!r`/`!s`/`!a` conversion and `:` format).
    fstr = (rule(g, "fstring") ++> Seq())[0];
    fstr ++> sym("fstring_start");
    ((fstr ++> Rep())[0] ++> Choice())[0] ++> [sym("fstring_content"), sym("fstring_interpolation")];
    fstr ++> sym("fstring_end");

    fi = (rule(g, "fstring_interpolation") ++> Seq())[0];
    fi ++> lit("{");
    (fi ++> Field(name="expression"))[0] ++> sym("expression");
    (fi ++> Choice())[0] ++> [sym("fstring_conversion"), blank()];
    (fi ++> Choice())[0] ++> [sym("fstring_format"), blank()];
    fi ++> lit("}");

    fcv = (rule(g, "fstring_conversion") ++> Tok())[0];
    fcv_s = (fcv ++> Seq())[0];
    fcv_s ++> lit("!");
    (fcv_s ++> Choice())[0] ++> [lit("r"), lit("s"), lit("a")];

    ff = (rule(g, "fstring_format") ++> Seq())[0];
    ff ++> lit(":");
    ((ff ++> Rep())[0] ++> Choice())[0] ++> [sym("fstring_content"), sym("fstring_interpolation")];

    pe = (rule(g, "parenthesized_expression") ++> Seq())[0];
    pe ++> lit("(");
    pe_inner_opt = (pe ++> Choice())[0];
    pe ++> lit(")");
    pe_inner = (pe_inner_opt ++> Choice())[0];
    pe_inner_opt ++> blank();
    (pe_inner ++> Seq())[0] ++> [sym("expression"), sym("comprehension_clauses")];   # `(x for x in xs if cond)`
    pe_tuple = (pe_inner ++> Seq())[0];
    pe_tuple ++> comma_sep1(sym("expression"));
    (pe_tuple ++> Choice())[0] ++> [lit(","), blank()];

    ae = (rule(g, "attribute_expression") ++> Prec(kind="PREC_LEFT", level=28))[0];
    ae_s = (ae ++> Seq())[0];
    (ae_s ++> Field(name="object"))[0] ++> sym("_primary_expression");
    (ae_s ++> Choice())[0] ++> [lit("."), lit(".>"), lit("<."), lit("?.")];
    (ae_s ++> Field(name="attr"))[0] ++> name_ref();

    call = (rule(g, "call_expression") ++> Prec(kind="PREC_LEFT", level=28))[0];
    call_s = (call ++> Seq())[0];
    (call_s ++> Field(name="function"))[0] ++> sym("_primary_expression");
    call_s ++> sym("argument_list");

    al = (rule(g, "argument_list") ++> Seq())[0];
    al ++> lit("(");
    al_cs_opt = (al ++> Choice())[0];
    al_trail = (al ++> Choice())[0];
    al ++> lit(")");
    al_cs_opt ++> [comma_sep1(sym("argument")), blank()];
    al_trail ++> [lit(","), blank()];

    arg = (rule(g, "argument") ++> Choice())[0];
    arg_kw = (arg ++> Seq())[0];
    (arg ++> Seq())[0] ++> [lit("**"), sym("expression")];
    (arg ++> Seq())[0] ++> [lit("*"), sym("expression")];
    arg_bare = (arg ++> Seq())[0];
    (arg_kw ++> Field(name="name"))[0] ++> name_ref();
    arg_kw ++> [lit("="), sym("expression")];
    arg_bare ++> sym("expression");
    # bare expression, optionally a generator expression `f(x for x in y)`
    (arg_bare ++> Choice())[0] ++> [sym("comprehension_clauses"), blank()];

    ie = (rule(g, "index_expression") ++> Prec(kind="PREC_LEFT", level=28))[0];
    ie_s = (ie ++> Seq())[0];
    (ie_s ++> Field(name="object"))[0] ++> sym("_primary_expression");
    (ie_s ++> Choice())[0] ++> [lit("?"), blank()];
    ie_s ++> [lit("["), sym("slice"), lit("]")];

    sl = (rule(g, "slice") ++> Choice())[0];
    sl_full = (sl ++> Seq())[0];
    sl ++> comma_sep1(sym("expression"));
    (sl_full ++> Choice())[0] ++> [sym("expression"), blank()];
    sl_full ++> lit(":");
    (sl_full ++> Choice())[0] ++> [sym("expression"), blank()];
    sl_step_opt = (sl_full ++> Choice())[0];
    sl_step = (sl_step_opt ++> Seq())[0];
    sl_step_opt ++> blank();
    sl_step ++> lit(":");
    (sl_step ++> Choice())[0] ++> [sym("expression"), blank()];

    awa = (rule(g, "await_expression") ++> Prec(kind="PREC", level=26))[0];
    awa_s = (awa ++> Seq())[0];
    awa_s ++> [lit("await"), sym("expression")];

    spw = (rule(g, "spawn_expression") ++> Prec(kind="PREC_LEFT", level=23))[0];
    spw_s = (spw ++> Seq())[0];
    spw_s ++> [sym("expression"), lit("spawn"), sym("expression")];
}

# ===========================================================================
# Collections & comprehensions
# ===========================================================================

def build_collections(g: Grammar) -> None {
    # list ::= "[" opt(comma_sep1(expr)) opt(",") "]"
    li = (rule(g, "list") ++> Seq())[0];
    li ++> lit("[");
    li_items = (li ++> Choice())[0];
    li_trail = (li ++> Choice())[0];
    li ++> lit("]");
    li_items ++> [comma_sep1(sym("expression")), blank()];
    li_trail ++> [lit(","), blank()];

    # set ::= "{" comma_sep1(expr) opt(",") "}"
    se = (rule(g, "set") ++> Seq())[0];
    se ++> [lit("{"), comma_sep1(sym("expression"))];
    se_trail = (se ++> Choice())[0];
    se ++> lit("}");
    se_trail ++> [lit(","), blank()];

    # dict ::= "{" opt(comma_sep1(dict_entry)) opt(",") "}"
    di = (rule(g, "dict") ++> Seq())[0];
    di ++> lit("{");
    di_items = (di ++> Choice())[0];
    di_trail = (di ++> Choice())[0];
    di ++> lit("}");
    di_items ++> [comma_sep1(sym("dict_entry")), blank()];
    di_trail ++> [lit(","), blank()];

    # dict_entry ::= "**" expr | key=expr ":" value=expr
    de = (rule(g, "dict_entry") ++> Choice())[0];
    (de ++> Seq())[0] ++> [lit("**"), sym("expression")];
    de_kv = (de ++> Seq())[0];
    (de_kv ++> Field(name="key"))[0] ++> sym("expression");
    de_kv ++> lit(":");
    (de_kv ++> Field(name="value"))[0] ++> sym("expression");

    # comprehension ::= list_comprehension | dict_comprehension | set_comprehension
    (rule(g, "comprehension") ++> Choice())[0] ++> [sym("list_comprehension"), sym("dict_comprehension"), sym("set_comprehension")];

    # list_comprehension ::= "[" expr comprehension_clauses "]"
    (rule(g, "list_comprehension") ++> Seq())[0] ++> [lit("["), sym("expression"), sym("comprehension_clauses"), lit("]")];

    # set_comprehension ::= "{" expr comprehension_clauses "}"
    (rule(g, "set_comprehension") ++> Seq())[0] ++> [lit("{"), sym("expression"), sym("comprehension_clauses"), lit("}")];

    # dict_comprehension ::= "{" expr ":" expr comprehension_clauses "}"
    (rule(g, "dict_comprehension") ++> Seq())[0] ++> [lit("{"), sym("expression"), lit(":"), sym("expression"), sym("comprehension_clauses"), lit("}")];

    # jac.spec: comprehension_clauses ::= compr_clause+ where each clause is a
    # `for X in Y` followed by zero+ trailing `if`s. Clauses INTERLEAVE
    # (`for a in b if c for d in e`), so this is rep1 of (for + ifs), not "all
    # fors then all ifs".
    cc = (rule(g, "comprehension_clauses") ++> Rep1())[0];
    cc_clause = (cc ++> Seq())[0];
    cc_clause ++> sym("for_in_clause");
    (cc_clause ++> Rep())[0] ++> sym("if_clause");

    # The target is a primary-expression list (jac.spec uses `atomic_chain`),
    # NOT a full expression -- a full expression would swallow the `in`
    # separator as a binary `in` comparison (`for (i in y)`). Comma-separated to
    # allow tuple targets `for k, v in ...`.
    # prec 2 (> ternary's 1) so a trailing `if` reduces the iterable and
    # attaches as a comprehension filter instead of starting an (else-less)
    # ternary on the iterable.
    fic_s = ((rule(g, "for_in_clause") ++> Prec(kind="PREC_RIGHT", level=2))[0] ++> Seq())[0];
    (fic_s ++> Choice())[0] ++> [lit("async"), blank()];
    fic_s ++> lit("for");
    (fic_s ++> Field(name="left"))[0] ++> comma_sep1(sym("_primary_expression"));
    fic_s ++> lit("in");
    (fic_s ++> Field(name="right"))[0] ++> sym("expression");

    # if_clause ::= "if" expr
    (rule(g, "if_clause") ++> Seq())[0] ++> [lit("if"), sym("expression")];
}

# ===========================================================================
# Graph / object-spatial operators
# ===========================================================================

# ===========================================================================
# JSX / view bodies (.cl.jac client UIs)
# ===========================================================================
#
# A `jsx_element` is an atom, so the opening `<` is unambiguous: at an atom
# position only JSX can start with `<`, whereas the binary `<` operator only
# appears in infix position (a disjoint parser state). The only token the CFG
# cannot express is the raw inter-tag text, supplied by the external scanner as
# `jsx_text` (src/scanner.c).
def build_jsx(g: Grammar) -> None {
    # jsx_element ::= "<" ( fragment | named )
    je = (rule(g, "jsx_element") ++> Seq())[0];
    je ++> lit("<");
    je_body = (je ++> Choice())[0];
    # fragment:  <> children </>
    je_frag = (je_body ++> Seq())[0];
    je_frag ++> lit(">");
    (je_frag ++> Rep())[0] ++> sym("jsx_child");
    je_frag ++> [lit("<"), lit("/"), lit(">")];
    # named element
    je_named = (je_body ++> Seq())[0];
    (je_named ++> Field(name="name"))[0] ++> sym("jsx_name");
    (je_named ++> Rep())[0] ++> sym("jsx_attribute");
    je_close = (je_named ++> Choice())[0];
    (je_close ++> Seq())[0] ++> [lit("/"), lit(">")];                          # self-closing
    je_open = (je_close ++> Seq())[0];                                         # open ... close
    je_open ++> lit(">");
    (je_open ++> Rep())[0] ++> sym("jsx_child");
    je_open ++> [lit("<"), lit("/")];
    (je_open ++> Choice())[0] ++> [sym("jsx_name"), blank()];
    je_open ++> lit(">");

    # Tag / attribute name: identifier, dotted member (`Foo.Bar`), or hyphenated
    # (`aria-label`); `@` is the raw-passthrough tag.
    jn = (rule(g, "jsx_name") ++> Seq())[0];
    (jn ++> Choice())[0] ++> [sym("identifier"), lit("@")];
    jn_rest = (jn ++> Rep())[0];
    jn_part = (jn_rest ++> Seq())[0];
    (jn_part ++> Choice())[0] ++> [lit("."), lit("-")];
    jn_part ++> sym("identifier");

    # jsx_attribute ::= name=jsx_name opt("=" value) | shorthand/spread
    ja = (rule(g, "jsx_attribute") ++> Choice())[0];
    ja_attr = (ja ++> Seq())[0];
    # shorthand / spread:  {expr} | {...expr} | {**expr}. The `**expr` form
    # parses as a prefix unary expression; `...` (rest/spread) is an
    # explicit optional prefix.
    ja_spread = (ja ++> Seq())[0];
    (ja_attr ++> Field(name="name"))[0] ++> sym("jsx_name");
    ja_eq_opt = (ja_attr ++> Choice())[0];
    ja_eq = (ja_eq_opt ++> Seq())[0];
    ja_eq_opt ++> blank();
    ja_eq ++> lit("=");
    ja_val_choice = ((ja_eq ++> Field(name="value"))[0] ++> Choice())[0];
    ja_val_choice ++> sym("string");
    (ja_val_choice ++> Seq())[0] ++> [lit("{"), sym("expression"), lit("}")];
    ja_spread ++> lit("{");
    (ja_spread ++> Choice())[0] ++> [lit("..."), blank()];
    ja_spread ++> [sym("expression"), lit("}")];

    (rule(g, "jsx_child") ++> Choice())[0] ++> [sym("jsx_text"), sym("jsx_element"), sym("jsx_expression")];

    # An embedded `{...}` in JSX children: a control-flow view block
    # (`{ if cond { <jsx> } }`), a statement interpolation (`{ x; }`), or a
    # value interpolation (`{count}`), per the jac.spec jsx_child production.
    jx = (rule(g, "jsx_expression") ++> Seq())[0];
    jx ++> lit("{");
    jx_inner = (jx ++> Choice())[0];
    jx ++> lit("}");
    jx_inner ++> sym("jsx_control");
    (jx_inner ++> Choice())[0] ++> [sym("expression"), blank()];

    # Conditional / iterative rendering. Unlike ordinary statements, the bodies
    # are JSX view blocks: bare jsx_children (elements/text/`{expr}`), no `;`.
    jctl = (rule(g, "jsx_control") ++> Choice())[0];
    jctl_if = (jctl ++> Seq())[0];
    jctl_for = (jctl ++> Seq())[0];
    jctl_while = (jctl ++> Seq())[0];
    jctl_if ++> lit("if");
    (jctl_if ++> Field(name="condition"))[0] ++> sym("expression");
    jctl_if ++> sym("jsx_view_block");
    jctl_if_elifs = (jctl_if ++> Rep())[0];
    jctl_if_else = (jctl_if ++> Choice())[0];
    (jctl_if_elifs ++> Seq())[0] ++> [lit("elif"), sym("expression"), sym("jsx_view_block")];
    (jctl_if_else ++> Seq())[0] ++> [lit("else"), sym("jsx_view_block")];
    jctl_if_else ++> blank();
    (jctl_for ++> Choice())[0] ++> [lit("async"), blank()];
    jctl_for ++> lit("for");
    (jctl_for ++> Field(name="left"))[0] ++> comma_sep1(sym("_primary_expression"));
    jctl_for ++> lit("in");
    (jctl_for ++> Field(name="right"))[0] ++> sym("expression");
    jctl_for ++> sym("jsx_view_block");
    jctl_while ++> lit("while");
    (jctl_while ++> Field(name="condition"))[0] ++> sym("expression");
    jctl_while ++> sym("jsx_view_block");

    jvb = (rule(g, "jsx_view_block") ++> Seq())[0];
    jvb ++> lit("{");
    (jvb ++> Rep())[0] ++> sym("jsx_child");
    jvb ++> lit("}");
}

def build_edges(g: Grammar) -> None {
    # connect_expression ::= precl(20, left=expression op=connect_op right=expression)
    ce = (rule(g, "connect_expression") ++> Prec(kind="PREC_LEFT", level=20))[0];
    ces = (ce ++> Seq())[0];
    (ces ++> Field(name="left"))[0]  ++> sym("expression");
    (ces ++> Field(name="op"))[0]    ++> sym("connect_op");
    (ces ++> Field(name="right"))[0] ++> sym("expression");

    # connect_op ::= "++>" | "<++" | "<++>" | typed-fwd | typed-back | "del" edge_op
    co = (rule(g, "connect_op") ++> Choice())[0];
    co ++> [lit("++>"), lit("<++"), lit("<++>")];
    co_a = (co ++> Seq())[0];
    co_b = (co ++> Seq())[0];
    # disconnect: `a del --> b` (jac.spec connect_op `"del" edge_op_ref`).
    (co ++> Seq())[0] ++> [lit("del"), sym("edge_op")];
    co_a ++> [lit("+>:"), sym("expression")];
    co_a_opt = (co_a ++> Choice())[0];
    co_a ++> lit(":+>");
    (co_a_opt ++> Seq())[0] ++> [lit(":"), sym("expression")];
    co_a_opt ++> blank();
    co_b ++> [lit("<+:"), sym("expression")];
    co_b_opt = (co_b ++> Choice())[0];
    co_b ++> lit(":<+");
    (co_b_opt ++> Seq())[0] ++> [lit(":"), sym("expression")];
    co_b_opt ++> blank();

    # edge_reference ::= "[" opt(edge|node) opt(expr) rep1(edge_op opt(filter)) opt(filter) "]"
    er = (rule(g, "edge_reference") ++> Seq())[0];
    er ++> lit("[");
    er_en_opt = (er ++> Choice())[0];
    er_e_opt = (er ++> Choice())[0];
    er_hops = (er ++> Rep1())[0];
    er_tf = (er ++> Choice())[0];
    er ++> lit("]");
    (er_en_opt ++> Choice())[0] ++> [lit("edge"), lit("node")];
    er_en_opt ++> blank();
    er_e_opt ++> [sym("expression"), blank()];
    er_hop = (er_hops ++> Seq())[0];
    er_hop ++> sym("edge_op");
    (er_hop ++> Choice())[0] ++> [sym("edge_filter"), blank()];
    er_tf ++> [sym("edge_filter"), blank()];

    # edge_op ::= "-->" | "<--" | "<-->" | typed-fwd | typed-back
    eo = (rule(g, "edge_op") ++> Choice())[0];
    eo ++> [lit("-->"), lit("<--"), lit("<-->")];
    eo_a = (eo ++> Seq())[0];
    eo_b = (eo ++> Seq())[0];
    eo_a ++> lit("->:");
    (eo_a ++> Choice())[0] ++> [name_ref(), blank()];
    eo_a_colon_opt = (eo_a ++> Choice())[0];
    eo_a ++> lit(":->");
    eo_a_colon = (eo_a_colon_opt ++> Seq())[0];
    eo_a_colon_opt ++> blank();
    eo_a_colon ++> lit(":");
    (eo_a_colon ++> Choice())[0] ++> [comma_sep1(sym("expression")), blank()];
    eo_b ++> lit("<-:");
    (eo_b ++> Choice())[0] ++> [name_ref(), blank()];
    eo_b_colon_opt = (eo_b ++> Choice())[0];
    eo_b ++> lit(":<-");
    eo_b_colon = (eo_b_colon_opt ++> Seq())[0];
    eo_b_colon_opt ++> blank();
    eo_b_colon ++> lit(":");
    (eo_b_colon ++> Choice())[0] ++> [comma_sep1(sym("expression")), blank()];

    # edge_filter ::= "[" opt("?" opt(":" expr)) opt(comma_sep1(expr)) "]"
    ef = (rule(g, "edge_filter") ++> Seq())[0];
    ef ++> lit("[");
    ef_q_opt = (ef ++> Choice())[0];
    ef_cs_opt = (ef ++> Choice())[0];
    ef ++> lit("]");
    ef_q = (ef_q_opt ++> Seq())[0];
    ef_q_opt ++> blank();
    ef_q ++> lit("?");
    ef_q_in_opt = (ef_q ++> Choice())[0];
    (ef_q_in_opt ++> Seq())[0] ++> [lit(":"), sym("expression")];
    ef_q_in_opt ++> blank();
    ef_cs_opt ++> [comma_sep1(sym("expression")), blank()];
}

# ===========================================================================
# Statements
# ===========================================================================

def build_stmts(g: Grammar) -> None {
    # Every statement self-terminates (own `;`, or ends in a block), so the
    # block body is just a sequence of statements -- no per-statement opt(";"),
    # which would otherwise fight each statement's own terminator.
    bb = (rule(g, "block_body") ++> Rep1())[0];
    bb ++> sym("statement");
    stmt = (rule(g, "statement") ++> Choice())[0];
    stmt ++> [
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
        sym("pyinline"),
        sym("expression_statement"),
        sym("empty_statement")
    ];
    # A lone `;` (e.g. an empty `else { ; }` / `except E { ; }` body).
    rule(g, "empty_statement") ++> lit(";");
    # A single rule covering expression / assignment / augmented-assignment.
    # Parsing the leading expression once, then an OPTIONAL assignment tail,
    # avoids a GLR conflict over the whole expression grammar (which exploded
    # the parse table). The next token (`=`/`:`/augop vs `;`) decides the tail.
    augops = [lit(a) for a in ["+=", "-=", "*=", "/=", "//=", "%=", "**=", "@=",
              "&=", "|=", "^=", "<<=", ">>="]];
    es = (rule(g, "expression_statement") ++> Seq())[0];
    (es ++> Field(name="left"))[0] ++> sym("expression");
    es_tail_opt = (es ++> Choice())[0];
    es ++> lit(";");
    es_tail = (es_tail_opt ++> Choice())[0];
    es_tail_opt ++> blank();
    es_ann = (es_tail ++> Seq())[0];   # `x: T`, `x: T = v` -- type annotation + value(s)
    es_asn = (es_tail ++> Rep1())[0];  # `x = v`, `x = v = w` -- chained assignment
    es_aug = (es_tail ++> Seq())[0];   # `x += v` -- augmented assignment
    es_ann ++> lit(":");
    (es_ann ++> Field(name="type"))[0] ++> sym("expression");
    es_ann_vals_opt = (es_ann ++> Choice())[0];
    es_ann_vals = (es_ann_vals_opt ++> Rep1())[0];
    es_ann_vals_opt ++> blank();
    es_ann_eq = (es_ann_vals ++> Seq())[0];
    es_ann_eq ++> lit("=");
    (es_ann_eq ++> Field(name="right"))[0] ++> sym("expression");
    es_asn_eq = (es_asn ++> Seq())[0];
    es_asn_eq ++> lit("=");
    (es_asn_eq ++> Field(name="right"))[0] ++> sym("expression");
    es_aug_op = ((es_aug ++> Field(name="operator"))[0] ++> Choice())[0];
    es_aug_op ++> augops;
    (es_aug ++> Field(name="right"))[0] ++> sym("expression");

    # if_statement ::= "if" condition=expr block opt(elif_clause | else_clause)
    if_s = (rule(g, "if_statement") ++> Seq())[0];
    if_s ++> lit("if");
    (if_s ++> Field(name="condition"))[0] ++> sym("expression");
    if_s ++> block();
    if_cont_opt = (if_s ++> Choice())[0];
    (if_cont_opt ++> Choice())[0] ++> [sym("elif_clause"), sym("else_clause")];
    if_cont_opt ++> blank();

    elif_s = (rule(g, "elif_clause") ++> Seq())[0];
    elif_s ++> lit("elif");
    (elif_s ++> Field(name="condition"))[0] ++> sym("expression");
    elif_s ++> block();
    elif_cont_opt = (elif_s ++> Choice())[0];
    (elif_cont_opt ++> Choice())[0] ++> [sym("elif_clause"), sym("else_clause")];
    elif_cont_opt ++> blank();

    else_s = (rule(g, "else_clause") ++> Seq())[0];
    else_s ++> [lit("else"), block()];

    wh = (rule(g, "while_statement") ++> Seq())[0];
    wh ++> lit("while");
    (wh ++> Field(name="condition"))[0] ++> sym("expression");
    wh ++> block();
    (wh ++> Choice())[0] ++> [sym("else_clause"), blank()];

    # The target is a primary-expression list, not a full expression, so the
    # `in` separator isn't swallowed as a binary `in` comparison (which broke
    # iterables like `node.bases or []`). Comma-separated for `for k, v in ...`.
    for_s = (rule(g, "for_statement") ++> Seq())[0];
    (for_s ++> Choice())[0] ++> [lit("async"), blank()];
    for_s ++> lit("for");
    (for_s ++> Field(name="target"))[0] ++> comma_sep1(sym("_primary_expression"));
    for_head = (for_s ++> Choice())[0];
    for_s ++> block();
    (for_s ++> Choice())[0] ++> [sym("else_clause"), blank()];
    for_in = (for_head ++> Seq())[0];
    for_in ++> lit("in");
    (for_in ++> Field(name="iter"))[0] ++> sym("expression");
    (for_head ++> Seq())[0] ++> [lit("="), sym("expression"), lit("to"), sym("expression"),
                                 lit("by"), sym("expression")];

    # try_statement ::= "try" block opt("awaiting" block) rep(except) opt(else) opt("finally" block)
    try_s = (rule(g, "try_statement") ++> Seq())[0];
    try_s ++> [lit("try"), block()];
    try_await_opt = (try_s ++> Choice())[0];
    try_excepts = (try_s ++> Rep())[0];
    try_else = (try_s ++> Choice())[0];
    try_finally_opt = (try_s ++> Choice())[0];
    (try_await_opt ++> Seq())[0] ++> [lit("awaiting"), block()];
    try_await_opt ++> blank();
    try_excepts ++> sym("except_clause");
    try_else ++> [sym("else_clause"), blank()];
    (try_finally_opt ++> Seq())[0] ++> [lit("finally"), block()];
    try_finally_opt ++> blank();

    exc = (rule(g, "except_clause") ++> Seq())[0];
    exc ++> [lit("except"), sym("expression")];
    exc_as_opt = (exc ++> Choice())[0];
    exc ++> block();
    (exc_as_opt ++> Seq())[0] ++> [lit("as"), name_ref()];
    exc_as_opt ++> blank();

    with_item = Seq();
    with_item ++> sym("expression");
    with_as_opt = (with_item ++> Choice())[0];
    (with_as_opt ++> Seq())[0] ++> [lit("as"), sym("expression")];
    with_as_opt ++> blank();
    with_s = (rule(g, "with_statement") ++> Seq())[0];
    (with_s ++> Choice())[0] ++> [lit("async"), blank()];
    with_s ++> [lit("with"), comma_sep1(with_item)];
    with_s ++> block();

    ret = (rule(g, "return_statement") ++> Seq())[0];
    ret ++> lit("return");
    (ret ++> Choice())[0] ++> [sym("expression"), blank()];
    ret ++> lit(";");

    yld = (rule(g, "yield_statement") ++> Seq())[0];
    yld ++> lit("yield");
    (yld ++> Choice())[0] ++> [lit("from"), blank()];
    (yld ++> Choice())[0] ++> [sym("expression"), blank()];
    yld ++> lit(";");

    rse = (rule(g, "raise_statement") ++> Seq())[0];
    rse ++> lit("raise");
    (rse ++> Choice())[0] ++> [sym("expression"), blank()];
    rse_from_opt = (rse ++> Choice())[0];
    rse ++> lit(";");
    (rse_from_opt ++> Seq())[0] ++> [lit("from"), sym("expression")];
    rse_from_opt ++> blank();

    asrt = (rule(g, "assert_statement") ++> Seq())[0];
    asrt ++> [lit("assert"), sym("expression")];
    asrt_msg_opt = (asrt ++> Choice())[0];
    asrt ++> lit(";");
    (asrt_msg_opt ++> Seq())[0] ++> [lit(","), sym("expression")];
    asrt_msg_opt ++> blank();

    del_s = (rule(g, "delete_statement") ++> Seq())[0];
    del_s ++> [lit("del"), sym("expression"), lit(";")];

    ctrl = (rule(g, "control_statement") ++> Seq())[0];
    (ctrl ++> Choice())[0] ++> [lit("break"), lit("continue"), lit("skip")];
    ctrl ++> lit(";");

    dis = (rule(g, "disengage_statement") ++> Seq())[0];
    dis ++> [lit("disengage"), lit(";")];

    # prec.right so the optional trailing `;` is consumed here rather than left
    # to stand alone as an empty_statement.
    vis = (rule(g, "visit_statement") ++> Prec(kind="PREC_RIGHT", level=1))[0];
    vis_s = (vis ++> Seq())[0];
    vis_s ++> lit("visit");
    vis_label_opt = (vis_s ++> Choice())[0];
    vis_s ++> sym("expression");
    vis_tail_opt = (vis_s ++> Choice())[0];
    (vis_label_opt ++> Seq())[0] ++> [lit(":"), sym("expression"), lit(":")];
    vis_label_opt ++> blank();
    (vis_tail_opt ++> Choice())[0] ++> [sym("else_clause"), lit(";")];
    vis_tail_opt ++> blank();

    rep_s = (rule(g, "report_statement") ++> Seq())[0];
    rep_s ++> [lit("report"), sym("expression"), lit(";")];

    glob_s = (rule(g, "global_statement") ++> Seq())[0];
    glob_s ++> [lit("global"), comma_sep1(name_ref()), lit(";")];

    nonlocal_s = (rule(g, "nonlocal_statement") ++> Seq())[0];
    nonlocal_s ++> [lit("nonlocal"), comma_sep1(name_ref()), lit(";")];
}

# ===========================================================================
# Patterns (match / switch)
# ===========================================================================

def build_patterns(g: Grammar) -> None {
    # match_statement ::= "match" expr "{" rep(match_case) "}"
    ms = (rule(g, "match_statement") ++> Seq())[0];
    ms ++> [lit("match"), sym("expression"), lit("{")];
    (ms ++> Rep())[0] ++> sym("match_case");
    ms ++> lit("}");

    # match_case ::= "case" pattern opt("if" expr) ":" rep(statement)
    mc = (rule(g, "match_case") ++> Seq())[0];
    mc ++> [lit("case"), sym("pattern")];
    mc_guard_opt = (mc ++> Choice())[0];
    mc ++> lit(":");
    (mc ++> Rep())[0] ++> sym("statement");
    (mc_guard_opt ++> Seq())[0] ++> [lit("if"), sym("expression")];
    mc_guard_opt ++> blank();

    # pattern ::= or_pattern opt("as" name)
    ptn = (rule(g, "pattern") ++> Seq())[0];
    ptn ++> sym("or_pattern");
    ptn_as_opt = (ptn ++> Choice())[0];
    (ptn_as_opt ++> Seq())[0] ++> [lit("as"), name_ref()];
    ptn_as_opt ++> blank();

    # or_pattern ::= closed_pattern rep("|" closed_pattern)
    op = (rule(g, "or_pattern") ++> Seq())[0];
    op ++> sym("closed_pattern");
    op_rest = (op ++> Rep())[0];
    (op_rest ++> Seq())[0] ++> [lit("|"), sym("closed_pattern")];

    cp = (rule(g, "closed_pattern") ++> Choice())[0];
    cp ++> [sym("bool"), sym("null"), sym("integer"), sym("float"), sym("string"),
            sym("sequence_pattern"), sym("mapping_pattern"), sym("class_pattern"),
            sym("capture_pattern")];

    # Use a dotted name (not a full `expression`) so patterns don't overlap the
    # expression grammar (which collided with `atom`).
    dpn = (rule(g, "dotted_pattern_name") ++> Seq())[0];
    dpn ++> name_ref();
    dpn_rest = (dpn ++> Rep())[0];
    (dpn_rest ++> Seq())[0] ++> [lit("."), name_ref()];

    rule(g, "capture_pattern") ++> sym("dotted_pattern_name");

    # sequence_pattern ::= "[" comma_sep( "*" name | pattern ) opt(",") "]"
    seqp = (rule(g, "sequence_pattern") ++> Seq())[0];
    seqp ++> lit("[");
    seqp_elem = Choice();
    (seqp_elem ++> Seq())[0] ++> [lit("*"), name_ref()];
    seqp_elem ++> sym("pattern");
    seqp ++> comma_sep(seqp_elem);
    seqp_trail = (seqp ++> Choice())[0];
    seqp ++> lit("]");
    seqp_trail ++> [lit(","), blank()];

    # mapping_pattern ::= "{" comma_sep( "**" name | key ":" pattern ) opt(",") "}"
    mp = (rule(g, "mapping_pattern") ++> Seq())[0];
    mp ++> lit("{");
    mp_elem = Choice();
    (mp_elem ++> Seq())[0] ++> [lit("**"), name_ref()];
    mp_kv = (mp_elem ++> Seq())[0];
    (mp_kv ++> Choice())[0] ++> [sym("integer"), sym("float"), sym("string"), sym("dotted_pattern_name")];
    mp_kv ++> [lit(":"), sym("pattern")];
    mp ++> comma_sep(mp_elem);
    mp_trail = (mp ++> Choice())[0];
    mp ++> lit("}");
    mp_trail ++> [lit(","), blank()];

    # class_pattern ::= dotted_pattern_name "(" comma_sep( name "=" pattern | pattern ) opt(",") ")"
    clp = (rule(g, "class_pattern") ++> Seq())[0];
    clp ++> [sym("dotted_pattern_name"), lit("(")];
    clp_elem = Choice();
    (clp_elem ++> Seq())[0] ++> [name_ref(), lit("="), sym("pattern")];
    clp_elem ++> sym("pattern");
    clp ++> comma_sep(clp_elem);
    clp_trail = (clp ++> Choice())[0];
    clp ++> lit(")");
    clp_trail ++> [lit(","), blank()];

    sw = (rule(g, "switch_statement") ++> Seq())[0];
    sw ++> [lit("switch"), sym("expression"), lit("{")];
    (sw ++> Rep())[0] ++> sym("switch_case");
    sw ++> lit("}");

    # switch_case ::= ("default" | "case" pattern) ":" rep(statement)
    swc = (rule(g, "switch_case") ++> Seq())[0];
    swc_head = (swc ++> Choice())[0];
    swc ++> lit(":");
    (swc ++> Rep())[0] ++> sym("statement");
    swc_head ++> lit("default");
    (swc_head ++> Seq())[0] ++> [lit("case"), sym("pattern")];
}

# ===========================================================================
# Declarations (archetypes, abilities, has, enum, test, glob, impl, type)
#
# NOTE: jac.spec hoists the obj/node/.../def/can dispatch keyword out of the
# `archetype`/`ability` rules (an extraction artifact). The real .jac surface
# carries the keyword in the declaration, so it is re-added here.
# ===========================================================================

def build_decls(g: Grammar) -> None {
    # decorator_list ::= rep1("@" expr)
    dl = (rule(g, "decorator_list") ++> Rep1())[0];
    (dl ++> Seq())[0] ++> [lit("@"), sym("expression")];

    rule(g, "type_annotation") ++> sym("expression");

    # param ::= opt("*"|"**") (name|special_ref) opt(":" type) opt("=" expr)
    param = (rule(g, "param") ++> Seq())[0];
    param_star_opt = (param ++> Choice())[0];
    (param_star_opt ++> Choice())[0] ++> [lit("*"), lit("**")];
    param_star_opt ++> blank();
    (param ++> Choice())[0] ++> [name_ref(), sym("special_ref")];
    param_type_opt = (param ++> Choice())[0];
    param_def_opt = (param ++> Choice())[0];
    (param_type_opt ++> Seq())[0] ++> [lit(":"), sym("type_annotation")];
    param_type_opt ++> blank();
    (param_def_opt ++> Seq())[0] ++> [lit("="), sym("expression")];
    param_def_opt ++> blank();

    pl = (rule(g, "parameter_list") ++> Seq())[0];
    pl ++> lit("(");
    pl_elem = Choice();
    pl_elem ++> [lit("*"), lit("/"), sym("param")];
    pl ++> comma_sep(pl_elem);
    pl_trail = (pl ++> Choice())[0];
    pl ++> lit(")");
    pl_trail ++> [lit(","), blank()];

    # func_signature ::= parameter_list opt("->" return_type) | "->" return_type
    fs = (rule(g, "func_signature") ++> Choice())[0];
    fs_a = (fs ++> Seq())[0];
    fs_b = (fs ++> Seq())[0];
    fs_a ++> sym("parameter_list");
    fs_arrow1_opt = (fs_a ++> Choice())[0];
    fs_arrow1 = (fs_arrow1_opt ++> Seq())[0];
    fs_arrow1_opt ++> blank();
    fs_arrow1 ++> lit("->");
    (fs_arrow1 ++> Field(name="return_type"))[0] ++> sym("type_annotation");
    fs_b ++> lit("->");
    (fs_b ++> Field(name="return_type"))[0] ++> sym("type_annotation");

    # archetype ::= decorators opt("async") kind=... access_tag name=... opt(type_params)
    #               opt("(" bases ")") ( "{" members "}" | ";" )
    arch = (rule(g, "archetype") ++> Seq())[0];
    arch ++> decorators();
    (arch ++> Choice())[0] ++> [lit("async"), blank()];
    ((arch ++> Field(name="kind"))[0] ++> Choice())[0] ++> [lit("obj"), lit("node"), lit("edge"), lit("walker"), lit("class")];
    arch ++> access_tag();
    (arch ++> Field(name="name"))[0] ++> name_ref();
    (arch ++> Choice())[0] ++> [sym("type_params"), blank()];
    arch_bases_opt = (arch ++> Choice())[0];
    arch_body = (arch ++> Choice())[0];
    arch_bases = (arch_bases_opt ++> Seq())[0];
    arch_bases_opt ++> blank();
    arch_bases ++> lit("(");
    (arch_bases ++> Choice())[0] ++> [comma_sep1(sym("expression")), blank()];
    arch_bases ++> lit(")");
    arch_block = (arch_body ++> Seq())[0];
    arch_body ++> lit(";");
    arch_block ++> lit("{");
    (arch_block ++> Rep())[0] ++> sym("archetype_member");
    arch_block ++> lit("}");

    am = (rule(g, "archetype_member") ++> Choice())[0];
    am ++> [sym("has_statement"), sym("ability"), sym("archetype"),
            sym("enum"), sym("impl"), sym("with_entry")];
    am_str = (am ++> Seq())[0];
    am_str ++> sym("string");
    (am_str ++> Choice())[0] ++> [lit(";"), blank()];

    we = (rule(g, "with_entry") ++> Seq())[0];
    we ++> lit("with");
    we_ee_opt = (we ++> Choice())[0];
    we ++> block();
    (we_ee_opt ++> Choice())[0] ++> [lit("entry"), lit("exit")];
    we_ee_opt ++> blank();

    # ability ::= decorators opt("override") opt("static") opt("async") kind=(def|can)
    #             access_tag opt(name) opt(type_params) opt(event_clause|func_signature)
    #             ( block | opt("abs") ";" | "by" expr ";" )
    ab = (rule(g, "ability") ++> Seq())[0];
    ab ++> decorators();
    (ab ++> Choice())[0] ++> [lit("override"), blank()];
    (ab ++> Choice())[0] ++> [lit("static"), blank()];
    (ab ++> Choice())[0] ++> [lit("async"), blank()];
    ((ab ++> Field(name="kind"))[0] ++> Choice())[0] ++> [lit("def"), lit("can")];
    ab ++> access_tag();
    ab_name_opt = (ab ++> Choice())[0];
    (ab ++> Choice())[0] ++> [sym("type_params"), blank()];
    ab_sig_opt = (ab ++> Choice())[0];
    ab_body = (ab ++> Choice())[0];
    (ab_name_opt ++> Field(name="name"))[0] ++> name_ref();
    ab_name_opt ++> blank();
    (ab_sig_opt ++> Choice())[0] ++> [sym("event_clause"), sym("func_signature")];
    ab_sig_opt ++> blank();
    ab_body ++> block();
    ab_decl = (ab_body ++> Seq())[0];
    (ab_body ++> Seq())[0] ++> [lit("by"), sym("expression"), lit(";")];
    (ab_decl ++> Choice())[0] ++> [lit("abs"), blank()];
    ab_decl ++> lit(";");

    # Ability event signature: `with <NodeType> entry|exit` (object-spatial
    # dispatch), e.g. `can create with Root entry { ... }`. The trailing
    # entry/exit keyword can't be part of the expression, so it is consumed
    # explicitly after it.
    ec = (rule(g, "event_clause") ++> Seq())[0];
    ec ++> [lit("with"), sym("expression")];
    ec_ee_opt = (ec ++> Choice())[0];
    (ec_ee_opt ++> Choice())[0] ++> [lit("entry"), lit("exit")];
    ec_ee_opt ++> blank();

    # prec.right so the optional trailing `;` is consumed here; an accessor-block
    # `has` self-terminates (ends in `}`) so the `;` is optional, like other
    # block-bodied constructs.
    hs = (rule(g, "has_statement") ++> Prec(kind="PREC_RIGHT", level=1))[0];
    hs_s = (hs ++> Seq())[0];
    (hs_s ++> Choice())[0] ++> [lit("static"), blank()];
    hs_s ++> [lit("has"), access_tag(), comma_sep1(sym("has_var"))];
    (hs_s ++> Choice())[0] ++> [lit(";"), blank()];

    # prec.right so a following `{` attaches as this field's accessor_block
    # rather than reducing the has_var early.
    hv = (rule(g, "has_var") ++> Prec(kind="PREC_RIGHT", level=1))[0];
    hv_s = (hv ++> Seq())[0];
    (hv_s ++> Field(name="name"))[0] ++> name_ref();
    hv_s ++> lit(":");
    (hv_s ++> Field(name="type"))[0] ++> sym("type_annotation");
    hv_init_opt = (hv_s ++> Choice())[0];
    (hv_s ++> Choice())[0] ++> [sym("accessor_block"), blank()];
    hv_init = (hv_init_opt ++> Choice())[0];
    hv_init_opt ++> blank();
    (hv_init ++> Seq())[0] ++> [lit("="), sym("expression")];
    (hv_init ++> Seq())[0] ++> [lit("by"), lit("postinit")];

    # Property accessors on a `has` field: `{ getter; setter(value: T); }`.
    acb = (rule(g, "accessor_block") ++> Seq())[0];
    acb ++> lit("{");
    (acb ++> Rep())[0] ++> sym("accessor");
    acb ++> lit("}");

    acc = (rule(g, "accessor") ++> Seq())[0];
    (acc ++> Field(name="name"))[0] ++> name_ref();
    (acc ++> Choice())[0] ++> [sym("parameter_list"), blank()];
    acc_arrow_opt = (acc ++> Choice())[0];
    acc_body = (acc ++> Choice())[0];
    acc_arrow = (acc_arrow_opt ++> Seq())[0];
    acc_arrow_opt ++> blank();
    acc_arrow ++> lit("->");
    (acc_arrow ++> Field(name="return_type"))[0] ++> sym("type_annotation");
    acc_body ++> block();
    acc_body ++> lit(";");

    # enum ::= decorators "enum" access_tag name opt(base) ( "{" members opt(",") "}" | ";" )
    # base class: either `: Base` or `(Base, ...)` (jac.spec).
    en = (rule(g, "enum") ++> Seq())[0];
    en ++> [decorators(), lit("enum"), access_tag()];
    (en ++> Field(name="name"))[0] ++> name_ref();
    en_base_opt = (en ++> Choice())[0];
    en_body = (en ++> Choice())[0];
    en_base = (en_base_opt ++> Choice())[0];
    en_base_opt ++> blank();
    (en_base ++> Seq())[0] ++> [lit(":"), sym("expression")];
    en_base_paren = (en_base ++> Seq())[0];
    en_base_paren ++> lit("(");
    (en_base_paren ++> Choice())[0] ++> [comma_sep1(sym("expression")), blank()];
    en_base_paren ++> lit(")");
    en_block = (en_body ++> Seq())[0];
    en_body ++> lit(";");
    en_block ++> lit("{");
    en_block ++> comma_sep(sym("enum_member"));
    (en_block ++> Choice())[0] ++> [lit(","), blank()];
    en_block ++> lit("}");

    enm = (rule(g, "enum_member") ++> Seq())[0];
    enm ++> name_ref();
    enm_val_opt = (enm ++> Choice())[0];
    (enm_val_opt ++> Seq())[0] ++> [lit("="), sym("expression")];
    enm_val_opt ++> blank();

    test_s = (rule(g, "test") ++> Seq())[0];
    test_s ++> [decorators(), lit("test")];
    (test_s ++> Choice())[0] ++> [sym("string"), blank()];
    test_s ++> block();

    # global_var ::= "glob" access_tag comma_sep1(name opt(":" type) opt(rep1("=" expr))) ";"
    gv_item = Seq();
    (gv_item ++> Field(name="name"))[0] ++> name_ref();
    gv_type_opt = (gv_item ++> Choice())[0];
    gv_vals_opt = (gv_item ++> Choice())[0];
    (gv_type_opt ++> Seq())[0] ++> [lit(":"), sym("type_annotation")];
    gv_type_opt ++> blank();
    gv_vals = (gv_vals_opt ++> Rep1())[0];
    gv_vals_opt ++> blank();
    (gv_vals ++> Seq())[0] ++> [lit("="), sym("expression")];
    gv = (rule(g, "global_var") ++> Seq())[0];
    gv ++> [lit("glob"), access_tag(), comma_sep1(gv_item), lit(";")];

    # The impl target is a dotted name PATH (`Class.method`, `Walker.entry`,
    # `Obj.init`), NOT a general expression -- using `expression` made
    # `impl X.f(params)` greedily parse as a call_expression, so the func
    # signature's `(` collided and every signature-bearing impl failed.
    impl_s = (rule(g, "impl") ++> Seq())[0];
    impl_s ++> [decorators(), lit("impl")];
    (impl_s ++> Field(name="target"))[0] ++> sym("impl_target");
    impl_sig_opt = (impl_s ++> Choice())[0];
    impl_body = (impl_s ++> Choice())[0];
    (impl_sig_opt ++> Choice())[0] ++> [sym("event_clause"), sym("func_signature")];
    impl_sig_opt ++> blank();
    impl_body ++> block();
    (impl_body ++> Seq())[0] ++> [lit("by"), sym("expression"), lit(";")];
    impl_body ++> lit(";");

    it = (rule(g, "impl_target") ++> Prec(kind="PREC_LEFT", level=1))[0];
    it_s = (it ++> Seq())[0];
    it_s ++> sym("impl_target_name");
    it_rest = (it_s ++> Rep())[0];
    (it_rest ++> Seq())[0] ++> [lit("."), sym("impl_target_name")];

    # impl_target_name (jac.spec): NAME/KWESC plus a few contextual keywords
    # that name abilities/ctors. Keyword extraction (word: identifier) keeps
    # these usable as ordinary identifiers elsewhere.
    itn = (rule(g, "impl_target_name") ++> Choice())[0];
    itn ++> [name_ref(),
             lit("init"), lit("postinit"), lit("entry"), lit("exit"), lit("default")];

    ta = (rule(g, "type_alias") ++> Seq())[0];
    ta ++> [lit("type"), access_tag()];
    (ta ++> Field(name="name"))[0] ++> name_ref();
    (ta ++> Choice())[0] ++> [sym("type_params"), blank()];
    ta ++> [lit("="), sym("type_annotation"), lit(";")];

    tp_item = Seq();
    tp_item ++> name_ref();
    tp_bound_opt = (tp_item ++> Choice())[0];
    tp_def_opt = (tp_item ++> Choice())[0];
    (tp_bound_opt ++> Seq())[0] ++> [lit(":"), sym("expression")];
    tp_bound_opt ++> blank();
    (tp_def_opt ++> Seq())[0] ++> [lit("="), sym("expression")];
    tp_def_opt ++> blank();
    tp = (rule(g, "type_params") ++> Seq())[0];
    tp ++> [lit("["), comma_sep1(tp_item), lit("]")];

    sem = (rule(g, "sem_def") ++> Prec(kind="PREC_RIGHT", level=1))[0];
    sem_s = (sem ++> Seq())[0];
    sem_s ++> [lit("sem"), sym("impl_target")];
    (sem_s ++> Choice())[0] ++> [lit("="), lit("is")];
    (sem_s ++> Rep())[0] ++> sym("string");
    (sem_s ++> Choice())[0] ++> [lit(";"), blank()];
}

# ===========================================================================
# Imports & module structure
# ===========================================================================

def build_imports(g: Grammar) -> None {
    # prec.right so the optional trailing `;` after the `{ ... }` items form is
    # shifted into THIS statement rather than left dangling (a benign
    # shift/reduce on the optional terminator).
    ist = (rule(g, "import_statement") ++> Prec(kind="PREC_RIGHT", level=1))[0];
    ist_s = (ist ++> Seq())[0];
    (ist_s ++> Choice())[0] ++> [lit("import"), lit("include")];
    (ist_s ++> Choice())[0] ++> [lit("type"), blank()];
    ist_from_opt = (ist_s ++> Choice())[0];
    ist_body = (ist_s ++> Choice())[0];
    (ist_from_opt ++> Seq())[0] ++> [lit("from"), sym("import_path")];
    ist_from_opt ++> blank();
    # The `{ ... }` items form ends in a block, so (like every other
    # block-bodied construct in Jac) it self-terminates and the trailing
    # `;` is optional -- real Jac omits it after `import from x { ... }`.
    ist_items = (ist_body ++> Seq())[0];
    ist_path = (ist_body ++> Seq())[0];
    ist_items ++> sym("import_items");
    (ist_items ++> Choice())[0] ++> [lit(";"), blank()];
    ist_path ++> sym("import_path");
    ist_path_as = (ist_path ++> Choice())[0];
    ist_path ++> lit(";");
    (ist_path_as ++> Seq())[0] ++> [lit("as"), name_ref()];
    ist_path_as ++> blank();

    # precl(2) so extending the path (`a` + `.b`) binds TIGHTER than reducing
    # the enclosing `import_path` relative branch (precr 1) -- otherwise a
    # `...pkg.sub` path reduces after the first segment and orphans `.sub`.
    dn = (rule(g, "dotted_name") ++> Choice())[0];
    dn ++> name_ref();
    dn_rec = (dn ++> Prec(kind="PREC_LEFT", level=2))[0];
    (dn_rec ++> Seq())[0] ++> [sym("dotted_name"), lit("."), name_ref()];

    # Leading relative-import dots: `.`, `..`, `...` (and longer runs).
    # Explicit left-recursion + prec.left resolves the dot shift/reduce without
    # a GLR dynamic conflict. The dots only ever precede the path (never follow
    # a NAME), so they never clash with `dotted_name`'s own `.` separators.
    rp = (rule(g, "relative_prefix") ++> Choice())[0];
    (rp ++> Choice())[0] ++> [lit("."), lit("...")];
    rp_rec = (rp ++> Prec(kind="PREC_LEFT", level=1))[0];
    rp_rec_s = (rp_rec ++> Seq())[0];
    rp_rec_s ++> sym("relative_prefix");
    (rp_rec_s ++> Choice())[0] ++> [lit("."), lit("...")];

    ip = (rule(g, "import_path") ++> Choice())[0];
    ip ++> [sym("string"), sym("dotted_name")];
    ip_rel = (ip ++> Prec(kind="PREC_RIGHT", level=1))[0];
    ip_rel_s = (ip_rel ++> Seq())[0];
    ip_rel_s ++> sym("relative_prefix");
    ip_tail_opt = (ip_rel_s ++> Choice())[0];
    (ip_tail_opt ++> Choice())[0] ++> [sym("string"), sym("dotted_name")];
    ip_tail_opt ++> blank();

    ii_item = Seq();
    (ii_item ++> Choice())[0] ++> [lit("*"), name_ref()];
    ii_as_opt = (ii_item ++> Choice())[0];
    (ii_as_opt ++> Seq())[0] ++> [lit("as"), name_ref()];
    ii_as_opt ++> blank();
    ii = (rule(g, "import_items") ++> Seq())[0];
    ii ++> lit("{");
    ii ++> comma_sep1(ii_item);
    ii_trail = (ii ++> Choice())[0];
    ii ++> lit("}");
    ii_trail ++> [lit(","), blank()];

    mod = (rule(g, "module_code") ++> Seq())[0];
    mod ++> lit("with");
    mod_ee_opt = (mod ++> Choice())[0];
    mod_named_opt = (mod ++> Choice())[0];
    mod ++> block();
    (mod_ee_opt ++> Choice())[0] ++> [lit("entry"), lit("exit")];
    mod_ee_opt ++> blank();
    (mod_named_opt ++> Seq())[0] ++> [lit(":"), name_ref()];
    mod_named_opt ++> blank();

    ctx = (rule(g, "context_block") ++> Seq())[0];
    ((ctx ++> Field(name="context"))[0] ++> Choice())[0] ++> [lit("cl"), lit("sv"), lit("na")];
    ctx_body = (ctx ++> Choice())[0];
    ctx_block = (ctx_body ++> Seq())[0];
    ctx_body ++> sym("element");
    ctx_block ++> lit("{");
    (ctx_block ++> Rep())[0] ++> sym("element");
    ctx_block ++> lit("}");

    elem = (rule(g, "element") ++> Choice())[0];
    elem ++> [
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
    ];
}

def build -> Grammar {
    g = Grammar(name="jac");
    (rule(g, "source_file") ++> Rep())[0] ++> sym("element");
    build_imports(g);
    build_decls(g);
    build_stmts(g);
    build_patterns(g);
    build_expr(g);
    build_collections(g);
    build_edges(g);
    build_jsx(g);
    build_tokens(g);
    return g;
}

with entry {
    g = build();
    out = {
        "name": g.name,
        "word": "identifier",
        "extras": [emit(pat("\\s")), emit(sym("comment"))],
        "conflicts": [
            ["param"],
            # Comprehension element vs. for-clause target: in `[<e> for <t> in ...]`
            # both `<e>` and the comma-separated `<t>` are expression-like, so
            # GLR must keep both interpretations until the `for`/`in` resolves it.
            ["expression", "for_in_clause"],
            # `<Foo.Bar>` (JSX member-tag name) vs `x < Foo.Bar` (less-than on a
            # dotted name): the dotted continuation is ambiguous, so GLR keeps
            # both the jsx_name and name_ref reads alive.
            ["jsx_name", "_name_ref"],
            # `{...expr}` JSX spread vs the `...` ellipsis atom starting an
            # expression -- only the spread is valid for `{...props}`, GLR drops
            # the other.
            ["jsx_attribute", "ellipsis"],
            # `{ for x in xs { <jsx> } }` view-body control flow vs a `for`
            # comprehension clause -- the `for ... in` prefix is shared until the
            # body shape (view block vs comprehension) decides it.
            ["expression", "jsx_control"],
            # for-statement target (a primary-expr list) vs an expression: the
            # `for <t1, t2> in` target overlaps an expression list until `in`.
            ["expression", "for_statement"]
        ],
        # External tokens provided by src/scanner.c (hand-written C). Order MUST
        # match the TokenType enum in scanner.c.
        "externals": [
            emit(sym("pyinline")), emit(sym("jsx_text")),
            emit(sym("fstring_start")), emit(sym("fstring_content")),
            emit(sym("fstring_end"))
        ],
        "inline": [],
        "supertypes": [],
        "rules": g.rules_json()
    };
    here = os.path.dirname(os.path.abspath(__file__));
    dest = os.path.join(here, "src", "grammar.json");
    with open(dest, "w") as f {
        f.write(json.dumps(out, indent=2) + "\n");
    }
    print(f"wrote {dest}");
}
