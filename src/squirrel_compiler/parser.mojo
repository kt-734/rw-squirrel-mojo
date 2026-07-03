def is_ident_char(b: UInt8) -> Bool:
    return (
        (b >= UInt8(ord("a")) and b <= UInt8(ord("z")))
        or (b >= UInt8(ord("A")) and b <= UInt8(ord("Z")))
        or (b >= UInt8(ord("0")) and b <= UInt8(ord("9")))
        or b == UInt8(ord("_"))
    )


@fieldwise_init
struct Field(Copyable, Movable):
    """A single `name: Type` entry inside a `@@struct` body. `type_str` is
    left as raw, untouched text -- whether it's a plain Mojo type or a
    `@@`-marked relation is for codegen to interpret, not this parser."""

    var name: String
    var type_str: String


struct ParsedStruct(Copyable, Movable):
    """One `@@struct Name { field: Type, ... }` declaration."""

    var name: String
    var fields: List[Field]

    def __init__(out self, var name: String, var fields: List[Field]):
        self.name = name^
        self.fields = fields^


@fieldwise_init
struct ConstructField(Copyable, Movable):
    """One `.name = value` (or, for a relation field, `.@@name = value`)
    segment inside a `@@TypeName { ... }` construct body -- `is_relation`
    mirrors the struct declaration's own marking (`@@name: @@Type`), which
    codegen validates against the project-wide relation schema (a
    mismatch, either direction, is rejected the same way a struct
    declaration's own name/type marking mismatch already is). It's also
    what tells codegen `value` might itself need marker rewriting -- a bare
    reference to an already-constructed entity (`@@bob`) or a nested
    construct (`@@Employee { ... }`) -- rather than being passed through as
    opaque text; a plain (non-`@@`) value is assumed already-valid Mojo and
    left untouched either way. `value` is raw, untrimmed-of-markers text --
    interpreting it is codegen's job, not this parser's."""

    var name: String
    var is_relation: Bool
    var value: String


@fieldwise_init
struct Construct(Copyable, Movable):
    """A `@@TypeName { .field = expr, ... }` construction use site --
    `fields` is `parse_construct_fields`' structured breakdown of the
    braced body, one entry per top-level `.name = value` segment."""

    var type_name: String
    var fields: List[ConstructField]


@fieldwise_init
struct FieldAccess(Copyable, Movable):
    """A `@@entity.field` use-site access -- a read, or (if `write_value` is
    set) a write from `@@entity.field = expr;`. `hops` holds any
    intermediate `@@relation` segments in a chain (`@@alice.@@employee.@@boss.title`
    -> `hops = ["employee", "boss"]`, `field = "title"`) -- each one is
    itself a relation field, followed to reach the next entity, with
    `field` (never `@@`-marked) being the terminal, actual field read or
    written. `hops` is empty for the ordinary single-hop case
    (`@@entity.field`)."""

    var entity: String
    var hops: List[String]
    var field: String
    var write_value: Optional[String]


@fieldwise_init
struct NameRef(Copyable, Movable):
    """A bare `@@name` -- covers both a declaration (`var @@alice = ...`)
    and a plain reference; both rewrite the same way (strip the `@@`)."""

    var name: String


@fieldwise_init
struct EntityParam(Copyable, Movable):
    """A `@@name: @@Type` function-parameter declaration -- same shape as a
    `@@struct` relation field (`@@employee: @@Employee`), just written in a
    `def`'s own parameter list instead of a struct body. This is what lets
    an already-constructed entity (a plain Mojo local otherwise, same as
    any `@@`-marked variable) cross into a different function: the callee
    opts in by naming it and its type here, which both gives it a properly
    typed Mojo parameter and registers it in the callee's own
    `entity_to_type` so `@@name.field` works inside that function too --
    passing the actual value at the call site needs no new syntax, since a
    bare `@@name` there already rewrites to a plain reference."""

    var name: String
    var type_name: String


