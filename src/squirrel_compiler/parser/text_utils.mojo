def source_location(source: String, byte_pos: Int) -> String:
    """1-indexed `"line:col"` for `byte_pos` within `source` -- column counts
    bytes since the last newline, not Unicode codepoints (fine here: every
    position this is ever called with points at a grammar token -- `{`,
    `@@`, an identifier, ... -- and those are all ASCII; only string-literal
    *contents* can be non-ASCII, and nothing ever raises pointing inside
    one). Spliced into every raised error so a message says exactly where in
    a `.rel` file it happened, not just that it did -- `Scanner.err` is the
    usual way this gets called, but it's a free function (not a method)
    since a couple of raise sites (`codegen.build_create_call`,
    `enforce_entity_binding`) have a `source`/position in scope without a
    live `Scanner` there to ask."""
    var line = 1
    var col = 1
    var bytes = source.as_bytes()
    var limit = byte_pos if byte_pos < len(bytes) else len(bytes)
    for i in range(limit):
        if bytes[i] == UInt8(ord("\n")):
            line += 1
            col = 1
        else:
            col += 1
    return String(line) + ":" + String(col)


def line_indent_of(source: String, pos: Int) -> Int:
    """Number of leading space/tab bytes on the line containing byte offset
    `pos` -- the baseline `Scanner.scan_indented_block` compares every
    following line's own indentation against, the same way a `@@struct`
    header's column tells Python/Mojo where its body block's fields must be
    indented past."""
    var bytes = source.as_bytes()
    var line_start = pos
    while line_start > 0 and bytes[line_start - 1] != UInt8(ord("\n")):
        line_start -= 1
    var i = line_start
    while i < len(bytes) and (bytes[i] == UInt8(ord(" ")) or bytes[i] == UInt8(ord("\t"))):
        i += 1
    return i - line_start


def is_ident_char(b: UInt8) -> Bool:
    return (
        (b >= UInt8(ord("a")) and b <= UInt8(ord("z")))
        or (b >= UInt8(ord("A")) and b <= UInt8(ord("Z")))
        or (b >= UInt8(ord("0")) and b <= UInt8(ord("9")))
        or b == UInt8(ord("_"))
    )


def is_after_arrow(source: String, pos: Int) -> Bool:
    """True if, scanning backward from byte offset `pos` (skipping spaces
    and tabs), the two bytes immediately before are `-` then `>` -- i.e.
    `pos` sits right after a `->` (Mojo's return-type arrow), modulo
    whitespace. Used to tell a return-type marking (`-> @@Type:`) apart
    from any other bare `@@name:` shape (which keeps its existing
    `MarkerKind.NAME_REF` fallback -- see `Scanner.find_next_marker`)."""
    var bytes = source.as_bytes()
    var i = pos
    while i > 0 and (bytes[i - 1] == UInt8(ord(" ")) or bytes[i - 1] == UInt8(ord("\t"))):
        i -= 1
    return i >= 2 and bytes[i - 1] == UInt8(ord(">")) and bytes[i - 2] == UInt8(ord("-"))


def is_after_for_keyword(source: String, pos: Int) -> Bool:
    """True if, scanning backward from byte offset `pos` (skipping spaces/
    tabs, and one optional `var`/`ref` keyword in between), the preceding
    text is `for` with a word boundary before it too -- `pos` sits right
    after `for `, `for var `, or `for ref ` (mod whitespace), the shapes a
    `for @@name in ...:`/`for var @@name in ...:`/`for ref @@name in ...:`
    loop's own target variable needs to recognize itself by (see
    `MarkerKind.FOR_ENTITY_LOOP`), as opposed to an ordinary, unmarked-target
    `for name in ...:` loop (left untouched -- no `@@` there for this
    scanner to ever reach in the first place). `var`/`ref` matter in
    practice, not just style: Mojo's own exclusivity checker sometimes
    *requires* one of them on a loop target -- `var` for an owned copy,
    `ref` for an explicit (rather than the default, sometimes-ambiguous
    implicit) reference -- when the loop body indexes back into the same
    container being iterated. Confirmed via a direct repro (`for state in
    capitals: print(capitals[state])` rejected with 'argument of
    __getitem__ call allows reading a memory location previously writable
    through another aliased argument'; `for var state in capitals:`
    compiles fine)."""
    var bytes = source.as_bytes()
    var i = pos
    while i > 0 and (bytes[i - 1] == UInt8(ord(" ")) or bytes[i - 1] == UInt8(ord("\t"))):
        i -= 1
    if i >= 3 and (
        String(source[byte = i - 3 : i]) == "var" or String(source[byte = i - 3 : i]) == "ref"
    ) and (i == 3 or not is_ident_char(bytes[i - 4])):
        i -= 3
        while i > 0 and (bytes[i - 1] == UInt8(ord(" ")) or bytes[i - 1] == UInt8(ord("\t"))):
            i -= 1
    if i < 3:
        return False
    if String(source[byte = i - 3 : i]) != "for":
        return False
    return i == 3 or not is_ident_char(bytes[i - 4])


