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
# Shared fragments
#
# Rules are built TOP-DOWN from the node constructors directly: create the
# parent, then descend into its children with `(parent ++> Child())[0]` -- `++>`
# returns its TARGETS (not the source), so `[0]` hands back the fresh child to
# keep building into; a run of leaf/ref children connects in one fan-out,
# `parent ++> [a, b, c]`. Terminals are the pure-data nodes themselves --
# `Lit(value=...)`, `Pat(value=...)`, `Sym(name=...)`, `Blank()` -- and a rule is
# `(g ++> Rule(name=...))[0]`. `comma_sep1`/`comma_sep` stay as helpers: each
# builds a multi-node fragment (comma_sep1 shares its `r` child between two
# sequences) used at ~30 expression sites, so neither is an inline constructor.
# ===========================================================================

"""Comma-separated list of one or more `r` (no trailing comma): `r ("," r)*`.
The SAME `r` node is connected under both the outer and the inner sequence (a
shared child), so it serializes by value in each place it appears."""
def comma_sep1(r: GNode) -> GNode {
    outer = Seq();
    outer ++> r;                       # member 1: r
    more  = (outer ++> Rep())[0];      # member 2: a Rep -- descend into it
    inner = (more  ++> Seq())[0];      # Rep's content: a Seq -- descend into it
    inner ++> [Lit(value=","), r];           # that Seq's members: "," then r
    return outer;
}