@fieldwise_init
struct MarkerKind(ImplicitlyCopyable, Movable, Equatable):
    """What `Scanner.find_next_marker` found. Mojo has no `enum` keyword --
    this is the standard idiom: a struct wrapping a discriminant, with
    named `comptime` values, giving a distinct type instead of a bare `Int`
    that any stray integer could be mistaken for."""

    var value: Int

    comptime NONE = Self(0)
    comptime STRUCT = Self(1)
    comptime CONSTRUCT = Self(2)
    comptime FIELD_ACCESS = Self(3)
    comptime NAME_REF = Self(4)
    comptime INIT = Self(5)
    comptime WORLD = Self(6)
    comptime ENTITY_PARAM = Self(7)

    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        return self.value != other.value


def parse_construct_fields(body: String) raises -> List[ConstructField]:
    """Splits a construct's braced body into `.name = value` /
    `.@@name = value` segments, each becoming a `ConstructField` -- same
    top-level-comma/bracket-depth tracking an earlier flat-text version of
    this used, but keeping each field's name, relation-marking, and value
    text apart instead of collapsing everything back into one opaque
    string (dots and commas nested inside brackets or strings still pass
    through untouched, as part of a field's `value`, same as before)."""
    var bs = Scanner(body)
    var out = List[ConstructField]()
    while True:
        bs.skip_trivia()
        if bs.at_end():
            break
        if not bs.try_consume("."):
            raise Error(
                "InvalidSquirrelSyntax: expected '.' before field name in"
                " construct"
            )
        var is_relation = bs.try_consume("@@")
        var name = bs.scan_ident()
        if name.byte_length() == 0:
            raise Error("InvalidSquirrelSyntax: expected field name in construct")
        bs.skip_trivia()
        if not bs.try_consume("="):
            raise Error(
                "InvalidSquirrelSyntax: expected '=' after field name in"
                " construct"
            )
        bs.skip_whitespace()
        var value_start = bs.pos
        var depth = 0
        while not bs.at_end():
            var before = bs.pos
            bs.skip_non_code()
            if bs.pos != before:
                continue
            var b = bs.peek()
            if b == UInt8(ord("(")) or b == UInt8(ord("[")) or b == UInt8(ord("{")):
                depth += 1
            elif b == UInt8(ord(")")) or b == UInt8(ord("]")) or b == UInt8(ord("}")):
                depth -= 1
            elif b == UInt8(ord(",")) and depth == 0:
                break
            bs.pos += 1
        var value = String(body[byte = value_start : bs.pos]).strip()
        out.append(ConstructField(name=name, is_relation=is_relation, value=String(value)))
        _ = bs.try_consume(",")
    return out^