def is_after_container_bracket(source: String, pos: Int) -> Bool:
    """True if byte offset `pos` sits inside `Ident[...]`'s bracket list, at
    *any* parameter position -- not just immediately after `[`
    (`List[@@Type`), but also after a `,` for a later parameter
    (`Dict[@@Type, V]`'s second slot, `Dict[K, @@Type]`'s own -- wherever
    that container appears: a return type (`-> Dict[@@Type, V]:`), a
    parameter type, or a bare generic-instantiation expression
    (`Dict[@@Type, V]()`). Scans backward from `pos` (the `@@` of the type
    name itself -- that's where the marker scanner finds it, the outer
    `Ident[` already scanned past as ordinary text on an earlier
    iteration), tracking bracket/paren/brace depth so an intervening
    parameter that's itself generic (`Dict[@@Type, List[Int]]`) doesn't
    confuse it, until it finds the *enclosing* `[` at depth 0 and checks
    for an identifier immediately before that. Bounded to the current
    line (stops at a newline) -- same single-line assumption
    `is_in_def_signature` already makes -- so this can't wander off into
    unrelated, far-earlier code looking for some other `Ident[`."""
    var bytes = source.as_bytes()
    var i = pos
    var depth = 0
    while i > 0:
        var b = bytes[i - 1]
        if b == UInt8(ord("\n")):
            return False
        if b == UInt8(ord("]")) or b == UInt8(ord(")")) or b == UInt8(ord("}")):
            depth += 1
        elif b == UInt8(ord("[")):
            if depth == 0:
                var j = i - 1
                while j > 0 and (bytes[j - 1] == UInt8(ord(" ")) or bytes[j - 1] == UInt8(ord("\t"))):
                    j -= 1
                var ident_end = j
                while j > 0 and is_ident_char(bytes[j - 1]):
                    j -= 1
                return j != ident_end
            depth -= 1
        elif b == UInt8(ord("(")) or b == UInt8(ord("{")):
            if depth == 0:
                return False
            depth -= 1
        i -= 1
    return False


def is_unmarked_container_declaration(source: String, marker_start: Int) -> Bool:
    """True if, scanning further backward past the `Ident[` that
    `is_after_container_bracket(source, marker_start)` already confirmed
    precedes `marker_start`, the text matches `name: Ident[` (mod
    whitespace) -- a `name: Container[@@Type]` field or variable
    declaration whose `name` isn't itself `@@`-marked, the same shape
    `parse_fields` already rejects inside a `@@struct` body but which
    reaches ordinary marker scanning unenforced anywhere else (a
    hand-written plain `struct`'s own field, or a bare `var name:
    List[@@Type] = ...`) -- confirmed empirically: `var members:
    List[@@Employee]` inside a plain Mojo struct compiled silently, with
    the type rewritten to `List[EntityHandle[...]]` but no requirement that
    `members` itself be written `@@members`.

    If `name` WERE `@@`-marked, `EntityParam`'s own forward-looking
    `@@name: Container[@@Type]` check (`Scanner.at_wrapped_entity_param`)
    would already have classified the whole thing as `ENTITY_PARAM` the
    moment the scanner reached `@@name`, well before it ever got to this
    inner `@@Type` as an independent marker -- so simply finding an
    unmarked `name:` here is sufficient; there's no marked case this could
    also be matching. Returns `False` for a return type (`->
    Container[@@Type]:`, nothing before `Ident[` but an arrow) or a bare
    generic instantiation (`Container[@@Type]()`, nothing meaningful
    before `Ident[` at all) -- neither has a name to enforce marking on."""
    var bytes = source.as_bytes()
    var i = marker_start
    while i > 0 and (bytes[i - 1] == UInt8(ord(" ")) or bytes[i - 1] == UInt8(ord("\t"))):
        i -= 1
    if i == 0 or bytes[i - 1] != UInt8(ord("[")):
        return False
    i -= 1
    while i > 0 and (bytes[i - 1] == UInt8(ord(" ")) or bytes[i - 1] == UInt8(ord("\t"))):
        i -= 1
    var wrapper_end = i
    while i > 0 and is_ident_char(bytes[i - 1]):
        i -= 1
    if i == wrapper_end:
        return False
    while i > 0 and (bytes[i - 1] == UInt8(ord(" ")) or bytes[i - 1] == UInt8(ord("\t"))):
        i -= 1
    if i == 0 or bytes[i - 1] != UInt8(ord(":")):
        return False
    i -= 1
    while i > 0 and (bytes[i - 1] == UInt8(ord(" ")) or bytes[i - 1] == UInt8(ord("\t"))):
        i -= 1
    var name_end = i
    while i > 0 and is_ident_char(bytes[i - 1]):
        i -= 1
    return i != name_end


