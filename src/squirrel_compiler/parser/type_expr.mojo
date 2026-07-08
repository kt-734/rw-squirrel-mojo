from std.memory import ArcPointer


@fieldwise_init
struct TypeExpr(Copyable, Movable, ImplicitlyDeletable):
    """A parsed field-type expression -- the AST counterpart to the raw
    `type_str: String` text that `is_wrapped_relation_type`/
    `relation_target_of`/`relation_wrapper_of`/`container_wrapper_of`/
    `_plain_struct_base_name` used to each re-derive their own answer to
    via ad hoc bracket-depth scanning over the same string, one
    purpose-built function per question ("is this a container", "what's
    its element", "what's this generic instantiation's base name", ...)
    -- every one of those now just parses into this tree and reads the
    answer off a field/method (`.is_parameterized()`, `.arg(i).name`,
    ...) instead, alongside `qualify_type_params_with_self`/
    `substitute_type_params_expr`/`_collect_json_container_types`, built
    directly on this tree from the start (`codegen.generics`,
    `driver.json_container_types`). `TypeExpr` answers all of those
    uniformly, by walking a real tree instead of slicing text -- and,
    unlike the string-based versions it replaced, walks correctly no
    matter how deeply the shape nests (a plain struct inside a container
    inside a generic instantiation, arbitrarily), which is exactly the
    shape the string-based approach had known gaps on (see
    `emit_json_module`'s own doc comment on the one it never closed:
    a plain struct nested inside a container has no `sqrrl__from_json[T]`
    dispatch branch to reach it through).

    Mojo has no `enum` keyword -- same discriminant-on-a-struct idiom as
    `MarkerKind`/`FieldModifier` (see their own doc comments): `kind` says
    which of three shapes this node is, `name` carries whichever name
    matters for that shape, and `args` holds child `TypeExpr`s (empty for
    a leaf or a bare relation, since neither is ever parameterized) --
    behind `ArcPointer`, not directly: Mojo has no way for a struct to
    hold a `List` of its own type as a field (confirmed: `List[TypeExpr]`
    as a field of `TypeExpr` itself fails "non-implicitly deletable type"
    even with `TypeExpr` itself declared `ImplicitlyDeletable` -- the
    conformance check is circular). `ArcPointer` breaks the cycle with a
    fixed-size indirection, the same fix any recursive data structure
    needs in a language without automatic boxing -- use `arg`/`arg_count`
    below rather than indexing `args` directly.

    - `LEAF`: a bare, unparameterized identifier with no `@@` and no
      `[...]` -- `String`, `UInt32`, `Address`, or a non-generic plain
      struct's own name used directly. `name` is that identifier verbatim.
    - `RELATION`: `@@Employee` -- a relation field's target, marked with
      `@@` in `.rel` source. `name` is the target's bare name (`@@`
      already stripped), matching `relation_target_of`'s own output.
    - `PARAMETERIZED`: `Ident[arg1, arg2, ...]` -- covers a real container
      (`List`/`Set`/`Optional`/`Dict`) *and* a generic plain struct's own
      instantiation (`Box[String]`, `Pair[Int, Int]`) uniformly, since
      both share identical `Ident[...]` syntax and only differ in what a
      *caller* does once it has `name` in hand (check it against the
      known container names, or fall through to "generic instantiation"
      handling) -- exactly the same distinction `is_container_type`
      already draws today, just now available as a simple string compare
      on `name` rather than a second independent parse. `args` is each
      comma-separated piece, itself parsed recursively (so
      `Optional[List[String]]`'s outer `Optional` has one `arg`, itself a
      `PARAMETERIZED` `List` with one `LEAF` `arg` of its own)."""

    comptime LEAF = 0
    comptime RELATION = 1
    comptime PARAMETERIZED = 2

    var kind: Int
    var name: String
    var args: List[ArcPointer[TypeExpr]]

    def is_relation(self) -> Bool:
        """True for a bare `@@Type` relation field -- never true for a
        `PARAMETERIZED` node even if it wraps one (`List[@@Employee]`'s
        own top-level kind is `PARAMETERIZED`, not `RELATION`; its sole
        `arg` is the `RELATION` one) -- callers that need to know whether
        a *wrapped* relation is buried inside walk `args` themselves, the
        same way `is_wrapped_relation_type` and this are two different
        questions today."""
        return self.kind == Self.RELATION

    def is_parameterized(self) -> Bool:
        return self.kind == Self.PARAMETERIZED

    def arg_count(self) -> Int:
        return len(self.args)

    def arg(self, i: Int) -> TypeExpr:
        """The `i`-th child type expression, copied out from behind its
        `ArcPointer` (see the struct's own doc comment for why `args`
        can't just be a plain `List[TypeExpr]`)."""
        return self.args[i][].copy()

    def render(self) -> String:
        """Renders back to the same `.rel`-source type text this was
        parsed from (`@@Employee`, `List[String]`, `Dict[String, Int]`)
        -- the inverse of `parse_type_expr`. Not necessarily byte-identical
        to arbitrary hand-written input spacing (always renders
        multi-argument commas as `", "`), but round-trips consistently for
        any tree this module itself produced, which is the only direction
        that matters: nothing here claims to preserve a human author's own
        whitespace choices, the same way `emit_field_type`'s own output
        never tries to either."""
        if self.kind == Self.RELATION:
            return "@@" + self.name
        if self.kind == Self.LEAF:
            return self.name
        var out = self.name + "["
        for i in range(len(self.args)):
            if i > 0:
                out += ", "
            out += self.args[i][].render()
        out += "]"
        return out^