struct Scanner(Movable):
    """A cursor over `.rel` source text. Every scanning/skipping operation
    here routes through `skip_non_code` so that a `{`, `}`, `,`, or `@@`
    sitting inside a `//` comment or a string literal never desyncs
    anything -- matching the Zig parser's `skipNonCode`, just expressed as
    mutating cursor state instead of threading `(source, pos)` through every
    call."""

    var source: String
    var pos: Int

    def __init__(out self, var source: String):
        self.source = source^
        self.pos = 0

    def at_end(self) -> Bool:
        return self.pos >= self.source.byte_length()

    def byte_at(self, i: Int) -> UInt8:
        return self.source.as_bytes()[i]

    def peek(self) -> UInt8:
        if self.at_end():
            return 0
        return self.byte_at(self.pos)

    def peek_at(self, offset: Int) -> UInt8:
        var i = self.pos + offset
        if i >= self.source.byte_length():
            return 0
        return self.byte_at(i)

    def starts_with(self, literal: String) -> Bool:
        var end = self.pos + literal.byte_length()
        if end > self.source.byte_length():
            return False
        return self.source[byte = self.pos : end] == literal

    def try_consume(mut self, literal: String) -> Bool:
        if self.starts_with(literal):
            self.pos += literal.byte_length()
            return True
        return False

    def skip_whitespace(mut self):
        while not self.at_end():
            var b = self.peek()
            if (
                b == UInt8(ord(" "))
                or b == UInt8(ord("\t"))
                or b == UInt8(ord("\n"))
                or b == UInt8(ord("\r"))
            ):
                self.pos += 1
            else:
                break

    def skip_non_code(mut self):
        """If positioned at a `//` line comment or a `"`/`'` string literal,
        advances past it. No-op otherwise."""
        if self.at_end():
            return
        if self.peek() == UInt8(ord("/")) and self.peek_at(1) == UInt8(ord("/")):
            while not self.at_end() and self.peek() != UInt8(ord("\n")):
                self.pos += 1
            return
        if self.peek() == UInt8(ord('"')) or self.peek() == UInt8(ord("'")):
            var quote = self.peek()
            self.pos += 1
            while not self.at_end() and self.peek() != quote:
                if self.peek() == UInt8(ord("\\")) and not self.at_end():
                    self.pos += 1
                self.pos += 1
            if not self.at_end():
                self.pos += 1  # consume closing quote

    def skip_trivia(mut self):
        """Skips whitespace and comments/strings, interleaved, until real
        code or end of input."""
        while True:
            var before = self.pos
            self.skip_whitespace()
            self.skip_non_code()
            if self.pos == before:
                return

    def scan_ident(mut self) -> String:
        var start = self.pos
        while not self.at_end() and is_ident_char(self.peek()):
            self.pos += 1
        return String(self.source[byte = start : self.pos])

    def scan_braced_span(mut self) raises -> String:
        """Requires `self.pos` at `{`. Returns the body between the matching
        braces (exclusive), and advances `self.pos` past the closing `}`."""
        if self.peek() != UInt8(ord("{")):
            raise Error("InvalidSquirrelSyntax: expected '{'")
        self.pos += 1
        var body_start = self.pos
        var depth = 1
        while not self.at_end() and depth > 0:
            var before = self.pos
            self.skip_non_code()
            if self.pos != before:
                continue
            var b = self.peek()
            if b == UInt8(ord("{")):
                depth += 1
            elif b == UInt8(ord("}")):
                depth -= 1
            self.pos += 1
        if depth != 0:
            raise Error("InvalidSquirrelSyntax: unterminated '{'")
        return String(self.source[byte = body_start : self.pos - 1])

    def scan_type(mut self) -> String:
        """Scans a field's type text: up to the next top-level `,` (ignoring
        commas nested inside `[]`/`()`/`{}`) or the end of input. Trimmed."""
        var start = self.pos
        var depth = 0
        while not self.at_end():
            var before = self.pos
            self.skip_non_code()
            if self.pos != before:
                continue
            var b = self.peek()
            if b == UInt8(ord("[")) or b == UInt8(ord("(")) or b == UInt8(ord("{")):
                depth += 1
            elif b == UInt8(ord("]")) or b == UInt8(ord(")")) or b == UInt8(ord("}")):
                depth -= 1
            elif b == UInt8(ord(",")) and depth == 0:
                break
            self.pos += 1
        var raw = String(self.source[byte = start : self.pos])
        return String(raw.strip())

    def find_next_struct_decl(mut self) -> Bool:
        """Advances to the start of the next `@@struct` occurrence at
        real-code depth. Returns False (leaving `self.pos` at the end) if
        there isn't one."""
        while True:
            self.skip_trivia()
            if self.at_end():
                return False
            if self.starts_with("@@struct"):
                return True
            self.pos += 1

    def find_next_plain_struct_decl(mut self) -> Bool:
        """Advances to the start of the next bare `struct` occurrence (not
        `@@struct`) at real-code depth -- an ordinary Mojo struct a `.rel`
        file defines directly, outside the managed-table DSL. It never gets
        a generated Table/State pair the way `@@struct` does; this exists
        purely so `check_no_relation_cycles` can see whether such a
        struct's body smuggles a `@@`-marked relation field that would
        otherwise be an invisible way to complete a construction cycle back
        through a real `@@struct` (a plain field elsewhere naming this
        struct wouldn't reveal that on its own). Requires a word boundary
        on both sides of `struct` (not preceded by an identifier char or by
        `@@`, not followed by an identifier char) so `construct`,
        `MyStructType`, or a real `@@struct` aren't mistaken for this.
        Returns False (leaving `self.pos` at the end) if there isn't one."""
        while True:
            self.skip_trivia()
            if self.at_end():
                return False
            if self.starts_with("struct"):
                var before_is_ident = self.pos > 0 and is_ident_char(
                    self.byte_at(self.pos - 1)
                )
                var before_is_at = self.pos >= 2 and self.byte_at(
                    self.pos - 1
                ) == UInt8(ord("@")) and self.byte_at(self.pos - 2) == UInt8(ord("@"))
                var after = self.pos + String("struct").byte_length()
                var after_is_ident = after < self.source.byte_length() and is_ident_char(
                    self.byte_at(after)
                )
                if not before_is_ident and not before_is_at and not after_is_ident:
                    return True
            self.pos += 1

    def parse_struct_body(mut self) raises -> ParsedStruct:
        """Shared tail of `parse_struct`/`parse_plain_struct`, once the
        `@@struct`/`struct` keyword itself has already been consumed: scans
        the name and braced body, and parses the body's fields with the
        same grammar either way."""
        self.skip_trivia()
        var name = self.scan_ident()
        if name.byte_length() == 0:
            raise Error("InvalidSquirrelSyntax: expected struct name")
        self.skip_trivia()
        var body = self.scan_braced_span()
        var fields = parse_fields(body)
        return ParsedStruct(name=name, fields=fields^)

    def parse_struct(mut self) raises -> ParsedStruct:
        """Requires `self.pos` at the `@@struct` token, e.g. right after
        `find_next_struct_decl` returns True."""
        if not self.try_consume("@@struct"):
            raise Error("InvalidSquirrelSyntax: expected '@@struct'")
        return self.parse_struct_body()

    def parse_plain_struct(mut self) raises -> ParsedStruct:
        """Requires `self.pos` at the bare `struct` token, e.g. right after
        `find_next_plain_struct_decl` returns True."""
        if not self.try_consume("struct"):
            raise Error("InvalidSquirrelSyntax: expected 'struct'")
        return self.parse_struct_body()

    def find_next_marker(mut self) -> MarkerKind:
        """Advances to the next `@@`-marked construct at real-code depth and
        reports which kind it is, leaving `self.pos` at the start of the
        marker (ready for the matching `parse_*` call) -- mirrors the Zig
        parser's `findNextMarker`, minus chained relation hops
        (`@@entity.@@relation.field`): those aren't recognized here, so a
        script using them fails with a clear parse error from
        `parse_field_access` rather than being silently mishandled.

        No `.destroy()` marker, unlike Zig's parser: Zig needed it because
        `defer sqrrl__alice.decref()` only releases at the *end of the
        enclosing function*, so an explicit call was the only way to release
        earlier. Mojo's own destruction is already more precise than
        that -- a plain `var alice = ...` drops at its actual last
        mention, not at scope exit -- so there's no gap left for
        `.destroy()` to fill; a `.rel` script just stops referencing an
        entity when it's done, same as any other Mojo value.

        Three more kinds beyond the original four, all driven by Mojo having
        no mutable global/static state (see `Table`'s doc comment in
        `entity.mojo`): `@@init()` (`MarkerKind.INIT`) is the explicit call
        a script makes to obtain `sqrrl__Squirrel`'s shared instance, a bare
        `@@` sitting directly before `)`/`,` (`MarkerKind.WORLD`) is the
        token that threads that instance through a function's own
        parameter list (`def foo(a: Int, @@)`) or forwards it at a call site
        (`foo(x, @@)`), and `@@name: @@Type` (`MarkerKind.ENTITY_PARAM`,
        e.g. `def example(a: Int, @@test: @@Test)`) is how a *different*
        function's own parameter list opts an already-constructed entity
        into that function's scope -- same shape as a `@@struct` relation
        field, just written in a signature instead of a struct body.
        Passing the value at a call site needs no extra syntax, since a
        bare `@@name` there is already `MarkerKind.NAME_REF`. `@@init` not
        immediately followed by `()`, or `@@name:` not followed by another
        `@@`, falls through to ordinary name-ref handling instead -- a
        variable literally named `init`, or one immediately followed by an
        ordinary (non-`@@`) type annotation, isn't this marker. Returns
        `MarkerKind.NONE` at end of input."""
        while True:
            self.skip_trivia()
            if self.at_end():
                return MarkerKind.NONE
            if self.starts_with("@@struct"):
                return MarkerKind.STRUCT
            if self.starts_with("@@"):
                var marker_start = self.pos
                self.pos += 2
                var ident_start = self.pos
                var ident = self.scan_ident()
                if self.pos == ident_start:
                    # Bare "@@" with no identifier -- the "thread
                    # sqrrl__world through" token if it's sitting directly
                    # before `)`/`,`, otherwise stray noise; step past it so
                    # the outer loop makes progress.
                    self.skip_trivia()
                    var b = self.peek()
                    if b == UInt8(ord(")")) or b == UInt8(ord(",")):
                        self.pos = marker_start
                        return MarkerKind.WORLD
                    self.pos = marker_start + 1
                    continue
                if ident == "init":
                    var after_ident = self.pos
                    self.skip_trivia()
                    if self.peek() == UInt8(ord("(")):
                        var paren_pos = self.pos
                        self.pos += 1
                        self.skip_trivia()
                        if self.peek() == UInt8(ord(")")):
                            self.pos = marker_start
                            return MarkerKind.INIT
                        self.pos = paren_pos
                    self.pos = after_ident
                self.skip_trivia()
                var kind: MarkerKind
                if self.peek() == UInt8(ord("{")):
                    kind = MarkerKind.CONSTRUCT
                elif self.peek() == UInt8(ord(".")):
                    kind = MarkerKind.FIELD_ACCESS
                elif self.peek() == UInt8(ord(":")):
                    var save_colon = self.pos
                    self.pos += 1
                    self.skip_trivia()
                    if self.starts_with("@@"):
                        kind = MarkerKind.ENTITY_PARAM
                    else:
                        kind = MarkerKind.NAME_REF
                    self.pos = save_colon
                else:
                    kind = MarkerKind.NAME_REF
                self.pos = marker_start
                return kind
            self.pos += 1

    def parse_entity_param(mut self) raises -> EntityParam:
        """Requires `self.pos` at the `@@` of `@@name: @@Type`, e.g. right
        after `find_next_marker` returns `MarkerKind.ENTITY_PARAM`."""
        if not self.try_consume("@@"):
            raise Error("InvalidSquirrelSyntax: expected '@@'")
        var name = self.scan_ident()
        if name.byte_length() == 0:
            raise Error("InvalidSquirrelSyntax: expected entity parameter name")
        self.skip_trivia()
        if not self.try_consume(":"):
            raise Error("InvalidSquirrelSyntax: expected ':' after entity parameter name")
        self.skip_trivia()
        if not self.try_consume("@@"):
            raise Error("InvalidSquirrelSyntax: expected '@@Type' after ':'")
        var type_name = self.scan_ident()
        if type_name.byte_length() == 0:
            raise Error("InvalidSquirrelSyntax: expected entity parameter type")
        return EntityParam(name=name, type_name=type_name)

    def parse_construct(mut self) raises -> Construct:
        """Requires `self.pos` at the `@@` of a `@@TypeName { ... }`
        construct, e.g. right after `find_next_marker` returns
        `MARKER_CONSTRUCT`."""
        if not self.try_consume("@@"):
            raise Error("InvalidSquirrelSyntax: expected '@@'")
        var type_name = self.scan_ident()
        if type_name.byte_length() == 0:
            raise Error("InvalidSquirrelSyntax: expected type name")
        self.skip_trivia()
        var body = self.scan_braced_span()
        return Construct(type_name=type_name, fields=parse_construct_fields(body))

    def parse_field_access(mut self) raises -> FieldAccess:
        """Requires `self.pos` at the `@@` of `@@entity.field` (or a chain,
        `@@entity.@@relation.field`, ...), e.g. right after
        `find_next_marker` returns `MARKER_FIELD_ACCESS`. Loops consuming
        `.@@relation` segments (each an intermediate hop, collected into
        `FieldAccess.hops`) until it hits a `.` followed by a *plain*
        (non-`@@`) identifier -- that one is the terminal `field`, read or
        (if followed by `=`) written."""
        if not self.try_consume("@@"):
            raise Error("InvalidSquirrelSyntax: expected '@@'")
        var entity = self.scan_ident()
        if entity.byte_length() == 0:
            raise Error("InvalidSquirrelSyntax: expected entity name")

        var hops = List[String]()
        var field: String
        while True:
            self.skip_trivia()
            if not self.try_consume("."):
                raise Error(
                    "InvalidSquirrelSyntax: expected '.' after entity/relation"
                    " name"
                )
            self.skip_trivia()
            if self.try_consume("@@"):
                var hop = self.scan_ident()
                if hop.byte_length() == 0:
                    raise Error(
                        "InvalidSquirrelSyntax: expected relation field name"
                        " after '@@'"
                    )
                hops.append(hop)
                continue
            field = self.scan_ident()
            if field.byte_length() == 0:
                raise Error("InvalidSquirrelSyntax: expected field name")
            break
        var after_field = self.pos

        self.skip_trivia()
        var is_write = self.peek() == UInt8(ord("=")) and self.peek_at(1) != UInt8(ord("="))
        if not is_write:
            self.pos = after_field
            return FieldAccess(entity=entity, hops=hops^, field=field, write_value=None)

        self.pos += 1  # consume '='
        self.skip_whitespace()
        var value_start = self.pos
        var depth = 0
        while not self.at_end():
            var before = self.pos
            self.skip_non_code()
            if self.pos != before:
                continue
            var b = self.peek()
            if b == UInt8(ord("(")) or b == UInt8(ord("[")) or b == UInt8(ord("{")):
                depth += 1
            elif b == UInt8(ord(")")) or b == UInt8(ord("]")) or b == UInt8(ord("}")):
                depth -= 1
            elif b == UInt8(ord(";")) and depth == 0:
                break
            self.pos += 1
        if self.at_end():
            raise Error("InvalidSquirrelSyntax: unterminated write expression")
        var value = String(self.source[byte = value_start : self.pos])
        self.pos += 1  # consume ';'
        return FieldAccess(entity=entity, hops=hops^, field=field, write_value=String(value.strip()))

    def parse_init(mut self) raises:
        """Requires `self.pos` at the `@@` of `@@init()`, e.g. right after
        `find_next_marker` returns `MarkerKind.INIT`. Takes no arguments --
        just consumes the token; `sqrrl__init`'s doc comment (generated
        `sqrrl__Squirrel.mojo`) is where the actual construction happens."""
        if not self.try_consume("@@init"):
            raise Error("InvalidSquirrelSyntax: expected '@@init'")
        self.skip_trivia()
        if not self.try_consume("("):
            raise Error("InvalidSquirrelSyntax: expected '(' after '@@init'")
        self.skip_trivia()
        if not self.try_consume(")"):
            raise Error("InvalidSquirrelSyntax: '@@init' takes no arguments")

    def parse_world_marker(mut self) raises:
        """Requires `self.pos` at a bare `@@` sitting before `)`/`,`, e.g.
        right after `find_next_marker` returns `MarkerKind.WORLD`. Carries no
        data of its own -- just consumes the token."""
        if not self.try_consume("@@"):
            raise Error("InvalidSquirrelSyntax: expected '@@'")

    def parse_name_ref(mut self) raises -> NameRef:
        """Requires `self.pos` at the `@@` of a bare `@@name`, e.g. right
        after `find_next_marker` returns `MARKER_NAME_REF`."""
        if not self.try_consume("@@"):
            raise Error("InvalidSquirrelSyntax: expected '@@'")
        var name = self.scan_ident()
        if name.byte_length() == 0:
            raise Error("InvalidSquirrelSyntax: expected name")
        return NameRef(name=name)