@fieldwise_init
struct PrecedingIdent(Copyable, Movable):
    """An identifier `preceding_unmarked_ident` recovered, and where it
    starts in the source -- `start` is what lets a caller trim it (and
    whatever `.`/whitespace sits between it and the marker it precedes)
    out of already-sliced text, rather than guessing its length back from
    `name` alone (which wouldn't account for whitespace around the `.`)."""

    var name: String
    var start: Int


def preceding_unmarked_ident(source: String, marker_start: Int) -> Optional[PrecedingIdent]:
    """The identifier immediately before `.` immediately before
    `marker_start` (mod whitespace), if any -- `note` in `note.@@author`.
    `find_next_marker`'s own `@@`-triggered scan has no way to notice this
    on its own: it only ever recognizes a marker starting at literal `@@`
    text, so `@@author` alone is what it finds, with `note.` already
    treated as ordinary text sitting before it. This is `rewrite_markers`'
    own way of recovering that prefix once it has a marker in hand,
    letting a `.@@relation` read resolve against whatever *precedes* the
    dot -- a tracked plain variable (`entity_to_type`), not just another
    `@@`-marked entity -- the same way `@@alice.@@job` already lets `job`
    continue from `alice`.

    Returns `None` if `marker_start` isn't immediately preceded by `.` at
    all (an ordinary top-level `@@author...` reference, no prefix to
    recover), or if nothing identifier-shaped precedes that `.` (`).@@foo`,
    `].@@foo`, ... -- not a plain name, out of scope here). Doesn't check
    *what* the identifier is or whether it's tracked -- purely a text-level
    recovery; the caller decides whether it means anything by checking
    `entity_to_type` itself."""
    var bytes = source.as_bytes()
    var i = marker_start
    while i > 0 and (bytes[i - 1] == UInt8(ord(" ")) or bytes[i - 1] == UInt8(ord("\t"))):
        i -= 1
    if i == 0 or bytes[i - 1] != UInt8(ord(".")):
        return None
    var dot_pos = i - 1
    i = dot_pos
    while i > 0 and (bytes[i - 1] == UInt8(ord(" ")) or bytes[i - 1] == UInt8(ord("\t"))):
        i -= 1
    var ident_end = i
    while i > 0 and is_ident_char(bytes[i - 1]):
        i -= 1
    if i == ident_end:
        return None
    # If the identifier is itself directly preceded by `.` or `@@`, this
    # is a deeper chain (`a.b.@@c`) or an already-marked entity
    # (`@@note.@@author` -- which `find_next_marker`'s own forward scan
    # would already have claimed starting at `@@note` anyway, so this
    # branch is unreachable for that case in practice, but checked
    # explicitly rather than assumed). Only the single, immediate
    # identifier is recovered -- deeper chains are out of scope.
    if i >= 2 and bytes[i - 1] == UInt8(ord("@")) and bytes[i - 2] == UInt8(ord("@")):
        return None
    return PrecedingIdent(name=String(source[byte = i : ident_end]), start=i)