def _split_top_level_commas(s: String) -> List[String]:
    """Splits `s` on every top-level `,` -- ignoring one nested inside
    further brackets (`Dict[String, Int]` as a single argument mustn't
    split on its own inner comma) -- trimming whitespace from each piece.
    `parse_type_expr`'s own comma-splitting, kept private to this module
    (not imported from `codegen`, which has no equivalent of its own
    anymore either) to keep `parser` from depending on `codegen`
    (the reverse of every other cross-package dependency in this
    compiler -- `codegen`/`driver` both depend on `parser`, never the
    other way)."""
    var out = List[String]()
    var depth = 0
    var start = 0
    var bytes = s.as_bytes()
    var n = len(bytes)
    for i in range(n):
        var b = bytes[i]
        if b == UInt8(ord("[")) or b == UInt8(ord("(")) or b == UInt8(ord("{")):
            depth += 1
        elif b == UInt8(ord("]")) or b == UInt8(ord(")")) or b == UInt8(ord("}")):
            depth -= 1
        elif b == UInt8(ord(",")) and depth == 0:
            out.append(String(String(s[byte = start : i]).strip()))
            start = i + 1
    out.append(String(String(s[byte = start : n]).strip()))
    return out^


def parse_type_expr(type_str: String) -> TypeExpr:
    """Parses `type_str` (a field's raw type text, from `Scanner.scan_type`
    -- `@@Employee`, `List[String]`, `Dict[String, Box[Int]]`, ...) into a
    `TypeExpr` tree. Requires nothing about `type_str` beyond what
    `Scanner.scan_type` already guarantees (balanced brackets, no stray
    whitespace at the edges after `.strip()`)."""
    var t = type_str.strip()
    if t.startswith("@@"):
        return TypeExpr(
            kind=TypeExpr.RELATION,
            name=String(t[byte=2 : t.byte_length()]),
            args=List[ArcPointer[TypeExpr]](),
        )
    var bracket = t.find("[")
    if bracket < 0:
        return TypeExpr(kind=TypeExpr.LEAF, name=String(t), args=List[ArcPointer[TypeExpr]]())
    var name = String(t[byte=0 : bracket])
    var inner = String(t[byte = bracket + 1 : t.byte_length() - 1])
    var args = List[ArcPointer[TypeExpr]]()
    for arg_str in _split_top_level_commas(inner):
        args.append(ArcPointer(parse_type_expr(arg_str)))
    return TypeExpr(kind=TypeExpr.PARAMETERIZED, name=name, args=args^)