def parse_fields(body: String) raises -> List[Field]:
    """Splits a `@@struct` body into `name: Type` fields. A relation field's
    name must itself be `@@`-marked (`@@employee: @@Employee`, not
    `employee: @@Employee`) so the marking stays consistent between a field's
    name and its type; the `@@` is stripped from the stored name."""
    var bs = Scanner(body)
    var fields = List[Field]()
    while True:
        bs.skip_trivia()
        if bs.at_end():
            break

        var name_is_marked = bs.try_consume("@@")
        var name = bs.scan_ident()
        if name.byte_length() == 0:
            raise Error("InvalidSquirrelSyntax: expected field name")

        for existing in fields:
            if existing.name == name:
                raise Error("DuplicateFieldName: " + name)

        bs.skip_trivia()
        if not bs.try_consume(":"):
            raise Error("InvalidSquirrelSyntax: expected ':' after field name")
        bs.skip_trivia()

        var type_str = bs.scan_type()
        if type_str.byte_length() == 0:
            raise Error("InvalidSquirrelSyntax: empty field type")

        var type_is_relation = type_str.startswith("@@")
        if name_is_marked != type_is_relation:
            raise Error(
                "InvalidSquirrelSyntax: @@ marking must match between field"
                " name and type"
            )

        fields.append(Field(name=name, type_str=type_str))
        _ = bs.try_consume(",")

    return fields^
