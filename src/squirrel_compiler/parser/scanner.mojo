from squirrel_compiler.parser.ast import (
    FieldModifier,
    Field,
    TypeParam,
    ParsedStruct,
    ConstructField,
    Construct,
    FieldAccess,
    NameRef,
    EntityParam,
    MarkerKind,
)
from squirrel_compiler.parser.text_utils import (
    is_ident_char,
    source_location,
    line_indent_of,
    is_after_arrow,
    is_after_for_keyword,
    is_after_container_bracket,
)
from squirrel_compiler.parser.field_parsing import (
    parse_fields,
    unqualify_self_type_params,
    parse_hand_written_struct_fields,
)


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
            raise bs.err(
                "InvalidSquirrelSyntax: expected '.' before field name in"
                " construct"
            )
        var is_relation = bs.try_consume("@@")
        var name = bs.scan_ident()
        if name.byte_length() == 0:
            raise bs.err("InvalidSquirrelSyntax: expected field name in construct")
        bs.skip_trivia()
        if not bs.try_consume("="):
            raise bs.err(
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

    def err(self, msg: String) -> Error:
        """Builds an `Error` prefixed with this scanner's current position
        (`source_location(self.source, self.pos)`) -- every raise site in
        this file does `raise self.err("...")` instead of `raise
        Error("...")`, so every `InvalidSquirrelSyntax` (and friends) says
        where in the source text it happened, not just that it did. Returns
        (rather than itself raising) so the call site keeps its own `raise`,
        same as constructing an `Error` directly."""
        return Error(source_location(self.source, self.pos) + ": " + msg)

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
        """If positioned at a `#` or `//` line comment or a `"`/`'` string
        literal, advances past it. No-op otherwise. `#` is real Mojo's own
        comment syntax; `//` is carried over from this compiler's original
        Zig-targeting version -- kept alongside `#` rather than replaced,
        since recognizing it costs nothing and a stray `//` in a string or
        elsewhere is already handled by the ordering here (checked before
        this function is reached, `//` only ever matters at a real code
        position). Undiscovered until a real `.rel` example first used a
        `#` comment mentioning `@@` and had it wrongly treated as a live
        marker -- no earlier example ever used a comment at all."""
        if self.at_end():
            return
        if self.peek() == UInt8(ord("#")) or (
            self.peek() == UInt8(ord("/")) and self.peek_at(1) == UInt8(ord("/"))
        ):
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
            raise self.err("InvalidSquirrelSyntax: expected '{'")
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
            raise self.err("InvalidSquirrelSyntax: unterminated '{'")
        return String(self.source[byte = body_start : self.pos - 1])

    def scan_indented_block(mut self, header_indent: Int) -> String:
        """Requires `self.pos` right after a block header's own trailing
        `:` (e.g. `@@struct @@Name:`). Consumes the rest of the header line
        (assumed empty beyond the `:`) plus every following line that's
        either blank or indented more than `header_indent`, matching
        Python/Mojo's own indentation-block convention -- stopping (without
        consuming) at the first non-blank line indented at or below
        `header_indent`, or at end of input. Returns the consumed span, from
        just after the header's own newline through just before the
        stopping line (or end of input) -- unlike `scan_braced_span`, there's
        no explicit closing token to exclude, so nothing needs trimming off
        the end."""
        while not self.at_end() and self.peek() != UInt8(ord("\n")):
            self.pos += 1
        if not self.at_end():
            self.pos += 1
        var body_start = self.pos
        var bytes = self.source.as_bytes()
        while not self.at_end():
            var line_start = self.pos
            var i = line_start
            while i < len(bytes) and (
                bytes[i] == UInt8(ord(" ")) or bytes[i] == UInt8(ord("\t"))
            ):
                i += 1
            var is_blank = i >= len(bytes) or bytes[i] == UInt8(ord("\n"))
            if not is_blank and (i - line_start) <= header_indent:
                break
            while not self.at_end() and self.peek() != UInt8(ord("\n")):
                self.pos += 1
            if not self.at_end():
                self.pos += 1
        return String(self.source[byte = body_start : self.pos])

    def scan_bracketed_span(mut self) raises -> String:
        """Requires `self.pos` at `[`. Returns the body between the matching
        brackets (exclusive), and advances `self.pos` past the closing `]`
        -- mirrors `scan_braced_span`, for `@@entity[index_expr]`."""
        if self.peek() != UInt8(ord("[")):
            raise self.err("InvalidSquirrelSyntax: expected '['")
        self.pos += 1
        var body_start = self.pos
        var depth = 1
        while not self.at_end() and depth > 0:
            var before = self.pos
            self.skip_non_code()
            if self.pos != before:
                continue
            var b = self.peek()
            if b == UInt8(ord("[")):
                depth += 1
            elif b == UInt8(ord("]")):
                depth -= 1
            self.pos += 1
        if depth != 0:
            raise self.err("InvalidSquirrelSyntax: unterminated '['")
        return String(self.source[byte = body_start : self.pos - 1])

    def scan_type(mut self) -> String:
        """Scans a field's type text: up to the next top-level `,` or `\\n`
        (ignoring either nested inside `[]`/`()`/`{}`) or the end of input.
        Trimmed. The `\\n` case is what lets `@@struct`'s newline-separated
        fields (no trailing comma required, one per line) terminate a type
        correctly; a comma-separated body (a plain struct's brace form)
        still stops at its comma first, on the same line, same as always."""
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
            elif b == UInt8(ord("\n")) and depth == 0:
                break
            self.pos += 1
        var raw = String(self.source[byte = start : self.pos])
        return String(raw.strip())

    def _scan_type_param_bound(mut self) -> String:
        """Like `scan_type`, but for a `[T: Bound, ...]` type-parameter
        list's own bound text specifically -- stops (without consuming) at
        a top-level `,` *or* a top-level closing `]`/`)`/`}`, rather than
        `scan_type`'s `,`/`\\n`. `scan_type` can't be reused here: its own
        depth counter starts at 0 assuming it's scanning a type that owns
        its *own* brackets, so hitting the type-parameter list's closing
        `]` (already consumed by the caller as the list's own delimiter,
        not part of any type this scans) would decrement past zero and
        keep consuming instead of stopping -- confirmed by direct
        inspection of what `scan_type` does at depth 0 on a closing
        bracket it didn't open."""
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
                if depth == 0:
                    break
                depth -= 1
            elif b == UInt8(ord(",")) and depth == 0:
                break
            self.pos += 1
        var raw = String(self.source[byte = start : self.pos])
        return String(raw.strip())

    def parse_type_params(mut self) raises -> List[TypeParam]:
        """Requires `self.pos` at `[` -- a plain struct's own `[T: Bound,
        ...]` type-parameter list, immediately after its name (shorthand
        or hand-written; an `@@struct` never has one). Returns the parsed
        list, advancing `self.pos` past the closing `]`. A parameter with
        no explicit `: Bound` gets `"Copyable & ImplicitlyDeletable"` --
        see `TypeParam`'s own doc comment for why."""
        if not self.try_consume("["):
            raise self.err("InvalidSquirrelSyntax: expected '['")
        var out = List[TypeParam]()
        self.skip_trivia()
        if self.try_consume("]"):
            return out^
        while True:
            self.skip_trivia()
            var name = self.scan_ident()
            if name.byte_length() == 0:
                raise self.err("InvalidSquirrelSyntax: expected type parameter name")
            self.skip_trivia()
            var bound = "Copyable & ImplicitlyDeletable"
            if self.try_consume(":"):
                self.skip_trivia()
                bound = self._scan_type_param_bound()
                if bound.byte_length() == 0:
                    raise self.err(
                        "InvalidSquirrelSyntax: expected type parameter bound after ':'"
                    )
            out.append(TypeParam(name=name, bound=bound))
            self.skip_trivia()
            if self.try_consume(","):
                continue
            if self.try_consume("]"):
                break
            raise self.err("InvalidSquirrelSyntax: expected ',' or ']' in type parameter list")
        return out^

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

    def peek_empty_call_follows(mut self) -> Bool:
        """True if, from `self.pos` (skipping trivia around both the `(`
        and `)`), an empty call `()` follows -- never moves `self.pos`
        permanently either way, since callers manage that differently
        afterward (one resets to a saved marker start and returns a marker
        kind, the other resets and returns a plain `Bool`). Shared by
        `find_next_marker`'s and `find_next_init_call`'s identical
        `@@init()` detection."""
        var save = self.pos
        self.skip_trivia()
        var matched = False
        if self.peek() == UInt8(ord("(")):
            self.pos += 1
            self.skip_trivia()
            matched = self.peek() == UInt8(ord(")"))
        self.pos = save
        return matched

    def find_next_declare_call(mut self) -> Bool:
        """Advances to the start of the next `@@{` call at real-code
        depth -- used only to *count* occurrences project-wide
        (`driver.check_single_declare_call`, which rejects more than one
        total: `@@{` is the single point that brings `sqrrl__world`
        into scope for a whole script, via `var sqrrl__world:
        sqrrl__World`, left deliberately uninitialized until whichever
        `@@init()`/`@@start_init_from_json(...)` call(s) follow it assign
        into it -- see `rewrite_markers`'s `MarkerKind.DECLARE` handling),
        not to parse or consume anything else about the surrounding
        source, so it doesn't need the full marker-dispatch loop
        `transform_source` runs. Returns `False` (leaving `self.pos` at the
        end) if there isn't one, otherwise `True`, with `self.pos` left at
        its start (matching `find_next_marker`'s own convention) for the
        caller to parse and consume."""
        while True:
            self.skip_trivia()
            if self.at_end():
                return False
            if self.starts_with("@@{"):
                return True
            if self.starts_with("@@"):
                self.pos += 2
                continue
            self.pos += 1

    def at_bare_struct_keyword(self) -> Bool:
        """True if `self.pos` sits at a bare `struct` keyword occurrence
        (not `@@struct`) with a word boundary on both sides -- not preceded
        by an identifier char or by `@@`, not followed by an identifier
        char -- so `construct`, `MyStructType`, or a real `@@struct` aren't
        mistaken for it. Shared by `find_next_plain_struct_decl` and
        `find_next_plain_struct_name`, which differ only in what they do
        once they've found one (parse a shorthand body's fields vs. just
        take the name)."""
        if not self.starts_with("struct"):
            return False
        var before_is_ident = self.pos > 0 and is_ident_char(self.byte_at(self.pos - 1))
        var before_is_at = self.pos >= 2 and self.byte_at(self.pos - 1) == UInt8(
            ord("@")
        ) and self.byte_at(self.pos - 2) == UInt8(ord("@"))
        var after = self.pos + String("struct").byte_length()
        var after_is_ident = after < self.source.byte_length() and is_ident_char(
            self.byte_at(after)
        )
        return not before_is_ident and not before_is_at and not after_is_ident

    def find_next_plain_struct_decl(mut self) raises -> Bool:
        """Advances to the start of the next bare `struct` occurrence (not
        `@@struct`) at real-code depth, *only* if its body uses the same
        brace-delimited shorthand grammar `@@struct` bodies do (`struct Name
        { field: Type, ... }`) -- an ordinary Mojo struct a `.rel` file
        defines directly, outside the managed-table DSL. It never gets a
        generated Table/State pair the way `@@struct` does; this exists
        purely so `check_no_relation_cycles` can see whether such a
        struct's body smuggles a `@@`-marked relation field that would
        otherwise be an invisible way to complete a construction cycle back
        through a real `@@struct` (a plain field elsewhere naming this
        struct wouldn't reveal that on its own).

        A *real*, hand-written Mojo struct (`struct Name(Traits...):` or
        `struct Name:`, followed by an indented `var` block, not `{`) is
        left invisible here rather than raising a parse error -- confirmed:
        `scan_braced_span` unconditionally requiring `{` right after the
        name used to abort the *entire* `convert_directory` run the moment
        any `.rel` file declared an ordinary Mojo struct anywhere, since
        that's the only way to declare a non-generated helper type at all.
        A relation smuggled through a real (non-shorthand) plain struct's
        own fields still isn't caught *here* -- but it isn't invisible to
        `check_no_relation_cycles` overall either:
        `driver.discover_hand_written_plain_structs`
        (`Scanner.find_next_hand_written_plain_struct_decl`/
        `parse_hand_written_plain_struct`) is the separate pass that
        covers this form, recovering a hand-written field's own
        `EntityHandle[sqrrl__PersonTableState]` spelling back to the
        pseudo `@@Person` shape the cycle graph already understands.
        Returns False (leaving `self.pos` at the end) if there isn't
        a brace-shorthand one. A generic plain struct's own `[T: Bound,
        ...]` list (if any) sits between the name and the `{`/non-`{`
        that decides shorthand vs hand-written -- skipped here via
        `parse_type_params` (discarding the result) purely to see past it
        to whatever follows."""
        while True:
            self.skip_trivia()
            if self.at_end():
                return False
            if self.at_bare_struct_keyword():
                var struct_start = self.pos
                var after = self.pos + String("struct").byte_length()
                self.pos = after
                self.skip_trivia()
                var name = self.scan_ident()
                self.skip_trivia()
                if name.byte_length() > 0 and self.peek() == UInt8(ord("[")):
                    _ = self.parse_type_params()
                    self.skip_trivia()
                var is_shorthand = name.byte_length() > 0 and self.peek() == UInt8(ord("{"))
                if is_shorthand:
                    self.pos = struct_start
                    return True
                self.pos = after
                continue
            self.pos += 1

    def find_next_plain_struct_name(mut self) -> Optional[String]:
        """Advances past the next bare `struct Name` occurrence (not
        `@@struct`) and returns `Name`, regardless of what follows it -- a
        brace-shorthand body (`{ ... }`) or a real, hand-written Mojo one
        (`(Traits...):`/`:` + an indented `var` block). Unlike
        `find_next_plain_struct_decl`, this never needs to parse the body
        at all, just the name -- used only to know a plain struct's name
        and declaring file for cross-file import purposes
        (`driver.build_cross_file_symbols`), which doesn't care whether the
        body is parseable the way `check_no_relation_cycles` does. Returns
        `None` (leaving `self.pos` at the end) once there are no more."""
        while True:
            self.skip_trivia()
            if self.at_end():
                return None
            if self.at_bare_struct_keyword():
                var after = self.pos + String("struct").byte_length()
                self.pos = after
                self.skip_trivia()
                var name = self.scan_ident()
                if name.byte_length() > 0:
                    return name
                continue
            self.pos += 1

    def parse_struct(mut self) raises -> ParsedStruct:
        """Requires `self.pos` at the `@@struct` token, e.g. right after
        `find_next_struct_decl` returns True. Grammar: `@@struct [keepalive]
        @@Name:` followed by an indented block of newline-separated fields
        (no commas) -- real Mojo's own struct-header shape, unlike the plain
        shorthand struct's brace-delimited body (see `parse_plain_struct`).
        The name is `@@`-marked (`@@struct @@Department:`, not `@@struct
        Department:`) for the same reason a relation field's own name is --
        every place an entity-struct's name appears stays consistently
        `@@`-prefixed, matching `@@Department{...}`/`@@dept: @@Department`."""
        var header_indent = line_indent_of(self.source, self.pos)
        if not self.try_consume("@@struct"):
            raise self.err("InvalidSquirrelSyntax: expected '@@struct'")
        self.skip_trivia()
        var is_keepalive = False
        if self.starts_with("keepalive") and not is_ident_char(self.peek_at(9)):
            self.pos += 9
            self.skip_trivia()
            is_keepalive = True
        if not self.try_consume("@@"):
            raise self.err("InvalidSquirrelSyntax: expected '@@' before struct name ('@@struct @@Name:')")
        var name = self.scan_ident()
        if name.byte_length() == 0:
            raise self.err("InvalidSquirrelSyntax: expected struct name")
        self.skip_trivia()
        if not self.try_consume(":"):
            raise self.err("InvalidSquirrelSyntax: expected ':' after struct name")
        var body = self.scan_indented_block(header_indent)
        var fields = parse_fields(body)
        return ParsedStruct(name=name, fields=fields^, is_keepalive=is_keepalive)

    def parse_plain_struct(mut self) raises -> ParsedStruct:
        """Requires `self.pos` at the bare `struct` token, e.g. right after
        `find_next_plain_struct_decl` returns True. Unlike `parse_struct`,
        this keeps the brace-delimited shorthand grammar (`struct Name {
        field: Type, ... }`) -- a plain struct never gets a generated table,
        so there's no `@@`-marked name either (it isn't itself a tracked
        entity type). An optional `[T: Bound, ...]` type-parameter list
        (`parse_type_params`) sits between the name and the `{` -- a field
        can then use `T` bare (`value: T`), the intended shorthand style,
        same as any other type. Also tolerates a field spelled out with
        the real-Mojo `Self.T` qualification instead (`unqualify_self_type_params`
        normalizes either spelling to the same bare form) -- harmless
        either way for a *shorthand* struct (unlike a hand-written one,
        where `Self.T` is the only form Mojo itself accepts), but
        skipping the normalization here would double-qualify it right
        back to `Self.Self.T` when `emit_plain_struct` adds its own
        `Self.` prefix, and would leak a literal `Self.T` into
        `emit_plain_struct_from_json`'s generated companion -- a free
        function, where `Self` doesn't exist at all (confirmed both
        failure modes directly)."""
        if not self.try_consume("struct"):
            raise self.err("InvalidSquirrelSyntax: expected 'struct'")
        self.skip_trivia()
        var name = self.scan_ident()
        if name.byte_length() == 0:
            raise self.err("InvalidSquirrelSyntax: expected struct name")
        self.skip_trivia()
        var type_params = List[TypeParam]()
        if self.peek() == UInt8(ord("[")):
            type_params = self.parse_type_params()
            self.skip_trivia()
        var body = self.scan_braced_span()
        var raw_fields = parse_fields(body)
        var fields = List[Field]()
        for field in raw_fields:
            fields.append(
                Field(
                    name=field.name,
                    type_str=unqualify_self_type_params(field.type_str, type_params),
                    modifier=field.modifier,
                )
            )
        return ParsedStruct(name=name, fields=fields^, type_params=type_params^)

    def find_next_hand_written_plain_struct_decl(mut self) raises -> Bool:
        """Advances to the start of the next bare `struct Name(...):`/
        `struct Name:` occurrence (not `@@struct`, and not the brace-
        shorthand form `find_next_plain_struct_decl` already handles) -- a
        *real*, hand-written Mojo struct. Used by two independent
        consumers of its body: `driver.build_plain_struct_fields` (so
        `from_json` codegen knows its field list, to serialize/deserialize
        a field of this type correctly instead of raising at runtime --
        see `parse_hand_written_plain_struct`) and
        `driver.discover_hand_written_plain_structs` (so
        `check_no_relation_cycles` can see a relation smuggled through
        one too, closing the gap `find_next_plain_struct_decl`'s own doc
        comment used to describe as accepted). Returns False (leaving
        `self.pos` at the end) once there are none left."""
        while True:
            self.skip_trivia()
            if self.at_end():
                return False
            if self.at_bare_struct_keyword():
                var struct_start = self.pos
                var after = self.pos + String("struct").byte_length()
                self.pos = after
                self.skip_trivia()
                var name = self.scan_ident()
                self.skip_trivia()
                if name.byte_length() == 0:
                    self.pos = after
                    continue
                if self.peek() == UInt8(ord("[")):
                    # A generic struct's own `[T: Bound, ...]` sits before
                    # either the `{` this loop is checking for below, or
                    # the `(Traits...)`/`:` `parse_hand_written_plain_struct`
                    # handles -- skip past it here too, purely to see past
                    # it to whichever of those actually follows.
                    _ = self.parse_type_params()
                    self.skip_trivia()
                if self.peek() == UInt8(ord("{")):
                    # Brace shorthand -- already handled by
                    # `find_next_plain_struct_decl`/`discover_plain_structs`
                    # elsewhere; skip past its whole body so it isn't seen
                    # (or double-counted) here too.
                    _ = self.scan_braced_span()
                    continue
                self.pos = struct_start
                return True
            self.pos += 1

    def parse_hand_written_plain_struct(mut self) raises -> ParsedStruct:
        """Requires `self.pos` at the bare `struct` token of a hand-written
        (non-brace) plain struct, e.g. right after
        `find_next_hand_written_plain_struct_decl` returns True. Extracts
        the struct's own name, its own optional `[T: Bound, ...]`
        type-parameter list (`parse_type_params` -- real Mojo syntax
        order: type parameters before the parenthesized trait list), and
        its leading `var name: Type` field declarations (see
        `parse_hand_written_struct_fields`), skipping over an optional
        parenthesized trait list (`(Copyable, Movable, ...)`) between that
        and the header's own trailing `:`. A best-effort structural read,
        not a full Mojo parse -- enough for `from_json` to know this
        struct's own fields, the one thing `sqrrl__from_json[T]`'s generic
        dispatcher can't do for any struct (see its own doc comment in
        `emit_json_module`).

        A field referencing the struct's own type parameter has to say
        `Self.T` in real, hand-written Mojo (Mojo's own requirement, not
        this DSL's -- see `unqualify_self_type_params`'s own doc comment),
        but the extracted field list feeds a *free function*
        (`emit_plain_struct_from_json`'s generated companion), where
        `Self` doesn't exist at all -- so every field's own `type_str` is
        unqualified back to bare `T` right here, once, rather than
        leaving every downstream consumer of this struct's fields to
        remember to do it."""
        var header_indent = line_indent_of(self.source, self.pos)
        if not self.try_consume("struct"):
            raise self.err("InvalidSquirrelSyntax: expected 'struct'")
        self.skip_trivia()
        var name = self.scan_ident()
        if name.byte_length() == 0:
            raise self.err("InvalidSquirrelSyntax: expected struct name")
        self.skip_trivia()
        var type_params = List[TypeParam]()
        if self.peek() == UInt8(ord("[")):
            type_params = self.parse_type_params()
            self.skip_trivia()
        if self.peek() == UInt8(ord("(")):
            var depth = 0
            while not self.at_end():
                var b = self.peek()
                self.pos += 1
                if b == UInt8(ord("(")):
                    depth += 1
                elif b == UInt8(ord(")")):
                    depth -= 1
                    if depth == 0:
                        break
            self.skip_trivia()
        if not self.try_consume(":"):
            raise self.err("InvalidSquirrelSyntax: expected ':' after struct name")
        var body = self.scan_indented_block(header_indent)
        var raw_fields = parse_hand_written_struct_fields(body)
        var fields = List[Field]()
        for field in raw_fields:
            fields.append(
                Field(
                    name=field.name,
                    type_str=unqualify_self_type_params(field.type_str, type_params),
                    modifier=field.modifier,
                )
            )
        return ParsedStruct(name=name, fields=fields^, type_params=type_params^)

    def find_next_marker(mut self) raises -> MarkerKind:
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

        Seven more kinds beyond the original four, all driven by Mojo
        having no mutable global/static state (see `Table`'s doc comment in
        `entity.mojo`): `@@{` (`MarkerKind.DECLARE`) brings
        `sqrrl__world` into scope, uninitialized, exactly once per script
        -- required before any `@@init()`/`@@start_init_from_json(...)`
        call (see those two immediately below), specifically so a script
        can choose between them conditionally (`if restoring_from_disk:
        @@start_init_from_json(dump); else: @@init();`) with Mojo's own
        definite-initialization checking (not a hand-rolled control-flow
        analysis here) catching a branch that forgot to initialize it.
        `@@init()` (`MarkerKind.INIT`) is the explicit call a script makes
        to obtain `sqrrl__World`'s shared instance. `@@start_init_from_json(json)`
        (`MarkerKind.START_INIT_FROM_JSON`) is its reload counterpart,
        obtaining that same shared instance by reconstructing it from a
        JSON dump (`sqrrl__world_from_json`) instead of building an empty
        one -- checked *before* the ordinary `@@name(`/`MarkerKind.
        WORLD_FUNC` case below, since it would otherwise look identical (a
        `@@`-marked name immediately followed by `(`). Either one may be
        called any number of times, in any control-flow shape, after
        `@@{` -- each one assigns into the already-declared
        `sqrrl__world`, dropping whatever it held before (see
        `rewrite_markers`'s `MarkerKind.INIT`/`START_INIT_FROM_JSON`
        handling). `@@finalize_init_from_json()`
        (`MarkerKind.FINALIZE_INIT_FROM_JSON`) drops every entity a prior
        `@@start_init_from_json(...)` retained only temporarily (see
        `TempKeepAlives`, `driver.emit_world_module`) -- optional, and
        valid after either form of `@@init`, not just the reload one (a
        no-op if there's nothing temporary to drop). `@@name(` (`MarkerKind.WORLD_FUNC`, e.g. `def @@make_department(a:
        Int)` or, at a call site, `@@make_department(x)`) marks a function
        whose *own name* -- not a separate parameter -- signals that it
        needs `sqrrl__world`: a definition gets it auto-inserted as its
        first parameter, a call site gets it auto-inserted as its first
        argument, both silently, so neither the signature nor the call
        needs a separate `@@` token the way an ordinary parameter would.
        `@@name: @@Type` (`MarkerKind.ENTITY_PARAM`, e.g. `def example(a:
        Int, @@test: @@Test)`) is how a *different* function's own
        parameter list -- or a local variable declaration, `var @@dept:
        @@Department = @@make_department();` -- opts an already-constructed
        entity into scope, same shape as a `@@struct` relation field, just
        written in a signature or a `var` declaration instead of a struct
        body, and `@@Type:` sitting right after `->` (`MarkerKind.
        RETURN_TYPE`, e.g. `def @@make_department() raises -> @@Department:`)
        is how a function's own return type is marked as yielding an
        entity. `@@init` not immediately followed by `()`, or `@@name:` not
        followed by another `@@` and not sitting right after `->`, falls
        through to ordinary name-ref handling instead -- a variable
        literally named `init`, or one immediately followed by an ordinary
        (non-`@@`) type annotation somewhere that isn't a return type,
        isn't either of these markers. Returns `MarkerKind.NONE` at end of
        input."""
        while True:
            self.skip_trivia()
            if self.at_end():
                return MarkerKind.NONE
            if self.starts_with("@@struct"):
                return MarkerKind.STRUCT
            if self.at_bare_struct_keyword():
                # A shorthand plain struct (`struct Name { field: Type,
                # ... }`) needs its own marker: without this, this same
                # scanning loop walks straight past its opening `struct
                # Name {` as ordinary text, then finds any `@@`-marked
                # field *inside* it as an independent marker later --
                # confirmed empirically indistinguishable from
                # `MarkerKind.ENTITY_PARAM`, since `@@name: @@Type` is
                # recognized as that shape wherever it occurs, not just in
                # a signature or `var` declaration. Checking here, in the
                # same single pass, means a real hand-written Mojo struct
                # (no `{` right after the name) is left alone exactly like
                # today -- only the brace-shorthand form is claimed.
                var save = self.pos
                var after_struct = self.pos + String("struct").byte_length()
                self.pos = after_struct
                self.skip_trivia()
                var name = self.scan_ident()
                self.skip_trivia()
                if name.byte_length() > 0 and self.peek() == UInt8(ord("[")):
                    # A generic plain struct's own `[T: Bound, ...]` sits
                    # before the `{` this is checking for -- skip past it
                    # (discarding the result) purely to see past it, same
                    # as `find_next_plain_struct_decl`/
                    # `find_next_hand_written_plain_struct_decl` already
                    # do for their own, separate shorthand-vs-not checks.
                    _ = self.parse_type_params()
                    self.skip_trivia()
                var is_shorthand = name.byte_length() > 0 and self.peek() == UInt8(ord("{"))
                self.pos = save
                if is_shorthand:
                    return MarkerKind.PLAIN_STRUCT
                self.pos = after_struct
                continue
            if self.starts_with("@@{"):
                return MarkerKind.DECLARE
            if self.starts_with("@@}"):
                return MarkerKind.UNDECLARE
            if self.starts_with("@@"):
                var marker_start = self.pos
                self.pos += 2
                var ident_start = self.pos
                var ident = self.scan_ident()
                if self.pos == ident_start:
                    # Bare "@@" with no identifier -- stray noise; step past
                    # it so the outer loop makes progress.
                    self.pos = marker_start + 1
                    continue
                if ident == "declare" and self.peek_empty_call_follows():
                    self.pos = marker_start
                    return MarkerKind.DECLARE
                if ident == "undeclare" and self.peek_empty_call_follows():
                    self.pos = marker_start
                    return MarkerKind.UNDECLARE
                if ident == "init" and self.peek_empty_call_follows():
                    self.pos = marker_start
                    return MarkerKind.INIT
                if ident == "start_init_from_json":
                    self.pos = marker_start
                    return MarkerKind.START_INIT_FROM_JSON
                if ident == "init_from_json":
                    self.pos = marker_start
                    return MarkerKind.INIT_FROM_JSON
                if ident == "finalize_init_from_json" and self.peek_empty_call_follows():
                    self.pos = marker_start
                    return MarkerKind.FINALIZE_INIT_FROM_JSON
                self.skip_trivia()
                var kind: MarkerKind
                if self.peek() == UInt8(ord("{")):
                    kind = MarkerKind.CONSTRUCT
                elif self.peek() == UInt8(ord(".")) or self.peek() == UInt8(ord("[")):
                    kind = MarkerKind.FIELD_ACCESS
                elif self.peek() == UInt8(ord("(")):
                    kind = MarkerKind.WORLD_FUNC
                elif self.peek() == UInt8(ord(":")):
                    var save_colon = self.pos
                    self.pos += 1
                    self.skip_trivia()
                    # `is_after_arrow` is checked *before* the "does a `@@`
                    # follow this colon" test, not after -- `-> @@Type:`
                    # always ends the `def`/`for` header line, with a
                    # newline before whatever comes next, so it's never
                    # itself the start of a genuine same-line `@@name:
                    # @@Type` shape. Checking `starts_with("@@")` first
                    # used to misfire when a `@@`-returning function's very
                    # first body statement happened to start with another
                    # `@@`-marker (`skip_trivia` crosses the intervening
                    # newline too, so it would find that *next* marker and
                    # wrongly conclude *this* one was `@@name: @@Type`
                    # instead of a return type) -- confirmed via a
                    # `-> @@Employee:` immediately followed by
                    # `@@e.title = ...` on the next line.
                    if is_after_arrow(self.source, marker_start):
                        kind = MarkerKind.RETURN_TYPE
                    elif self.starts_with("@@"):
                        kind = MarkerKind.ENTITY_PARAM
                    elif self.at_wrapped_entity_param():
                        kind = MarkerKind.ENTITY_PARAM
                    else:
                        kind = MarkerKind.NAME_REF
                    self.pos = save_colon
                elif self.peek() == UInt8(ord("]")):
                    # `@@Type` sitting inside `Ident[...]` -- a generic
                    # type-argument position, wherever it occurs: a return
                    # type (`-> List[@@Type]:`), a parameter type (`items:
                    # List[@@Type]`), or a bare generic-instantiation
                    # expression (`List[@@Type]()`). The marker sits
                    # *inside* the container brackets (already scanned past
                    # on an earlier iteration as ordinary text), so only
                    # the backward (`Ident[`) context needs checking --
                    # unlike a plain list literal, `[@@alice, @@bob]`,
                    # which has no identifier immediately before its `[`
                    # and keeps the ordinary `MarkerKind.NAME_REF` fallback.
                    if is_after_container_bracket(self.source, marker_start):
                        kind = MarkerKind.RETURN_TYPE
                    else:
                        kind = MarkerKind.NAME_REF
                elif self.peek() == UInt8(ord(",")) and is_after_container_bracket(self.source, marker_start):
                    # Same shape as the `]` case just above, but `@@Type`
                    # isn't the *last* type parameter -- `Dict[@@Type, V]`,
                    # not just `List[@@Type]`. Still sits right inside
                    # `Ident[`, so the same backward check applies; a plain
                    # list literal's first element (`[@@alice, @@bob]`) is
                    # also followed by `,` but has no identifier before its
                    # own `[`, so `is_after_container_bracket` already tells
                    # the two apart correctly.
                    kind = MarkerKind.RETURN_TYPE
                elif (
                    self.starts_with("in")
                    and not is_ident_char(self.peek_at(2))
                    and is_after_for_keyword(self.source, marker_start)
                ):
                    # `for @@name in ...:` -- the loop's own target variable,
                    # bound to the iterated expression's *element* type
                    # (unlike `var @@name = ...`, which binds to the whole
                    # return type) once codegen sees what follows `in`.
                    kind = MarkerKind.FOR_ENTITY_LOOP
                else:
                    kind = MarkerKind.NAME_REF
                self.pos = marker_start
                return kind
            self.pos += 1

    def at_wrapped_entity_param(mut self) -> Bool:
        """True if, from the current position, the text matches
        `Ident[@@` -- a container-wrapped entity-param type
        (`List[@@Person]`, `InlineArray[@@Person]`, or any other container
        identifier), which `find_next_marker`'s `:` branch also classifies
        as `MarkerKind.ENTITY_PARAM`, alongside the bare `@@name: @@Type`
        form. Restores `self.pos` before returning either way -- purely a
        lookahead."""
        var save = self.pos
        var wrapper = self.scan_ident()
        if wrapper.byte_length() == 0:
            self.pos = save
            return False
        self.skip_trivia()
        if self.peek() != UInt8(ord("[")):
            self.pos = save
            return False
        self.pos += 1
        self.skip_trivia()
        var result = self.starts_with("@@")
        self.pos = save
        return result

    def parse_entity_param(mut self) raises -> EntityParam:
        """Requires `self.pos` at the `@@` of `@@name: @@Type` (or the
        container form, `@@name: Container[@@Type]`), e.g. right after
        `find_next_marker` returns `MarkerKind.ENTITY_PARAM`."""
        if not self.try_consume("@@"):
            raise self.err("InvalidSquirrelSyntax: expected '@@'")
        var name = self.scan_ident()
        if name.byte_length() == 0:
            raise self.err("InvalidSquirrelSyntax: expected entity parameter name")
        self.skip_trivia()
        if not self.try_consume(":"):
            raise self.err("InvalidSquirrelSyntax: expected ':' after entity parameter name")
        self.skip_trivia()

        var wrapper: Optional[String] = None
        if not self.starts_with("@@"):
            var w = self.scan_ident()
            if w.byte_length() == 0:
                raise self.err("InvalidSquirrelSyntax: expected '@@Type' or 'Container[@@Type]' after ':'")
            self.skip_trivia()
            if not self.try_consume("["):
                raise self.err("InvalidSquirrelSyntax: expected '[' after '" + w + "'")
            self.skip_trivia()
            wrapper = w

        if not self.try_consume("@@"):
            raise self.err("InvalidSquirrelSyntax: expected '@@Type' after ':'")
        var type_name = self.scan_ident()
        if type_name.byte_length() == 0:
            raise self.err("InvalidSquirrelSyntax: expected entity parameter type")

        if wrapper:
            self.skip_trivia()
            if not self.try_consume("]"):
                raise self.err("InvalidSquirrelSyntax: expected ']' after '" + wrapper.value() + "[@@" + type_name + "'")

        return EntityParam(name=name, type_name=type_name, wrapper=wrapper)

    def parse_construct(mut self) raises -> Construct:
        """Requires `self.pos` at the `@@` of a `@@TypeName { ... }`
        construct, e.g. right after `find_next_marker` returns
        `MARKER_CONSTRUCT`."""
        if not self.try_consume("@@"):
            raise self.err("InvalidSquirrelSyntax: expected '@@'")
        var type_name = self.scan_ident()
        if type_name.byte_length() == 0:
            raise self.err("InvalidSquirrelSyntax: expected type name")
        self.skip_trivia()
        var body = self.scan_braced_span()
        return Construct(type_name=type_name, fields=parse_construct_fields(body))

    def parse_field_access(mut self) raises -> FieldAccess:
        """Requires `self.pos` at the `@@` of `@@entity.field` (or a chain,
        `@@entity.@@relation.field`, ...), e.g. right after
        `find_next_marker` returns `MARKER_FIELD_ACCESS`. Loops consuming
        `.@@relation` segments (each an intermediate hop, collected into
        `FieldAccess.hops`) until it hits a `.` followed by a *plain*
        (non-`@@`) identifier -- that one is the terminal `field`, read,
        written (if followed by `=`), or called (if followed by `(`, see
        `FieldAccess.is_call`). Neither a read nor a call consumes anything
        past the terminal identifier -- codegen splices its own rewritten
        prefix in and lets whatever follows (a call's `(args)`, or nothing
        at all for a read) pass through the normal copy loop unchanged.

        An indexed entity (`@@matches[0]`) not followed by `.` at all --
        used as a value in its own right, not the start of a field chain --
        returns early with `field=""` (see that check just below) instead
        of falling into the loop, which would otherwise demand a `.`."""
        if not self.try_consume("@@"):
            raise self.err("InvalidSquirrelSyntax: expected '@@'")
        var entity = self.scan_ident()
        if entity.byte_length() == 0:
            raise self.err("InvalidSquirrelSyntax: expected entity name")

        var index_expr: Optional[String] = None
        self.skip_trivia()
        if self.peek() == UInt8(ord("[")):
            index_expr = self.scan_bracketed_span()

        if index_expr:
            var save = self.pos
            self.skip_trivia()
            if self.peek() != UInt8(ord(".")):
                # A bare indexed reference, `@@matches[0]`, used as a value
                # in its own right (an argument, the RHS of a plain `var
                # x = ...`, ...) rather than as the start of a further
                # `.field` chain -- `field=""` is the sentinel for this
                # (never a legitimate field name; `scan_ident` returning
                # empty already raises everywhere else a real field name is
                # expected, so this can't collide with one).
                self.pos = save
                return FieldAccess(
                    entity=entity,
                    hops=List[String](),
                    field="",
                    field_marked=False,
                    write_value=None,
                    is_call=False,
                    index_expr=index_expr,
                )

        var hops = List[String]()
        var field: String
        var field_marked: Bool
        while True:
            self.skip_trivia()
            if not self.try_consume("."):
                raise self.err(
                    "InvalidSquirrelSyntax: expected '.' after entity/relation"
                    " name"
                )
            self.skip_trivia()
            if self.try_consume("@@"):
                var hop = self.scan_ident()
                if hop.byte_length() == 0:
                    raise self.err(
                        "InvalidSquirrelSyntax: expected relation field name"
                        " after '@@'"
                    )
                # A further `.` continues the chain (this hop is an
                # intermediate relation, its target's own field/hop comes
                # next); anything else ends it here, with *this* hop as the
                # terminal `field` instead of an intermediate one --
                # `@@alice.@@dept` (nothing after) reads the relation
                # itself, marked (`field_marked`) the same way an
                # intermediate hop always is -- unlike a bare `.dept`,
                # which is an ordinary, untracked field read regardless of
                # what `dept`'s own type happens to be.
                var save = self.pos
                self.skip_trivia()
                if self.peek() == UInt8(ord(".")):
                    self.pos = save
                    hops.append(hop)
                    continue
                self.pos = save
                field = hop
                field_marked = True
                break
            field = self.scan_ident()
            if field.byte_length() == 0:
                raise self.err("InvalidSquirrelSyntax: expected field name")
            field_marked = False
            break
        var after_field = self.pos

        self.skip_trivia()
        if self.peek() == UInt8(ord("(")):
            self.pos = after_field
            return FieldAccess(
                entity=entity,
                hops=hops^,
                field=field,
                field_marked=field_marked,
                write_value=None,
                is_call=True,
                index_expr=index_expr,
            )

        var is_write = self.peek() == UInt8(ord("=")) and self.peek_at(1) != UInt8(ord("="))
        if not is_write:
            self.pos = after_field
            return FieldAccess(
                entity=entity,
                hops=hops^,
                field=field,
                field_marked=field_marked,
                write_value=None,
                is_call=False,
                index_expr=index_expr,
            )

        self.pos += 1  # consume '='
        self.skip_whitespace()
        var value_start = self.pos
        var depth = 0
        var hit_semicolon = False
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
            elif depth == 0 and b == UInt8(ord(";")):
                hit_semicolon = True
                break
            elif depth == 0 and b == UInt8(ord("\n")):
                # A bare newline ends the write value exactly like `;`
                # does, just without consuming it (unlike `;`, it's real
                # source text the normal copy-through still needs to
                # reproduce) -- the semicolon stays optional the same way
                # it already is everywhere else; only an unbalanced
                # `(`/`[`/`{` still needs an explicit close, which the
                # `depth != 0` check below still catches regardless of
                # which terminator (or end of input) it ran into.
                break
            self.pos += 1
        if depth != 0:
            raise self.err("InvalidSquirrelSyntax: unterminated write expression")
        var value = String(self.source[byte = value_start : self.pos])
        if hit_semicolon:
            self.pos += 1  # consume ';'
        return FieldAccess(
            entity=entity,
            hops=hops^,
            field=field,
            field_marked=field_marked,
            write_value=String(value.strip()),
            is_call=False,
            index_expr=index_expr,
        )

    def parse_declare(mut self) raises:
        """Requires `self.pos` at the `@@` of `@@{`, e.g. right after
        `find_next_marker` returns `MarkerKind.DECLARE`. Just consumes the
        3-byte token; `rewrite_markers`'s own `MarkerKind.DECLARE` handling
        is where `var sqrrl__world = sqrrl__init()` and the opening `try:`
        actually get emitted. Deliberately brace-shaped rather than a
        `@@{` call: everything from here to the matching `@@}` is
        visibly one block, and -- unlike the old call-syntax version --
        this compiler does *not* re-indent that block for you. Write the
        body already indented one level deeper, exactly as you would for a
        hand-written `try:`; `@@{`/`@@}` just supply the boilerplate
        `try:`/`finally:` lines themselves, verbatim at whatever column
        they're written."""
        if not self.try_consume("@@{"):
            raise self.err("InvalidSquirrelSyntax: expected '@@{'")

    def parse_undeclare(mut self) raises:
        """Requires `self.pos` at the `@@` of `@@}`, e.g. right after
        `find_next_marker` returns `MarkerKind.UNDECLARE`. Just consumes the
        3-byte token; `rewrite_markers`'s own `MarkerKind.UNDECLARE`
        handling is where closing the `try:` `@@{` opened (with a `finally:`
        that checks for leaks) actually happens."""
        if not self.try_consume("@@}"):
            raise self.err("InvalidSquirrelSyntax: expected '@@}'")

    def parse_init(mut self) raises:
        """Requires `self.pos` at the `@@` of `@@init()`, e.g. right after
        `find_next_marker` returns `MarkerKind.INIT`. Takes no arguments --
        just consumes the token; `sqrrl__init`'s doc comment (generated
        `sqrrl__world.mojo`) is where the actual construction happens."""
        if not self.try_consume("@@init"):
            raise self.err("InvalidSquirrelSyntax: expected '@@init'")
        self.skip_trivia()
        if not self.try_consume("("):
            raise self.err("InvalidSquirrelSyntax: expected '(' after '@@init'")
        self.skip_trivia()
        if not self.try_consume(")"):
            raise self.err("InvalidSquirrelSyntax: '@@init' takes no arguments")

    def _parse_json_call_arg(mut self, call_text: String) raises -> String:
        """Shared by `parse_start_init_from_json`/`parse_init_from_json`:
        requires `self.pos` right after the call's own opening `(` (each
        caller already consumed its own distinct leading token and that
        `(` before calling this). Scans through the matching `)` at
        real-code depth and returns the argument's raw text, trimmed,
        unparsed otherwise -- codegen splices it straight into
        `sqrrl__world_from_json(sqrrl__JsonScanner(<expr>))`, so whatever
        expression shape Mojo itself accepts there just works, the same
        way `@@Type { ... }` construct field values are never themselves
        parsed as anything but opaque text. `call_text` (the caller's own
        name, `"@@start_init_from_json"` or `"@@init_from_json"`) only
        appears in the two error messages, so each reads correctly."""
        var start = self.pos
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
                if depth == 0:
                    break
                depth -= 1
            self.pos += 1
        if self.at_end():
            raise self.err("InvalidSquirrelSyntax: unterminated '" + call_text + "(...)' call")
        var raw = String(self.source[byte = start : self.pos]).strip()
        if raw.byte_length() == 0:
            raise self.err("InvalidSquirrelSyntax: '" + call_text + "' requires one argument")
        self.pos += 1  # consume ')'
        return String(raw)

    def parse_start_init_from_json(mut self) raises -> String:
        """Requires `self.pos` at the `@@` of `@@start_init_from_json(<expr>)`,
        e.g. right after `find_next_marker` returns
        `MarkerKind.START_INIT_FROM_JSON` -- `@@init()`'s reload
        counterpart, taking one `String` argument (a JSON dump, however the
        caller obtained it: a literal, a variable, a function call, ...)
        instead of none."""
        if not self.try_consume("@@start_init_from_json"):
            raise self.err("InvalidSquirrelSyntax: expected '@@start_init_from_json'")
        self.skip_trivia()
        if not self.try_consume("("):
            raise self.err("InvalidSquirrelSyntax: expected '(' after '@@start_init_from_json'")
        self.skip_trivia()
        return self._parse_json_call_arg("@@start_init_from_json")

    def parse_init_from_json(mut self) raises -> String:
        """Requires `self.pos` at the `@@` of `@@init_from_json(<expr>)`,
        e.g. right after `find_next_marker` returns
        `MarkerKind.INIT_FROM_JSON` -- `@@start_init_from_json(...)`
        immediately followed by `@@finalize_init_from_json()`, both in one
        call, for the common case where nothing needs grabbing from the
        reload beyond whatever real relation fields/`keepalive` tags
        already keep alive on their own. Same argument shape as
        `parse_start_init_from_json`."""
        if not self.try_consume("@@init_from_json"):
            raise self.err("InvalidSquirrelSyntax: expected '@@init_from_json'")
        self.skip_trivia()
        if not self.try_consume("("):
            raise self.err("InvalidSquirrelSyntax: expected '(' after '@@init_from_json'")
        self.skip_trivia()
        return self._parse_json_call_arg("@@init_from_json")

    def parse_finalize_init_from_json(mut self) raises:
        """Requires `self.pos` at the `@@` of `@@finalize_init_from_json()`,
        e.g. right after `find_next_marker` returns
        `MarkerKind.FINALIZE_INIT_FROM_JSON`. Takes no arguments -- just
        consumes the token; codegen (`rewrite_markers`) is where dropping
        `sqrrl__world`'s temporary reload retention actually happens."""
        if not self.try_consume("@@finalize_init_from_json"):
            raise self.err("InvalidSquirrelSyntax: expected '@@finalize_init_from_json'")
        self.skip_trivia()
        if not self.try_consume("("):
            raise self.err(
                "InvalidSquirrelSyntax: expected '(' after '@@finalize_init_from_json'"
            )
        self.skip_trivia()
        if not self.try_consume(")"):
            raise self.err(
                "InvalidSquirrelSyntax: '@@finalize_init_from_json' takes no arguments"
            )

    def parse_world_func(mut self) raises -> String:
        """Requires `self.pos` at the `@@` of `@@name(`, e.g. right after
        `find_next_marker` returns `MarkerKind.WORLD_FUNC`. Consumes through
        the opening `(` (but not what follows it -- codegen decides what to
        splice in right after, depending on whether this is a definition or
        a call site, and whether more arguments follow) and returns
        `name`."""
        if not self.try_consume("@@"):
            raise self.err("InvalidSquirrelSyntax: expected '@@'")
        var name = self.scan_ident()
        if name.byte_length() == 0:
            raise self.err("InvalidSquirrelSyntax: expected function name")
        self.skip_trivia()
        if not self.try_consume("("):
            raise self.err("InvalidSquirrelSyntax: expected '(' after function name")
        return name

    def parse_name_ref(mut self) raises -> NameRef:
        """Requires `self.pos` at the `@@` of a bare `@@name`, e.g. right
        after `find_next_marker` returns `MARKER_NAME_REF` or the (bare or
        container) `MarkerKind.RETURN_TYPE` -- both parse identically, see
        `NameRef`'s own doc comment for why a container return type needs
        nothing extra here."""
        if not self.try_consume("@@"):
            raise self.err("InvalidSquirrelSyntax: expected '@@'")
        var name = self.scan_ident()
        if name.byte_length() == 0:
            raise self.err("InvalidSquirrelSyntax: expected name")
        return NameRef(name=name)

    def parse_for_entity_loop(mut self) raises -> String:
        """Requires `self.pos` at the `@@` of `for @@name in ...:`, e.g.
        right after `find_next_marker` returns `MarkerKind.FOR_ENTITY_LOOP`.
        Consumes through the `in` keyword (leaving `self.pos` right at the
        start of the iterated expression, whatever marker that turns out to
        be -- codegen decides what to splice in from there, same technique
        `parse_world_func` uses for its own trailing `(`). Returns `name`."""
        if not self.try_consume("@@"):
            raise self.err("InvalidSquirrelSyntax: expected '@@'")
        var name = self.scan_ident()
        if name.byte_length() == 0:
            raise self.err("InvalidSquirrelSyntax: expected name")
        self.skip_trivia()
        if not self.try_consume("in") or is_ident_char(self.peek()):
            raise self.err("InvalidSquirrelSyntax: expected 'in' after 'for @@" + name + "'")
        return name