"""Comma-separated list of zero or more `r`."""
def comma_sep(r: GNode) -> GNode {
    cs = Choice();
    cs ++> [comma_sep1(r), Blank()];
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
def name_ref() -> GNode { return Sym(name="_name_ref"); }

"""access_tag ::= (":" ("pub" | "priv" | "protect")?)?"""
def access_tag() -> GNode {
    at = Choice();
    colon = (at ++> Seq())[0];          # member 1: the ":" ...? sequence
    at ++> Blank();                     # member 2: empty
    colon ++> Lit(value=":");
    vis_opt = (colon ++> Choice())[0];  # optional visibility keyword
    vis = (vis_opt ++> Choice())[0];
    vis_opt ++> Blank();
    vis ++> [Lit(value="pub"), Lit(value="priv"), Lit(value="protect")];
    return at;
}

"""Decorators `(@expr)*`. References the SHARED `decorator_list` rule (rep1,
defined in build_decls) wrapped in opt, so the decorator-prefix states are
built once rather than duplicated across every decl that can carry them."""
def decorators() -> GNode {
    d = Choice();
    d ++> [Sym(name="decorator_list"), Blank()];
    return d;
}

"""A `{ ... }` code block. References the SHARED `block_body` rule (defined in
build_stmts) so tree-sitter builds the statement-list state machine ONCE,
instead of duplicating it at every block site (which exploded the parse
table). `block_body` is rep1 (non-empty); the inner opt handles the empty `{}`."""
def block() -> GNode {
    b = Seq();
    b ++> Lit(value="{");
    bb = (b ++> Choice())[0];           # optional block_body
    b ++> Lit(value="}");
    bb ++> [Sym(name="block_body"), Blank()];
    return b;
}

# ===========================================================================
# Tokens
# ===========================================================================

def build_tokens(g: Grammar) -> None {
    ((g ++> Rule(name="identifier"))[0] ++> Tok())[0] ++> Pat(value="[a-zA-Z_][a-zA-Z0-9_]*");
    ((g ++> Rule(name="kwesc_name"))[0] ++> Tok())[0] ++> Pat(value="`[a-zA-Z_][a-zA-Z0-9_]*");
    ((g ++> Rule(name="_name_ref"))[0] ++> Choice())[0] ++> [Sym(name="identifier"), Sym(name="kwesc_name")];
    int_t = ((g ++> Rule(name="integer"))[0] ++> Tok())[0];
    (int_t ++> Choice())[0] ++> [
        Pat(value="0[xX][0-9a-fA-F_]+"),
        Pat(value="0[bB][01_]+"),
        Pat(value="0[oO][0-7_]+"),
        Pat(value="[0-9][0-9_]*")
    ];
    flt_t = ((g ++> Rule(name="float"))[0] ++> Tok())[0];
    (flt_t ++> Choice())[0] ++> [
        Pat(value="[0-9][0-9_]*\\.[0-9_]*([eE][-+]?[0-9_]+)?"),
        Pat(value="\\.[0-9][0-9_]*([eE][-+]?[0-9_]+)?"),
        Pat(value="[0-9][0-9_]*[eE][-+]?[0-9_]+")
    ];
    # NOTE: f-strings and JSX text need an external C scanner for full fidelity
    # (interpolation / context-sensitive lexing). v0.1 treats strings -- incl.
    # f/r/b-prefixed -- as opaque tokens; interpolated exprs are not yet split
    # out. Tracked as the external-scanner follow-up.
    # Non-f strings only; f-strings (prefix containing f/F) are tokenized by the
    # external scanner into start/content/interpolation/end (see `fstring`).
    str_seq = (((g ++> Rule(name="string"))[0] ++> Tok())[0] ++> Seq())[0];
    (str_seq ++> Choice())[0] ++> [Pat(value="[rRbB]+"), Blank()];
    (str_seq ++> Choice())[0] ++> [
        Pat(value="\"\"\"([^\"]|\"[^\"]|\"\"[^\"])*\"\"\""),
        Pat(value="'''([^']|'[^']|''[^'])*'''"),
        Pat(value="\"([^\"\\\\\\n]|\\\\.)*\""),
        Pat(value="'([^'\\\\\\n]|\\\\.)*'")
    ];
    ((g ++> Rule(name="bool"))[0] ++> Choice())[0] ++> [Lit(value="True"), Lit(value="False")];
    (g ++> Rule(name="null"))[0] ++> Lit(value="None");
    (g ++> Rule(name="ellipsis"))[0] ++> Lit(value="...");
    ((g ++> Rule(name="comment"))[0] ++> Tok())[0] ++> Pat(value="#.*");
    # `pyinline` (jac.spec PYNLINE) is a whole `::py:: ... ::py::` block. Its
    # body is arbitrary Python that the context-free grammar can't delimit, so
    # it is provided by the external scanner (src/scanner.c) and declared in
    # `externals` below -- no rule here.
    bt = [Lit(value=t) for t in [
        "str", "int", "float", "list", "tuple", "set", "dict", "bool", "bytes",
        "any", "type", "i8", "u8", "i16", "u16", "i32", "u32", "i64", "u64",
        "f32", "f64"
    ]];
    ((g ++> Rule(name="builtin_type"))[0] ++> Choice())[0] ++> bt;
    sr = [Lit(value=s) for s in [
        "self", "super", "here", "root", "visitor", "props", "init", "postinit"
    ]];
    ((g ++> Rule(name="special_ref"))[0] ++> Choice())[0] ++> sr;
}

# ===========================================================================
# Expressions
#
# The jac.spec precedence cascade is realized the idiomatic tree-sitter way:
# one `expression` supertype and a `binary_expression` whose alternatives carry
# `prec` levels read straight off the spec's ordering (higher binds tighter).
# ===========================================================================

def build_expr(g: Grammar) -> None {
    expr = ((g ++> Rule(name="expression"))[0] ++> Choice())[0];
    expr ++> [
        Sym(name="binary_expression"),
        Sym(name="unary_expression"),
        Sym(name="ternary_expression"),
        Sym(name="lambda_expression"),
        Sym(name="connect_expression"),
        Sym(name="concurrent_expression"),
        Sym(name="_primary_expression")
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
        (be_s ++> Field(name="left"))[0] ++> Sym(name="expression");
        (be_s ++> Field(name="operator"))[0] ++> Lit(value=op[0]);
        (be_s ++> Field(name="right"))[0] ++> Sym(name="expression");
        alts.append(be_p);
    }
    # multi-word comparison operators
    for words in [["not", "in"], ["is", "not"]] {
        bw_p = Prec(kind="PREC_LEFT", level=11);
        bw_s = (bw_p ++> Seq())[0];
        (bw_s ++> Field(name="left"))[0] ++> Sym(name="expression");
        ((bw_s ++> Field(name="operator"))[0] ++> Seq())[0] ++> [Lit(value=words[0]), Lit(value=words[1])];
        (bw_s ++> Field(name="right"))[0] ++> Sym(name="expression");
        alts.append(bw_p);
    }
    # right-associative: ** and walrus
    bpow = Prec(kind="PREC_RIGHT", level=18);
    bpow_s = (bpow ++> Seq())[0];
    (bpow_s ++> Field(name="left"))[0] ++> Sym(name="expression");
    (bpow_s ++> Field(name="operator"))[0] ++> Lit(value="**");
    (bpow_s ++> Field(name="right"))[0] ++> Sym(name="expression");
    alts.append(bpow);
    bwal = Prec(kind="PREC_RIGHT", level=3);
    bwal_s = (bwal ++> Seq())[0];
    (bwal_s ++> Field(name="left"))[0] ++> Sym(name="expression");
    (bwal_s ++> Field(name="operator"))[0] ++> Lit(value=":=");
    (bwal_s ++> Field(name="right"))[0] ++> Sym(name="expression");
    alts.append(bwal);
    be = ((g ++> Rule(name="binary_expression"))[0] ++> Choice())[0];
    be ++> alts;

    # Prefix operators. `|>` / `:>` are the prefix pipe-call forms
    # (jac.spec `pipe_call`), e.g. `x = :> uuid4()` -- distinct from their
    # binary (atomic-)pipe roles, disambiguated by the absence of a left operand.
    # NOTE: `**` is intentionally NOT a general prefix operator -- it only ever
    # appears as dict-spread (`{**x}`), call kwargs (`f(**x)`), or a `**param`,
    # each handled by its own rule. Treating it as a unary made `{**x}` match a
    # set element, so `{**base, "k": v}` mis-parsed as a set and broke at `:`.
    uops = [Lit(value=u) for u in ["not", "~", "-", "+", "*", "&", "|>", ":>"]];
    ue = ((g ++> Rule(name="unary_expression"))[0] ++> Prec(kind="PREC_RIGHT", level=19))[0];
    ue_s = (ue ++> Seq())[0];
    ((ue_s ++> Field(name="operator"))[0] ++> Choice())[0] ++> uops;
    (ue_s ++> Field(name="operand"))[0] ++> Sym(name="expression");

    te = ((g ++> Rule(name="ternary_expression"))[0] ++> Prec(kind="PREC_RIGHT", level=1))[0];
    te_s = (te ++> Seq())[0];
    (te_s ++> Field(name="consequence"))[0] ++> Sym(name="expression");
    te_s ++> Lit(value="if");
    (te_s ++> Field(name="condition"))[0] ++> Sym(name="expression");
    te_s ++> Lit(value="else");
    (te_s ++> Field(name="alternative"))[0] ++> Sym(name="expression");

    # flow/wait prefix and await/spawn/ref/unpack prefixes
    conc = ((g ++> Rule(name="concurrent_expression"))[0] ++> Prec(kind="PREC", level=2))[0];
    conc_s = (conc ++> Seq())[0];
    (conc_s ++> Choice())[0] ++> [Lit(value="flow"), Lit(value="wait")];
    conc_s ++> Sym(name="expression");

    # Lower precedence than ternary so the body greedily absorbs a trailing
    # `if/else` (`lambda: a if b else c` -> body is `(a if b else c)`).
    # jac.spec: `("(" func_params ")" | lambda_params)` -- params may be
    # parenthesized (`lambda (x: int) -> int { ... }`) or bare
    # (`lambda x: int : expr`).
    le = ((g ++> Rule(name="lambda_expression"))[0] ++> Prec(kind="PREC_RIGHT", level=-1))[0];
    le_s = (le ++> Seq())[0];
    le_s ++> Lit(value="lambda");
    le_params_opt = (le_s ++> Choice())[0];
    le_ret_opt = (le_s ++> Choice())[0];
    le_body = (le_s ++> Choice())[0];
    (le_params_opt ++> Choice())[0] ++> [Sym(name="parameter_list"), Sym(name="lambda_params")];
    le_params_opt ++> Blank();
    (le_ret_opt ++> Seq())[0] ++> [Lit(value="->"), Sym(name="expression")];
    le_ret_opt ++> Blank();
    (le_body ++> Seq())[0] ++> [Lit(value=":"), Sym(name="expression")];
    le_body ++> block();
    (g ++> Rule(name="lambda_params"))[0] ++> comma_sep1(Sym(name="param"));

    # ---- primary / atoms -------------------------------------------------
    prim = ((g ++> Rule(name="_primary_expression"))[0] ++> Choice())[0];
    prim ++> [
        Sym(name="_atom"),
        Sym(name="call_expression"),
        Sym(name="index_expression"),
        Sym(name="attribute_expression"),
        Sym(name="filter_expression"),
        Sym(name="await_expression"),
        Sym(name="spawn_expression"),
        Sym(name="edge_reference")
    ];

    # Object-spatial filter comprehension applied to a primary:
    # `nodes(?score > 5)` / `[-->][?:NodeType, val == 1]` (jac.spec
    # filter_compr_inner / filter_compr_bracket).
    fe = ((g ++> Rule(name="filter_expression"))[0] ++> Prec(kind="PREC_LEFT", level=28))[0];
    fe_s = (fe ++> Seq())[0];
    (fe_s ++> Field(name="object"))[0] ++> Sym(name="_primary_expression");
    fe_alt = (fe_s ++> Choice())[0];
    (fe_alt ++> Seq())[0] ++> [Lit(value="("), Sym(name="filter_compr"), Lit(value=")")];
    (fe_alt ++> Seq())[0] ++> [Lit(value="["), Sym(name="filter_compr"), Lit(value="]")];

    fc = ((g ++> Rule(name="filter_compr"))[0] ++> Seq())[0];
    fc ++> Lit(value="?");
    fc_type_opt = (fc ++> Choice())[0];
    fc_comma_opt = (fc ++> Choice())[0];
    fc_cs_opt = (fc ++> Choice())[0];
    (fc_type_opt ++> Seq())[0] ++> [Lit(value=":"), Sym(name="expression")];
    fc_type_opt ++> Blank();
    fc_comma_opt ++> [Lit(value=","), Blank()];
    fc_cs_opt ++> [comma_sep1(Sym(name="expression")), Blank()];

    atom = ((g ++> Rule(name="_atom"))[0] ++> Choice())[0];
    atom ++> [
        name_ref(),
        Sym(name="integer"),
        Sym(name="float"),
        Sym(name="string"),
        Sym(name="multistring"),
        Sym(name="bool"),
        Sym(name="null"),
        Sym(name="ellipsis"),
        Sym(name="builtin_type"),
        Sym(name="special_ref"),
        Sym(name="parenthesized_expression"),
        Sym(name="list"),
        Sym(name="dict"),
        Sym(name="set"),
        Sym(name="comprehension"),
        Sym(name="jsx_element"),
        Sym(name="fstring")
    ];

    # Implicit concatenation of adjacent string literals, which may mix plain
    # strings and f-strings (jac.spec multistring).
    mstr = ((g ++> Rule(name="multistring"))[0] ++> Prec(kind="PREC", level=2))[0];
    mstr_s = (mstr ++> Seq())[0];
    (mstr_s ++> Choice())[0] ++> [Sym(name="string"), Sym(name="fstring")];
    ((mstr_s ++> Rep1())[0] ++> Choice())[0] ++> [Sym(name="string"), Sym(name="fstring")];

    # f-strings: the start/content/end tokens come from the external scanner
    # (src/scanner.c); the grammar parses the embedded `{ expression }`
    # interpolations (with optional `!r`/`!s`/`!a` conversion and `:` format).
    fstr = ((g ++> Rule(name="fstring"))[0] ++> Seq())[0];
    fstr ++> Sym(name="fstring_start");
    ((fstr ++> Rep())[0] ++> Choice())[0] ++> [Sym(name="fstring_content"), Sym(name="fstring_interpolation")];
    fstr ++> Sym(name="fstring_end");

    fi = ((g ++> Rule(name="fstring_interpolation"))[0] ++> Seq())[0];
    fi ++> Lit(value="{");
    (fi ++> Field(name="expression"))[0] ++> Sym(name="expression");
    (fi ++> Choice())[0] ++> [Sym(name="fstring_conversion"), Blank()];
    (fi ++> Choice())[0] ++> [Sym(name="fstring_format"), Blank()];
    fi ++> Lit(value="}");

    fcv = ((g ++> Rule(name="fstring_conversion"))[0] ++> Tok())[0];
    fcv_s = (fcv ++> Seq())[0];
    fcv_s ++> Lit(value="!");
    (fcv_s ++> Choice())[0] ++> [Lit(value="r"), Lit(value="s"), Lit(value="a")];

    ff = ((g ++> Rule(name="fstring_format"))[0] ++> Seq())[0];
    ff ++> Lit(value=":");
    ((ff ++> Rep())[0] ++> Choice())[0] ++> [Sym(name="fstring_content"), Sym(name="fstring_interpolation")];

    pe = ((g ++> Rule(name="parenthesized_expression"))[0] ++> Seq())[0];
    pe ++> Lit(value="(");
    pe_inner_opt = (pe ++> Choice())[0];
    pe ++> Lit(value=")");
    pe_inner = (pe_inner_opt ++> Choice())[0];
    pe_inner_opt ++> Blank();
    (pe_inner ++> Seq())[0] ++> [Sym(name="expression"), Sym(name="comprehension_clauses")];   # `(x for x in xs if cond)`
    pe_tuple = (pe_inner ++> Seq())[0];
    pe_tuple ++> comma_sep1(Sym(name="expression"));
    (pe_tuple ++> Choice())[0] ++> [Lit(value=","), Blank()];

    ae = ((g ++> Rule(name="attribute_expression"))[0] ++> Prec(kind="PREC_LEFT", level=28))[0];
    ae_s = (ae ++> Seq())[0];
    (ae_s ++> Field(name="object"))[0] ++> Sym(name="_primary_expression");
    (ae_s ++> Choice())[0] ++> [Lit(value="."), Lit(value=".>"), Lit(value="<."), Lit(value="?.")];
    (ae_s ++> Field(name="attr"))[0] ++> name_ref();

    call = ((g ++> Rule(name="call_expression"))[0] ++> Prec(kind="PREC_LEFT", level=28))[0];
    call_s = (call ++> Seq())[0];
    (call_s ++> Field(name="function"))[0] ++> Sym(name="_primary_expression");
    call_s ++> Sym(name="argument_list");

    al = ((g ++> Rule(name="argument_list"))[0] ++> Seq())[0];
    al ++> Lit(value="(");
    al_cs_opt = (al ++> Choice())[0];
    al_trail = (al ++> Choice())[0];
    al ++> Lit(value=")");
    al_cs_opt ++> [comma_sep1(Sym(name="argument")), Blank()];
    al_trail ++> [Lit(value=","), Blank()];

    arg = ((g ++> Rule(name="argument"))[0] ++> Choice())[0];
    arg_kw = (arg ++> Seq())[0];
    (arg ++> Seq())[0] ++> [Lit(value="**"), Sym(name="expression")];
    (arg ++> Seq())[0] ++> [Lit(value="*"), Sym(name="expression")];
    arg_bare = (arg ++> Seq())[0];
    (arg_kw ++> Field(name="name"))[0] ++> name_ref();
    arg_kw ++> [Lit(value="="), Sym(name="expression")];
    arg_bare ++> Sym(name="expression");
    # bare expression, optionally a generator expression `f(x for x in y)`
    (arg_bare ++> Choice())[0] ++> [Sym(name="comprehension_clauses"), Blank()];

    ie = ((g ++> Rule(name="index_expression"))[0] ++> Prec(kind="PREC_LEFT", level=28))[0];
    ie_s = (ie ++> Seq())[0];
    (ie_s ++> Field(name="object"))[0] ++> Sym(name="_primary_expression");
    (ie_s ++> Choice())[0] ++> [Lit(value="?"), Blank()];
    ie_s ++> [Lit(value="["), Sym(name="slice"), Lit(value="]")];

    sl = ((g ++> Rule(name="slice"))[0] ++> Choice())[0];
    sl_full = (sl ++> Seq())[0];
    sl ++> comma_sep1(Sym(name="expression"));
    (sl_full ++> Choice())[0] ++> [Sym(name="expression"), Blank()];
    sl_full ++> Lit(value=":");
    (sl_full ++> Choice())[0] ++> [Sym(name="expression"), Blank()];
    sl_step_opt = (sl_full ++> Choice())[0];
    sl_step = (sl_step_opt ++> Seq())[0];
    sl_step_opt ++> Blank();
    sl_step ++> Lit(value=":");
    (sl_step ++> Choice())[0] ++> [Sym(name="expression"), Blank()];

    awa = ((g ++> Rule(name="await_expression"))[0] ++> Prec(kind="PREC", level=26))[0];
    awa_s = (awa ++> Seq())[0];
    awa_s ++> [Lit(value="await"), Sym(name="expression")];

    spw = ((g ++> Rule(name="spawn_expression"))[0] ++> Prec(kind="PREC_LEFT", level=23))[0];
    spw_s = (spw ++> Seq())[0];
    spw_s ++> [Sym(name="expression"), Lit(value="spawn"), Sym(name="expression")];
}

# ===========================================================================
# Collections & comprehensions
# ===========================================================================

def build_collections(g: Grammar) -> None {
    # list ::= "[" opt(comma_sep1(expr)) opt(",") "]"
    li = ((g ++> Rule(name="list"))[0] ++> Seq())[0];
    li ++> Lit(value="[");
    li_items = (li ++> Choice())[0];
    li_trail = (li ++> Choice())[0];
    li ++> Lit(value="]");
    li_items ++> [comma_sep1(Sym(name="expression")), Blank()];
    li_trail ++> [Lit(value=","), Blank()];

    # set ::= "{" comma_sep1(expr) opt(",") "}"
    se = ((g ++> Rule(name="set"))[0] ++> Seq())[0];
    se ++> [Lit(value="{"), comma_sep1(Sym(name="expression"))];
    se_trail = (se ++> Choice())[0];
    se ++> Lit(value="}");
    se_trail ++> [Lit(value=","), Blank()];

    # dict ::= "{" opt(comma_sep1(dict_entry)) opt(",") "}"
    di = ((g ++> Rule(name="dict"))[0] ++> Seq())[0];
    di ++> Lit(value="{");
    di_items = (di ++> Choice())[0];
    di_trail = (di ++> Choice())[0];
    di ++> Lit(value="}");
    di_items ++> [comma_sep1(Sym(name="dict_entry")), Blank()];
    di_trail ++> [Lit(value=","), Blank()];

    # dict_entry ::= "**" expr | key=expr ":" value=expr
    de = ((g ++> Rule(name="dict_entry"))[0] ++> Choice())[0];
    (de ++> Seq())[0] ++> [Lit(value="**"), Sym(name="expression")];
    de_kv = (de ++> Seq())[0];
    (de_kv ++> Field(name="key"))[0] ++> Sym(name="expression");
    de_kv ++> Lit(value=":");
    (de_kv ++> Field(name="value"))[0] ++> Sym(name="expression");

    # comprehension ::= list_comprehension | dict_comprehension | set_comprehension
    ((g ++> Rule(name="comprehension"))[0] ++> Choice())[0] ++> [Sym(name="list_comprehension"), Sym(name="dict_comprehension"), Sym(name="set_comprehension")];

    # list_comprehension ::= "[" expr comprehension_clauses "]"
    ((g ++> Rule(name="list_comprehension"))[0] ++> Seq())[0] ++> [Lit(value="["), Sym(name="expression"), Sym(name="comprehension_clauses"), Lit(value="]")];

    # set_comprehension ::= "{" expr comprehension_clauses "}"
    ((g ++> Rule(name="set_comprehension"))[0] ++> Seq())[0] ++> [Lit(value="{"), Sym(name="expression"), Sym(name="comprehension_clauses"), Lit(value="}")];

    # dict_comprehension ::= "{" expr ":" expr comprehension_clauses "}"
    ((g ++> Rule(name="dict_comprehension"))[0] ++> Seq())[0] ++> [Lit(value="{"), Sym(name="expression"), Lit(value=":"), Sym(name="expression"), Sym(name="comprehension_clauses"), Lit(value="}")];

    # jac.spec: comprehension_clauses ::= compr_clause+ where each clause is a
    # `for X in Y` followed by zero+ trailing `if`s. Clauses INTERLEAVE
    # (`for a in b if c for d in e`), so this is rep1 of (for + ifs), not "all
    # fors then all ifs".
    cc = ((g ++> Rule(name="comprehension_clauses"))[0] ++> Rep1())[0];
    cc_clause = (cc ++> Seq())[0];
    cc_clause ++> Sym(name="for_in_clause");
    (cc_clause ++> Rep())[0] ++> Sym(name="if_clause");

    # The target is a primary-expression list (jac.spec uses `atomic_chain`),
    # NOT a full expression -- a full expression would swallow the `in`
    # separator as a binary `in` comparison (`for (i in y)`). Comma-separated to
    # allow tuple targets `for k, v in ...`.
    # prec 2 (> ternary's 1) so a trailing `if` reduces the iterable and
    # attaches as a comprehension filter instead of starting an (else-less)
    # ternary on the iterable.
    fic_s = (((g ++> Rule(name="for_in_clause"))[0] ++> Prec(kind="PREC_RIGHT", level=2))[0] ++> Seq())[0];
    (fic_s ++> Choice())[0] ++> [Lit(value="async"), Blank()];
    fic_s ++> Lit(value="for");
    (fic_s ++> Field(name="left"))[0] ++> comma_sep1(Sym(name="_primary_expression"));
    fic_s ++> Lit(value="in");
    (fic_s ++> Field(name="right"))[0] ++> Sym(name="expression");

    # if_clause ::= "if" expr
    ((g ++> Rule(name="if_clause"))[0] ++> Seq())[0] ++> [Lit(value="if"), Sym(name="expression")];
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
    je = ((g ++> Rule(name="jsx_element"))[0] ++> Seq())[0];
    je ++> Lit(value="<");
    je_body = (je ++> Choice())[0];
    # fragment:  <> children </>
    je_frag = (je_body ++> Seq())[0];
    je_frag ++> Lit(value=">");
    (je_frag ++> Rep())[0] ++> Sym(name="jsx_child");
    je_frag ++> [Lit(value="<"), Lit(value="/"), Lit(value=">")];
    # named element
    je_named = (je_body ++> Seq())[0];
    (je_named ++> Field(name="name"))[0] ++> Sym(name="jsx_name");
    (je_named ++> Rep())[0] ++> Sym(name="jsx_attribute");
    je_close = (je_named ++> Choice())[0];
    (je_close ++> Seq())[0] ++> [Lit(value="/"), Lit(value=">")];                          # self-closing
    je_open = (je_close ++> Seq())[0];                                         # open ... close
    je_open ++> Lit(value=">");
    (je_open ++> Rep())[0] ++> Sym(name="jsx_child");
    je_open ++> [Lit(value="<"), Lit(value="/")];
    (je_open ++> Choice())[0] ++> [Sym(name="jsx_name"), Blank()];
    je_open ++> Lit(value=">");

    # Tag / attribute name: identifier, dotted member (`Foo.Bar`), or hyphenated
    # (`aria-label`); `@` is the raw-passthrough tag.
    jn = ((g ++> Rule(name="jsx_name"))[0] ++> Seq())[0];
    (jn ++> Choice())[0] ++> [Sym(name="identifier"), Lit(value="@")];
    jn_rest = (jn ++> Rep())[0];
    jn_part = (jn_rest ++> Seq())[0];
    (jn_part ++> Choice())[0] ++> [Lit(value="."), Lit(value="-")];
    jn_part ++> Sym(name="identifier");

    # jsx_attribute ::= name=jsx_name opt("=" value) | shorthand/spread
    ja = ((g ++> Rule(name="jsx_attribute"))[0] ++> Choice())[0];
    ja_attr = (ja ++> Seq())[0];
    # shorthand / spread:  {expr} | {...expr} | {**expr}. The `**expr` form
    # parses as a prefix unary expression; `...` (rest/spread) is an
    # explicit optional prefix.
    ja_spread = (ja ++> Seq())[0];
    (ja_attr ++> Field(name="name"))[0] ++> Sym(name="jsx_name");
    ja_eq_opt = (ja_attr ++> Choice())[0];
    ja_eq = (ja_eq_opt ++> Seq())[0];
    ja_eq_opt ++> Blank();
    ja_eq ++> Lit(value="=");
    ja_val_choice = ((ja_eq ++> Field(name="value"))[0] ++> Choice())[0];
    ja_val_choice ++> Sym(name="string");
    (ja_val_choice ++> Seq())[0] ++> [Lit(value="{"), Sym(name="expression"), Lit(value="}")];
    ja_spread ++> Lit(value="{");
    (ja_spread ++> Choice())[0] ++> [Lit(value="..."), Blank()];
    ja_spread ++> [Sym(name="expression"), Lit(value="}")];

    ((g ++> Rule(name="jsx_child"))[0] ++> Choice())[0] ++> [Sym(name="jsx_text"), Sym(name="jsx_element"), Sym(name="jsx_expression")];

    # An embedded `{...}` in JSX children: a control-flow view block
    # (`{ if cond { <jsx> } }`), a statement interpolation (`{ x; }`), or a
    # value interpolation (`{count}`), per the jac.spec jsx_child production.
    jx = ((g ++> Rule(name="jsx_expression"))[0] ++> Seq())[0];
    jx ++> Lit(value="{");
    jx_inner = (jx ++> Choice())[0];
    jx ++> Lit(value="}");
    jx_inner ++> Sym(name="jsx_control");
    (jx_inner ++> Choice())[0] ++> [Sym(name="expression"), Blank()];

    # Conditional / iterative rendering. Unlike ordinary statements, the bodies
    # are JSX view blocks: bare jsx_children (elements/text/`{expr}`), no `;`.
    jctl = ((g ++> Rule(name="jsx_control"))[0] ++> Choice())[0];
    jctl_if = (jctl ++> Seq())[0];
    jctl_for = (jctl ++> Seq())[0];
    jctl_while = (jctl ++> Seq())[0];
    jctl_if ++> Lit(value="if");
    (jctl_if ++> Field(name="condition"))[0] ++> Sym(name="expression");
    jctl_if ++> Sym(name="jsx_view_block");
    jctl_if_elifs = (jctl_if ++> Rep())[0];
    jctl_if_else = (jctl_if ++> Choice())[0];
    (jctl_if_elifs ++> Seq())[0] ++> [Lit(value="elif"), Sym(name="expression"), Sym(name="jsx_view_block")];
    (jctl_if_else ++> Seq())[0] ++> [Lit(value="else"), Sym(name="jsx_view_block")];
    jctl_if_else ++> Blank();
    (jctl_for ++> Choice())[0] ++> [Lit(value="async"), Blank()];
    jctl_for ++> Lit(value="for");
    (jctl_for ++> Field(name="left"))[0] ++> comma_sep1(Sym(name="_primary_expression"));
    jctl_for ++> Lit(value="in");
    (jctl_for ++> Field(name="right"))[0] ++> Sym(name="expression");
    jctl_for ++> Sym(name="jsx_view_block");
    jctl_while ++> Lit(value="while");
    (jctl_while ++> Field(name="condition"))[0] ++> Sym(name="expression");
    jctl_while ++> Sym(name="jsx_view_block");

    jvb = ((g ++> Rule(name="jsx_view_block"))[0] ++> Seq())[0];
    jvb ++> Lit(value="{");
    (jvb ++> Rep())[0] ++> Sym(name="jsx_child");
    jvb ++> Lit(value="}");
}

def build_edges(g: Grammar) -> None {
    # connect_expression ::= precl(20, left=expression op=connect_op right=expression)
    ce = ((g ++> Rule(name="connect_expression"))[0] ++> Prec(kind="PREC_LEFT", level=20))[0];
    ces = (ce ++> Seq())[0];
    (ces ++> Field(name="left"))[0]  ++> Sym(name="expression");
    (ces ++> Field(name="op"))[0]    ++> Sym(name="connect_op");
    (ces ++> Field(name="right"))[0] ++> Sym(name="expression");

    # connect_op ::= "++>" | "<++" | "<++>" | typed-fwd | typed-back | "del" edge_op
    co = ((g ++> Rule(name="connect_op"))[0] ++> Choice())[0];
    co ++> [Lit(value="++>"), Lit(value="<++"), Lit(value="<++>")];
    co_a = (co ++> Seq())[0];
    co_b = (co ++> Seq())[0];
    # disconnect: `a del --> b` (jac.spec connect_op `"del" edge_op_ref`).
    (co ++> Seq())[0] ++> [Lit(value="del"), Sym(name="edge_op")];
    co_a ++> [Lit(value="+>:"), Sym(name="expression")];
    co_a_opt = (co_a ++> Choice())[0];
    co_a ++> Lit(value=":+>");
    (co_a_opt ++> Seq())[0] ++> [Lit(value=":"), Sym(name="expression")];
    co_a_opt ++> Blank();
    co_b ++> [Lit(value="<+:"), Sym(name="expression")];
    co_b_opt = (co_b ++> Choice())[0];
    co_b ++> Lit(value=":<+");
    (co_b_opt ++> Seq())[0] ++> [Lit(value=":"), Sym(name="expression")];
    co_b_opt ++> Blank();

    # edge_reference ::= "[" opt(edge|node) opt(expr) rep1(edge_op opt(filter)) opt(filter) "]"
    er = ((g ++> Rule(name="edge_reference"))[0] ++> Seq())[0];
    er ++> Lit(value="[");
    er_en_opt = (er ++> Choice())[0];
    er_e_opt = (er ++> Choice())[0];
    er_hops = (er ++> Rep1())[0];
    er_tf = (er ++> Choice())[0];
    er ++> Lit(value="]");
    (er_en_opt ++> Choice())[0] ++> [Lit(value="edge"), Lit(value="node")];
    er_en_opt ++> Blank();
    er_e_opt ++> [Sym(name="expression"), Blank()];
    er_hop = (er_hops ++> Seq())[0];
    er_hop ++> Sym(name="edge_op");
    (er_hop ++> Choice())[0] ++> [Sym(name="edge_filter"), Blank()];
    er_tf ++> [Sym(name="edge_filter"), Blank()];

    # edge_op ::= "-->" | "<--" | "<-->" | typed-fwd | typed-back
    eo = ((g ++> Rule(name="edge_op"))[0] ++> Choice())[0];
    eo ++> [Lit(value="-->"), Lit(value="<--"), Lit(value="<-->")];
    eo_a = (eo ++> Seq())[0];
    eo_b = (eo ++> Seq())[0];
    eo_a ++> Lit(value="->:");
    (eo_a ++> Choice())[0] ++> [name_ref(), Blank()];
    eo_a_colon_opt = (eo_a ++> Choice())[0];
    eo_a ++> Lit(value=":->");
    eo_a_colon = (eo_a_colon_opt ++> Seq())[0];
    eo_a_colon_opt ++> Blank();
    eo_a_colon ++> Lit(value=":");
    (eo_a_colon ++> Choice())[0] ++> [comma_sep1(Sym(name="expression")), Blank()];
    eo_b ++> Lit(value="<-:");
    (eo_b ++> Choice())[0] ++> [name_ref(), Blank()];
    eo_b_colon_opt = (eo_b ++> Choice())[0];
    eo_b ++> Lit(value=":<-");
    eo_b_colon = (eo_b_colon_opt ++> Seq())[0];
    eo_b_colon_opt ++> Blank();
    eo_b_colon ++> Lit(value=":");
    (eo_b_colon ++> Choice())[0] ++> [comma_sep1(Sym(name="expression")), Blank()];

    # edge_filter ::= "[" opt("?" opt(":" expr)) opt(comma_sep1(expr)) "]"
    ef = ((g ++> Rule(name="edge_filter"))[0] ++> Seq())[0];
    ef ++> Lit(value="[");
    ef_q_opt = (ef ++> Choice())[0];
    ef_cs_opt = (ef ++> Choice())[0];
    ef ++> Lit(value="]");
    ef_q = (ef_q_opt ++> Seq())[0];
    ef_q_opt ++> Blank();
    ef_q ++> Lit(value="?");
    ef_q_in_opt = (ef_q ++> Choice())[0];
    (ef_q_in_opt ++> Seq())[0] ++> [Lit(value=":"), Sym(name="expression")];
    ef_q_in_opt ++> Blank();
    ef_cs_opt ++> [comma_sep1(Sym(name="expression")), Blank()];
}

# ===========================================================================
# Statements
# ===========================================================================

def build_stmts(g: Grammar) -> None {
    # Every statement self-terminates (own `;`, or ends in a block), so the
    # block body is just a sequence of statements -- no per-statement opt(";"),
    # which would otherwise fight each statement's own terminator.
    bb = ((g ++> Rule(name="block_body"))[0] ++> Rep1())[0];
    bb ++> Sym(name="statement");
    stmt = ((g ++> Rule(name="statement"))[0] ++> Choice())[0];
    stmt ++> [
        Sym(name="if_statement"),
        Sym(name="while_statement"),
        Sym(name="for_statement"),
        Sym(name="try_statement"),
        Sym(name="with_statement"),
        Sym(name="match_statement"),
        Sym(name="switch_statement"),
        Sym(name="return_statement"),
        Sym(name="yield_statement"),
        Sym(name="raise_statement"),
        Sym(name="assert_statement"),
        Sym(name="delete_statement"),
        Sym(name="control_statement"),
        Sym(name="visit_statement"),
        Sym(name="report_statement"),
        Sym(name="disengage_statement"),
        Sym(name="global_statement"),
        Sym(name="nonlocal_statement"),
        Sym(name="import_statement"),
        Sym(name="global_var"),
        Sym(name="has_statement"),
        Sym(name="ability"),
        Sym(name="archetype"),
        Sym(name="pyinline"),
        Sym(name="expression_statement"),
        Sym(name="empty_statement")
    ];
    # A lone `;` (e.g. an empty `else { ; }` / `except E { ; }` body).
    (g ++> Rule(name="empty_statement"))[0] ++> Lit(value=";");
    # A single rule covering expression / assignment / augmented-assignment.
    # Parsing the leading expression once, then an OPTIONAL assignment tail,
    # avoids a GLR conflict over the whole expression grammar (which exploded
    # the parse table). The next token (`=`/`:`/augop vs `;`) decides the tail.
    augops = [Lit(value=a) for a in ["+=", "-=", "*=", "/=", "//=", "%=", "**=", "@=",
              "&=", "|=", "^=", "<<=", ">>="]];
    es = ((g ++> Rule(name="expression_statement"))[0] ++> Seq())[0];
    (es ++> Field(name="left"))[0] ++> Sym(name="expression");
    es_tail_opt = (es ++> Choice())[0];
    es ++> Lit(value=";");
    es_tail = (es_tail_opt ++> Choice())[0];
    es_tail_opt ++> Blank();
    es_ann = (es_tail ++> Seq())[0];   # `x: T`, `x: T = v` -- type annotation + value(s)
    es_asn = (es_tail ++> Rep1())[0];  # `x = v`, `x = v = w` -- chained assignment
    es_aug = (es_tail ++> Seq())[0];   # `x += v` -- augmented assignment
    es_ann ++> Lit(value=":");
    (es_ann ++> Field(name="type"))[0] ++> Sym(name="expression");
    es_ann_vals_opt = (es_ann ++> Choice())[0];
    es_ann_vals = (es_ann_vals_opt ++> Rep1())[0];
    es_ann_vals_opt ++> Blank();
    es_ann_eq = (es_ann_vals ++> Seq())[0];
    es_ann_eq ++> Lit(value="=");
    (es_ann_eq ++> Field(name="right"))[0] ++> Sym(name="expression");
    es_asn_eq = (es_asn ++> Seq())[0];
    es_asn_eq ++> Lit(value="=");
    (es_asn_eq ++> Field(name="right"))[0] ++> Sym(name="expression");
    es_aug_op = ((es_aug ++> Field(name="operator"))[0] ++> Choice())[0];
    es_aug_op ++> augops;
    (es_aug ++> Field(name="right"))[0] ++> Sym(name="expression");

    # if_statement ::= "if" condition=expr block opt(elif_clause | else_clause)
    if_s = ((g ++> Rule(name="if_statement"))[0] ++> Seq())[0];
    if_s ++> Lit(value="if");
    (if_s ++> Field(name="condition"))[0] ++> Sym(name="expression");
    if_s ++> block();
    if_cont_opt = (if_s ++> Choice())[0];
    (if_cont_opt ++> Choice())[0] ++> [Sym(name="elif_clause"), Sym(name="else_clause")];
    if_cont_opt ++> Blank();

    elif_s = ((g ++> Rule(name="elif_clause"))[0] ++> Seq())[0];
    elif_s ++> Lit(value="elif");
    (elif_s ++> Field(name="condition"))[0] ++> Sym(name="expression");
    elif_s ++> block();
    elif_cont_opt = (elif_s ++> Choice())[0];
    (elif_cont_opt ++> Choice())[0] ++> [Sym(name="elif_clause"), Sym(name="else_clause")];
    elif_cont_opt ++> Blank();

    else_s = ((g ++> Rule(name="else_clause"))[0] ++> Seq())[0];
    else_s ++> [Lit(value="else"), block()];

    wh = ((g ++> Rule(name="while_statement"))[0] ++> Seq())[0];
    wh ++> Lit(value="while");
    (wh ++> Field(name="condition"))[0] ++> Sym(name="expression");
    wh ++> block();
    (wh ++> Choice())[0] ++> [Sym(name="else_clause"), Blank()];

    # The target is a primary-expression list, not a full expression, so the
    # `in` separator isn't swallowed as a binary `in` comparison (which broke
    # iterables like `node.bases or []`). Comma-separated for `for k, v in ...`.
    for_s = ((g ++> Rule(name="for_statement"))[0] ++> Seq())[0];
    (for_s ++> Choice())[0] ++> [Lit(value="async"), Blank()];
    for_s ++> Lit(value="for");
    (for_s ++> Field(name="target"))[0] ++> comma_sep1(Sym(name="_primary_expression"));
    for_head = (for_s ++> Choice())[0];
    for_s ++> block();
    (for_s ++> Choice())[0] ++> [Sym(name="else_clause"), Blank()];
    for_in = (for_head ++> Seq())[0];
    for_in ++> Lit(value="in");
    (for_in ++> Field(name="iter"))[0] ++> Sym(name="expression");
    (for_head ++> Seq())[0] ++> [Lit(value="="), Sym(name="expression"), Lit(value="to"), Sym(name="expression"),
                                 Lit(value="by"), Sym(name="expression")];

    # try_statement ::= "try" block opt("awaiting" block) rep(except) opt(else) opt("finally" block)
    try_s = ((g ++> Rule(name="try_statement"))[0] ++> Seq())[0];
    try_s ++> [Lit(value="try"), block()];
    try_await_opt = (try_s ++> Choice())[0];
    try_excepts = (try_s ++> Rep())[0];
    try_else = (try_s ++> Choice())[0];
    try_finally_opt = (try_s ++> Choice())[0];
    (try_await_opt ++> Seq())[0] ++> [Lit(value="awaiting"), block()];
    try_await_opt ++> Blank();
    try_excepts ++> Sym(name="except_clause");
    try_else ++> [Sym(name="else_clause"), Blank()];
    (try_finally_opt ++> Seq())[0] ++> [Lit(value="finally"), block()];
    try_finally_opt ++> Blank();

    exc = ((g ++> Rule(name="except_clause"))[0] ++> Seq())[0];
    exc ++> [Lit(value="except"), Sym(name="expression")];
    exc_as_opt = (exc ++> Choice())[0];
    exc ++> block();
    (exc_as_opt ++> Seq())[0] ++> [Lit(value="as"), name_ref()];
    exc_as_opt ++> Blank();

    with_item = Seq();
    with_item ++> Sym(name="expression");
    with_as_opt = (with_item ++> Choice())[0];
    (with_as_opt ++> Seq())[0] ++> [Lit(value="as"), Sym(name="expression")];
    with_as_opt ++> Blank();
    with_s = ((g ++> Rule(name="with_statement"))[0] ++> Seq())[0];
    (with_s ++> Choice())[0] ++> [Lit(value="async"), Blank()];
    with_s ++> [Lit(value="with"), comma_sep1(with_item)];
    with_s ++> block();

    ret = ((g ++> Rule(name="return_statement"))[0] ++> Seq())[0];
    ret ++> Lit(value="return");
    (ret ++> Choice())[0] ++> [Sym(name="expression"), Blank()];
    ret ++> Lit(value=";");

    yld = ((g ++> Rule(name="yield_statement"))[0] ++> Seq())[0];
    yld ++> Lit(value="yield");
    (yld ++> Choice())[0] ++> [Lit(value="from"), Blank()];
    (yld ++> Choice())[0] ++> [Sym(name="expression"), Blank()];
    yld ++> Lit(value=";");

    rse = ((g ++> Rule(name="raise_statement"))[0] ++> Seq())[0];
    rse ++> Lit(value="raise");
    (rse ++> Choice())[0] ++> [Sym(name="expression"), Blank()];
    rse_from_opt = (rse ++> Choice())[0];
    rse ++> Lit(value=";");
    (rse_from_opt ++> Seq())[0] ++> [Lit(value="from"), Sym(name="expression")];
    rse_from_opt ++> Blank();

    asrt = ((g ++> Rule(name="assert_statement"))[0] ++> Seq())[0];
    asrt ++> [Lit(value="assert"), Sym(name="expression")];
    asrt_msg_opt = (asrt ++> Choice())[0];
    asrt ++> Lit(value=";");
    (asrt_msg_opt ++> Seq())[0] ++> [Lit(value=","), Sym(name="expression")];
    asrt_msg_opt ++> Blank();

    del_s = ((g ++> Rule(name="delete_statement"))[0] ++> Seq())[0];
    del_s ++> [Lit(value="del"), Sym(name="expression"), Lit(value=";")];

    ctrl = ((g ++> Rule(name="control_statement"))[0] ++> Seq())[0];
    (ctrl ++> Choice())[0] ++> [Lit(value="break"), Lit(value="continue"), Lit(value="skip")];
    ctrl ++> Lit(value=";");

    dis = ((g ++> Rule(name="disengage_statement"))[0] ++> Seq())[0];
    dis ++> [Lit(value="disengage"), Lit(value=";")];

    # prec.right so the optional trailing `;` is consumed here rather than left
    # to stand alone as an empty_statement.
    vis = ((g ++> Rule(name="visit_statement"))[0] ++> Prec(kind="PREC_RIGHT", level=1))[0];
    vis_s = (vis ++> Seq())[0];
    vis_s ++> Lit(value="visit");
    vis_label_opt = (vis_s ++> Choice())[0];
    vis_s ++> Sym(name="expression");
    vis_tail_opt = (vis_s ++> Choice())[0];
    (vis_label_opt ++> Seq())[0] ++> [Lit(value=":"), Sym(name="expression"), Lit(value=":")];
    vis_label_opt ++> Blank();
    (vis_tail_opt ++> Choice())[0] ++> [Sym(name="else_clause"), Lit(value=";")];
    vis_tail_opt ++> Blank();

    rep_s = ((g ++> Rule(name="report_statement"))[0] ++> Seq())[0];
    rep_s ++> [Lit(value="report"), Sym(name="expression"), Lit(value=";")];

    glob_s = ((g ++> Rule(name="global_statement"))[0] ++> Seq())[0];
    glob_s ++> [Lit(value="global"), comma_sep1(name_ref()), Lit(value=";")];

    nonlocal_s = ((g ++> Rule(name="nonlocal_statement"))[0] ++> Seq())[0];
    nonlocal_s ++> [Lit(value="nonlocal"), comma_sep1(name_ref()), Lit(value=";")];
}

# ===========================================================================
# Patterns (match / switch)
# ===========================================================================

def build_patterns(g: Grammar) -> None {
    # match_statement ::= "match" expr "{" rep(match_case) "}"
    ms = ((g ++> Rule(name="match_statement"))[0] ++> Seq())[0];
    ms ++> [Lit(value="match"), Sym(name="expression"), Lit(value="{")];
    (ms ++> Rep())[0] ++> Sym(name="match_case");
    ms ++> Lit(value="}");

    # match_case ::= "case" pattern opt("if" expr) ":" rep(statement)
    mc = ((g ++> Rule(name="match_case"))[0] ++> Seq())[0];
    mc ++> [Lit(value="case"), Sym(name="pattern")];
    mc_guard_opt = (mc ++> Choice())[0];
    mc ++> Lit(value=":");
    (mc ++> Rep())[0] ++> Sym(name="statement");
    (mc_guard_opt ++> Seq())[0] ++> [Lit(value="if"), Sym(name="expression")];
    mc_guard_opt ++> Blank();

    # pattern ::= or_pattern opt("as" name)
    ptn = ((g ++> Rule(name="pattern"))[0] ++> Seq())[0];
    ptn ++> Sym(name="or_pattern");
    ptn_as_opt = (ptn ++> Choice())[0];
    (ptn_as_opt ++> Seq())[0] ++> [Lit(value="as"), name_ref()];
    ptn_as_opt ++> Blank();

    # or_pattern ::= closed_pattern rep("|" closed_pattern)
    op = ((g ++> Rule(name="or_pattern"))[0] ++> Seq())[0];
    op ++> Sym(name="closed_pattern");
    op_rest = (op ++> Rep())[0];
    (op_rest ++> Seq())[0] ++> [Lit(value="|"), Sym(name="closed_pattern")];

    cp = ((g ++> Rule(name="closed_pattern"))[0] ++> Choice())[0];
    cp ++> [Sym(name="bool"), Sym(name="null"), Sym(name="integer"), Sym(name="float"), Sym(name="string"),
            Sym(name="sequence_pattern"), Sym(name="mapping_pattern"), Sym(name="class_pattern"),
            Sym(name="capture_pattern")];

    # Use a dotted name (not a full `expression`) so patterns don't overlap the
    # expression grammar (which collided with `atom`).
    dpn = ((g ++> Rule(name="dotted_pattern_name"))[0] ++> Seq())[0];
    dpn ++> name_ref();
    dpn_rest = (dpn ++> Rep())[0];
    (dpn_rest ++> Seq())[0] ++> [Lit(value="."), name_ref()];

    (g ++> Rule(name="capture_pattern"))[0] ++> Sym(name="dotted_pattern_name");

    # sequence_pattern ::= "[" comma_sep( "*" name | pattern ) opt(",") "]"
    seqp = ((g ++> Rule(name="sequence_pattern"))[0] ++> Seq())[0];
    seqp ++> Lit(value="[");
    seqp_elem = Choice();
    (seqp_elem ++> Seq())[0] ++> [Lit(value="*"), name_ref()];
    seqp_elem ++> Sym(name="pattern");
    seqp ++> comma_sep(seqp_elem);
    seqp_trail = (seqp ++> Choice())[0];
    seqp ++> Lit(value="]");
    seqp_trail ++> [Lit(value=","), Blank()];

    # mapping_pattern ::= "{" comma_sep( "**" name | key ":" pattern ) opt(",") "}"
    mp = ((g ++> Rule(name="mapping_pattern"))[0] ++> Seq())[0];
    mp ++> Lit(value="{");
    mp_elem = Choice();
    (mp_elem ++> Seq())[0] ++> [Lit(value="**"), name_ref()];
    mp_kv = (mp_elem ++> Seq())[0];
    (mp_kv ++> Choice())[0] ++> [Sym(name="integer"), Sym(name="float"), Sym(name="string"), Sym(name="dotted_pattern_name")];
    mp_kv ++> [Lit(value=":"), Sym(name="pattern")];
    mp ++> comma_sep(mp_elem);
    mp_trail = (mp ++> Choice())[0];
    mp ++> Lit(value="}");
    mp_trail ++> [Lit(value=","), Blank()];

    # class_pattern ::= dotted_pattern_name "(" comma_sep( name "=" pattern | pattern ) opt(",") ")"
    clp = ((g ++> Rule(name="class_pattern"))[0] ++> Seq())[0];
    clp ++> [Sym(name="dotted_pattern_name"), Lit(value="(")];
    clp_elem = Choice();
    (clp_elem ++> Seq())[0] ++> [name_ref(), Lit(value="="), Sym(name="pattern")];
    clp_elem ++> Sym(name="pattern");
    clp ++> comma_sep(clp_elem);
    clp_trail = (clp ++> Choice())[0];
    clp ++> Lit(value=")");
    clp_trail ++> [Lit(value=","), Blank()];

    sw = ((g ++> Rule(name="switch_statement"))[0] ++> Seq())[0];
    sw ++> [Lit(value="switch"), Sym(name="expression"), Lit(value="{")];
    (sw ++> Rep())[0] ++> Sym(name="switch_case");
    sw ++> Lit(value="}");

    # switch_case ::= ("default" | "case" pattern) ":" rep(statement)
    swc = ((g ++> Rule(name="switch_case"))[0] ++> Seq())[0];
    swc_head = (swc ++> Choice())[0];
    swc ++> Lit(value=":");
    (swc ++> Rep())[0] ++> Sym(name="statement");
    swc_head ++> Lit(value="default");
    (swc_head ++> Seq())[0] ++> [Lit(value="case"), Sym(name="pattern")];
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
    dl = ((g ++> Rule(name="decorator_list"))[0] ++> Rep1())[0];
    (dl ++> Seq())[0] ++> [Lit(value="@"), Sym(name="expression")];

    (g ++> Rule(name="type_annotation"))[0] ++> Sym(name="expression");

    # param ::= opt("*"|"**") (name|special_ref) opt(":" type) opt("=" expr)
    param = ((g ++> Rule(name="param"))[0] ++> Seq())[0];
    param_star_opt = (param ++> Choice())[0];
    (param_star_opt ++> Choice())[0] ++> [Lit(value="*"), Lit(value="**")];
    param_star_opt ++> Blank();
    (param ++> Choice())[0] ++> [name_ref(), Sym(name="special_ref")];
    param_type_opt = (param ++> Choice())[0];
    param_def_opt = (param ++> Choice())[0];
    (param_type_opt ++> Seq())[0] ++> [Lit(value=":"), Sym(name="type_annotation")];
    param_type_opt ++> Blank();
    (param_def_opt ++> Seq())[0] ++> [Lit(value="="), Sym(name="expression")];
    param_def_opt ++> Blank();

    pl = ((g ++> Rule(name="parameter_list"))[0] ++> Seq())[0];
    pl ++> Lit(value="(");
    pl_elem = Choice();
    pl_elem ++> [Lit(value="*"), Lit(value="/"), Sym(name="param")];
    pl ++> comma_sep(pl_elem);
    pl_trail = (pl ++> Choice())[0];
    pl ++> Lit(value=")");
    pl_trail ++> [Lit(value=","), Blank()];

    # func_signature ::= parameter_list opt("->" return_type) | "->" return_type
    fs = ((g ++> Rule(name="func_signature"))[0] ++> Choice())[0];
    fs_a = (fs ++> Seq())[0];
    fs_b = (fs ++> Seq())[0];
    fs_a ++> Sym(name="parameter_list");
    fs_arrow1_opt = (fs_a ++> Choice())[0];
    fs_arrow1 = (fs_arrow1_opt ++> Seq())[0];
    fs_arrow1_opt ++> Blank();
    fs_arrow1 ++> Lit(value="->");
    (fs_arrow1 ++> Field(name="return_type"))[0] ++> Sym(name="type_annotation");
    fs_b ++> Lit(value="->");
    (fs_b ++> Field(name="return_type"))[0] ++> Sym(name="type_annotation");

    # archetype ::= decorators opt("async") kind=... access_tag name=... opt(type_params)
    #               opt("(" bases ")") ( "{" members "}" | ";" )
    arch = ((g ++> Rule(name="archetype"))[0] ++> Seq())[0];
    arch ++> decorators();
    (arch ++> Choice())[0] ++> [Lit(value="async"), Blank()];
    ((arch ++> Field(name="kind"))[0] ++> Choice())[0] ++> [Lit(value="obj"), Lit(value="node"), Lit(value="edge"), Lit(value="walker"), Lit(value="class")];
    arch ++> access_tag();
    (arch ++> Field(name="name"))[0] ++> name_ref();
    (arch ++> Choice())[0] ++> [Sym(name="type_params"), Blank()];
    arch_bases_opt = (arch ++> Choice())[0];
    arch_body = (arch ++> Choice())[0];
    arch_bases = (arch_bases_opt ++> Seq())[0];
    arch_bases_opt ++> Blank();
    arch_bases ++> Lit(value="(");
    (arch_bases ++> Choice())[0] ++> [comma_sep1(Sym(name="expression")), Blank()];
    arch_bases ++> Lit(value=")");
    arch_block = (arch_body ++> Seq())[0];
    arch_body ++> Lit(value=";");
    arch_block ++> Lit(value="{");
    (arch_block ++> Rep())[0] ++> Sym(name="archetype_member");
    arch_block ++> Lit(value="}");

    am = ((g ++> Rule(name="archetype_member"))[0] ++> Choice())[0];
    am ++> [Sym(name="has_statement"), Sym(name="ability"), Sym(name="archetype"),
            Sym(name="enum"), Sym(name="impl"), Sym(name="with_entry")];
    am_str = (am ++> Seq())[0];
    am_str ++> Sym(name="string");
    (am_str ++> Choice())[0] ++> [Lit(value=";"), Blank()];

    we = ((g ++> Rule(name="with_entry"))[0] ++> Seq())[0];
    we ++> Lit(value="with");
    we_ee_opt = (we ++> Choice())[0];
    we ++> block();
    (we_ee_opt ++> Choice())[0] ++> [Lit(value="entry"), Lit(value="exit")];
    we_ee_opt ++> Blank();

    # ability ::= decorators opt("override") opt("static") opt("async") kind=(def|can)
    #             access_tag opt(name) opt(type_params) opt(event_clause|func_signature)
    #             ( block | opt("abs") ";" | "by" expr ";" )
    ab = ((g ++> Rule(name="ability"))[0] ++> Seq())[0];
    ab ++> decorators();
    (ab ++> Choice())[0] ++> [Lit(value="override"), Blank()];
    (ab ++> Choice())[0] ++> [Lit(value="static"), Blank()];
    (ab ++> Choice())[0] ++> [Lit(value="async"), Blank()];
    ((ab ++> Field(name="kind"))[0] ++> Choice())[0] ++> [Lit(value="def"), Lit(value="can")];
    ab ++> access_tag();
    ab_name_opt = (ab ++> Choice())[0];
    (ab ++> Choice())[0] ++> [Sym(name="type_params"), Blank()];
    ab_sig_opt = (ab ++> Choice())[0];
    ab_body = (ab ++> Choice())[0];
    (ab_name_opt ++> Field(name="name"))[0] ++> name_ref();
    ab_name_opt ++> Blank();
    (ab_sig_opt ++> Choice())[0] ++> [Sym(name="event_clause"), Sym(name="func_signature")];
    ab_sig_opt ++> Blank();
    ab_body ++> block();
    ab_decl = (ab_body ++> Seq())[0];
    (ab_body ++> Seq())[0] ++> [Lit(value="by"), Sym(name="expression"), Lit(value=";")];
    (ab_decl ++> Choice())[0] ++> [Lit(value="abs"), Blank()];
    ab_decl ++> Lit(value=";");

    # Ability event signature: `with <NodeType> entry|exit` (object-spatial
    # dispatch), e.g. `can create with Root entry { ... }`. The trailing
    # entry/exit keyword can't be part of the expression, so it is consumed
    # explicitly after it.
    ec = ((g ++> Rule(name="event_clause"))[0] ++> Seq())[0];
    ec ++> [Lit(value="with"), Sym(name="expression")];
    ec_ee_opt = (ec ++> Choice())[0];
    (ec_ee_opt ++> Choice())[0] ++> [Lit(value="entry"), Lit(value="exit")];
    ec_ee_opt ++> Blank();

    # prec.right so the optional trailing `;` is consumed here; an accessor-block
    # `has` self-terminates (ends in `}`) so the `;` is optional, like other
    # block-bodied constructs.
    hs = ((g ++> Rule(name="has_statement"))[0] ++> Prec(kind="PREC_RIGHT", level=1))[0];
    hs_s = (hs ++> Seq())[0];
    (hs_s ++> Choice())[0] ++> [Lit(value="static"), Blank()];
    hs_s ++> [Lit(value="has"), access_tag(), comma_sep1(Sym(name="has_var"))];
    (hs_s ++> Choice())[0] ++> [Lit(value=";"), Blank()];

    # prec.right so a following `{` attaches as this field's accessor_block
    # rather than reducing the has_var early.
    hv = ((g ++> Rule(name="has_var"))[0] ++> Prec(kind="PREC_RIGHT", level=1))[0];
    hv_s = (hv ++> Seq())[0];
    (hv_s ++> Field(name="name"))[0] ++> name_ref();
    hv_s ++> Lit(value=":");
    (hv_s ++> Field(name="type"))[0] ++> Sym(name="type_annotation");
    hv_init_opt = (hv_s ++> Choice())[0];
    (hv_s ++> Choice())[0] ++> [Sym(name="accessor_block"), Blank()];
    hv_init = (hv_init_opt ++> Choice())[0];
    hv_init_opt ++> Blank();
    (hv_init ++> Seq())[0] ++> [Lit(value="="), Sym(name="expression")];
    (hv_init ++> Seq())[0] ++> [Lit(value="by"), Lit(value="postinit")];

    # Property accessors on a `has` field: `{ getter; setter(value: T); }`.
    acb = ((g ++> Rule(name="accessor_block"))[0] ++> Seq())[0];
    acb ++> Lit(value="{");
    (acb ++> Rep())[0] ++> Sym(name="accessor");
    acb ++> Lit(value="}");

    acc = ((g ++> Rule(name="accessor"))[0] ++> Seq())[0];
    (acc ++> Field(name="name"))[0] ++> name_ref();
    (acc ++> Choice())[0] ++> [Sym(name="parameter_list"), Blank()];
    acc_arrow_opt = (acc ++> Choice())[0];
    acc_body = (acc ++> Choice())[0];
    acc_arrow = (acc_arrow_opt ++> Seq())[0];
    acc_arrow_opt ++> Blank();
    acc_arrow ++> Lit(value="->");
    (acc_arrow ++> Field(name="return_type"))[0] ++> Sym(name="type_annotation");
    acc_body ++> block();
    acc_body ++> Lit(value=";");

    # enum ::= decorators "enum" access_tag name opt(base) ( "{" members opt(",") "}" | ";" )
    # base class: either `: Base` or `(Base, ...)` (jac.spec).
    en = ((g ++> Rule(name="enum"))[0] ++> Seq())[0];
    en ++> [decorators(), Lit(value="enum"), access_tag()];
    (en ++> Field(name="name"))[0] ++> name_ref();
    en_base_opt = (en ++> Choice())[0];
    en_body = (en ++> Choice())[0];
    en_base = (en_base_opt ++> Choice())[0];
    en_base_opt ++> Blank();
    (en_base ++> Seq())[0] ++> [Lit(value=":"), Sym(name="expression")];
    en_base_paren = (en_base ++> Seq())[0];
    en_base_paren ++> Lit(value="(");
    (en_base_paren ++> Choice())[0] ++> [comma_sep1(Sym(name="expression")), Blank()];
    en_base_paren ++> Lit(value=")");
    en_block = (en_body ++> Seq())[0];
    en_body ++> Lit(value=";");
    en_block ++> Lit(value="{");
    en_block ++> comma_sep(Sym(name="enum_member"));
    (en_block ++> Choice())[0] ++> [Lit(value=","), Blank()];
    en_block ++> Lit(value="}");

    enm = ((g ++> Rule(name="enum_member"))[0] ++> Seq())[0];
    enm ++> name_ref();
    enm_val_opt = (enm ++> Choice())[0];
    (enm_val_opt ++> Seq())[0] ++> [Lit(value="="), Sym(name="expression")];
    enm_val_opt ++> Blank();

    test_s = ((g ++> Rule(name="test"))[0] ++> Seq())[0];
    test_s ++> [decorators(), Lit(value="test")];
    (test_s ++> Choice())[0] ++> [Sym(name="string"), Blank()];
    test_s ++> block();

    # global_var ::= "glob" access_tag comma_sep1(name opt(":" type) opt(rep1("=" expr))) ";"
    gv_item = Seq();
    (gv_item ++> Field(name="name"))[0] ++> name_ref();
    gv_type_opt = (gv_item ++> Choice())[0];
    gv_vals_opt = (gv_item ++> Choice())[0];
    (gv_type_opt ++> Seq())[0] ++> [Lit(value=":"), Sym(name="type_annotation")];
    gv_type_opt ++> Blank();
    gv_vals = (gv_vals_opt ++> Rep1())[0];
    gv_vals_opt ++> Blank();
    (gv_vals ++> Seq())[0] ++> [Lit(value="="), Sym(name="expression")];
    gv = ((g ++> Rule(name="global_var"))[0] ++> Seq())[0];
    gv ++> [Lit(value="glob"), access_tag(), comma_sep1(gv_item), Lit(value=";")];

    # The impl target is a dotted name PATH (`Class.method`, `Walker.entry`,
    # `Obj.init`), NOT a general expression -- using `expression` made
    # `impl X.f(params)` greedily parse as a call_expression, so the func
    # signature's `(` collided and every signature-bearing impl failed.
    impl_s = ((g ++> Rule(name="impl"))[0] ++> Seq())[0];
    impl_s ++> [decorators(), Lit(value="impl")];
    (impl_s ++> Field(name="target"))[0] ++> Sym(name="impl_target");
    impl_sig_opt = (impl_s ++> Choice())[0];
    impl_body = (impl_s ++> Choice())[0];
    (impl_sig_opt ++> Choice())[0] ++> [Sym(name="event_clause"), Sym(name="func_signature")];
    impl_sig_opt ++> Blank();
    impl_body ++> block();
    (impl_body ++> Seq())[0] ++> [Lit(value="by"), Sym(name="expression"), Lit(value=";")];
    impl_body ++> Lit(value=";");

    it = ((g ++> Rule(name="impl_target"))[0] ++> Prec(kind="PREC_LEFT", level=1))[0];
    it_s = (it ++> Seq())[0];
    it_s ++> Sym(name="impl_target_name");
    it_rest = (it_s ++> Rep())[0];
    (it_rest ++> Seq())[0] ++> [Lit(value="."), Sym(name="impl_target_name")];

    # impl_target_name (jac.spec): NAME/KWESC plus a few contextual keywords
    # that name abilities/ctors. Keyword extraction (word: identifier) keeps
    # these usable as ordinary identifiers elsewhere.
    itn = ((g ++> Rule(name="impl_target_name"))[0] ++> Choice())[0];
    itn ++> [name_ref(),
             Lit(value="init"), Lit(value="postinit"), Lit(value="entry"), Lit(value="exit"), Lit(value="default")];

    ta = ((g ++> Rule(name="type_alias"))[0] ++> Seq())[0];
    ta ++> [Lit(value="type"), access_tag()];
    (ta ++> Field(name="name"))[0] ++> name_ref();
    (ta ++> Choice())[0] ++> [Sym(name="type_params"), Blank()];
    ta ++> [Lit(value="="), Sym(name="type_annotation"), Lit(value=";")];

    tp_item = Seq();
    tp_item ++> name_ref();
    tp_bound_opt = (tp_item ++> Choice())[0];
    tp_def_opt = (tp_item ++> Choice())[0];
    (tp_bound_opt ++> Seq())[0] ++> [Lit(value=":"), Sym(name="expression")];
    tp_bound_opt ++> Blank();
    (tp_def_opt ++> Seq())[0] ++> [Lit(value="="), Sym(name="expression")];
    tp_def_opt ++> Blank();
    tp = ((g ++> Rule(name="type_params"))[0] ++> Seq())[0];
    tp ++> [Lit(value="["), comma_sep1(tp_item), Lit(value="]")];

    sem = ((g ++> Rule(name="sem_def"))[0] ++> Prec(kind="PREC_RIGHT", level=1))[0];
    sem_s = (sem ++> Seq())[0];
    sem_s ++> [Lit(value="sem"), Sym(name="impl_target")];
    (sem_s ++> Choice())[0] ++> [Lit(value="="), Lit(value="is")];
    (sem_s ++> Rep())[0] ++> Sym(name="string");
    (sem_s ++> Choice())[0] ++> [Lit(value=";"), Blank()];
}

# ===========================================================================
# Imports & module structure
# ===========================================================================

def build_imports(g: Grammar) -> None {
    # prec.right so the optional trailing `;` after the `{ ... }` items form is
    # shifted into THIS statement rather than left dangling (a benign
    # shift/reduce on the optional terminator).
    ist = ((g ++> Rule(name="import_statement"))[0] ++> Prec(kind="PREC_RIGHT", level=1))[0];
    ist_s = (ist ++> Seq())[0];
    (ist_s ++> Choice())[0] ++> [Lit(value="import"), Lit(value="include")];
    (ist_s ++> Choice())[0] ++> [Lit(value="type"), Blank()];
    ist_from_opt = (ist_s ++> Choice())[0];
    ist_body = (ist_s ++> Choice())[0];
    (ist_from_opt ++> Seq())[0] ++> [Lit(value="from"), Sym(name="import_path")];
    ist_from_opt ++> Blank();
    # The `{ ... }` items form ends in a block, so (like every other
    # block-bodied construct in Jac) it self-terminates and the trailing
    # `;` is optional -- real Jac omits it after `import from x { ... }`.
    ist_items = (ist_body ++> Seq())[0];
    ist_path = (ist_body ++> Seq())[0];
    ist_items ++> Sym(name="import_items");
    (ist_items ++> Choice())[0] ++> [Lit(value=";"), Blank()];
    ist_path ++> Sym(name="import_path");
    ist_path_as = (ist_path ++> Choice())[0];
    ist_path ++> Lit(value=";");
    (ist_path_as ++> Seq())[0] ++> [Lit(value="as"), name_ref()];
    ist_path_as ++> Blank();

    # precl(2) so extending the path (`a` + `.b`) binds TIGHTER than reducing
    # the enclosing `import_path` relative branch (precr 1) -- otherwise a
    # `...pkg.sub` path reduces after the first segment and orphans `.sub`.
    dn = ((g ++> Rule(name="dotted_name"))[0] ++> Choice())[0];
    dn ++> name_ref();
    dn_rec = (dn ++> Prec(kind="PREC_LEFT", level=2))[0];
    (dn_rec ++> Seq())[0] ++> [Sym(name="dotted_name"), Lit(value="."), name_ref()];

    # Leading relative-import dots: `.`, `..`, `...` (and longer runs).
    # Explicit left-recursion + prec.left resolves the dot shift/reduce without
    # a GLR dynamic conflict. The dots only ever precede the path (never follow
    # a NAME), so they never clash with `dotted_name`'s own `.` separators.
    rp = ((g ++> Rule(name="relative_prefix"))[0] ++> Choice())[0];
    (rp ++> Choice())[0] ++> [Lit(value="."), Lit(value="...")];
    rp_rec = (rp ++> Prec(kind="PREC_LEFT", level=1))[0];
    rp_rec_s = (rp_rec ++> Seq())[0];
    rp_rec_s ++> Sym(name="relative_prefix");
    (rp_rec_s ++> Choice())[0] ++> [Lit(value="."), Lit(value="...")];

    ip = ((g ++> Rule(name="import_path"))[0] ++> Choice())[0];
    ip ++> [Sym(name="string"), Sym(name="dotted_name")];
    ip_rel = (ip ++> Prec(kind="PREC_RIGHT", level=1))[0];
    ip_rel_s = (ip_rel ++> Seq())[0];
    ip_rel_s ++> Sym(name="relative_prefix");
    ip_tail_opt = (ip_rel_s ++> Choice())[0];
    (ip_tail_opt ++> Choice())[0] ++> [Sym(name="string"), Sym(name="dotted_name")];
    ip_tail_opt ++> Blank();

    ii_item = Seq();
    (ii_item ++> Choice())[0] ++> [Lit(value="*"), name_ref()];
    ii_as_opt = (ii_item ++> Choice())[0];
    (ii_as_opt ++> Seq())[0] ++> [Lit(value="as"), name_ref()];
    ii_as_opt ++> Blank();
    ii = ((g ++> Rule(name="import_items"))[0] ++> Seq())[0];
    ii ++> Lit(value="{");
    ii ++> comma_sep1(ii_item);
    ii_trail = (ii ++> Choice())[0];
    ii ++> Lit(value="}");
    ii_trail ++> [Lit(value=","), Blank()];

    mod = ((g ++> Rule(name="module_code"))[0] ++> Seq())[0];
    mod ++> Lit(value="with");
    mod_ee_opt = (mod ++> Choice())[0];
    mod_named_opt = (mod ++> Choice())[0];
    mod ++> block();
    (mod_ee_opt ++> Choice())[0] ++> [Lit(value="entry"), Lit(value="exit")];
    mod_ee_opt ++> Blank();
    (mod_named_opt ++> Seq())[0] ++> [Lit(value=":"), name_ref()];
    mod_named_opt ++> Blank();

    ctx = ((g ++> Rule(name="context_block"))[0] ++> Seq())[0];
    ((ctx ++> Field(name="context"))[0] ++> Choice())[0] ++> [Lit(value="cl"), Lit(value="sv"), Lit(value="na")];
    ctx_body = (ctx ++> Choice())[0];
    ctx_block = (ctx_body ++> Seq())[0];
    ctx_body ++> Sym(name="element");
    ctx_block ++> Lit(value="{");
    (ctx_block ++> Rep())[0] ++> Sym(name="element");
    ctx_block ++> Lit(value="}");

    elem = ((g ++> Rule(name="element"))[0] ++> Choice())[0];
    elem ++> [
        Sym(name="import_statement"),
        Sym(name="archetype"),
        Sym(name="ability"),
        Sym(name="enum"),
        Sym(name="test"),
        Sym(name="global_var"),
        Sym(name="impl"),
        Sym(name="sem_def"),
        Sym(name="type_alias"),
        Sym(name="module_code"),
        Sym(name="context_block"),
        Sym(name="pyinline"),
        Sym(name="string"),
        Lit(value=";")
    ];
}

def build -> Grammar {
    g = Grammar(name="jac");
    ((g ++> Rule(name="source_file"))[0] ++> Rep())[0] ++> Sym(name="element");
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
        "extras": [emit(Pat(value="\\s")), emit(Sym(name="comment"))],
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
            emit(Sym(name="pyinline")), emit(Sym(name="jsx_text")),
            emit(Sym(name="fstring_start")), emit(Sym(name="fstring_content")),
            emit(Sym(name="fstring_end"))
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
