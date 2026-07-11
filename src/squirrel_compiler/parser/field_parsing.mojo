from squirrel_compiler.parser.ast import Field, FieldModifier, TypeParam
from squirrel_compiler.parser.text_utils import is_ident_char
from squirrel_compiler.parser.relation_type_text import is_wrapped_relation_type
from squirrel_compiler.parser.scanner import Scanner


def parse_fields(body: String) raises -> List[Field]:
    """Splits a `@@struct` body into `name: Type` fields. A relation field's
    name must itself be `@@`-marked (`@@employee: @@Employee`, not
    `employee: @@Employee`) so the marking stays consistent between a field's
    name and its type -- true whether the field is a bare relation
    (`@@Employee`) or a collection of them (`List[@@Employee]`); the `@@`
    is stripped from the stored name either way. A field may also be
    prefixed with the bare `unique` keyword (`unique name: Type`, or
    `unique @@employee: @@Employee`/`unique @@members: List[@@Employee]`
    for a relation field -- a collection is `KeyElement` exactly when its
    element type is, so there's nothing collection-specific to reject
    here), the `forwardonly` keyword (`forwardonly scores:
    List[Int]`) -- forcing `ForwardOnlyRel` storage for a field whose type
    genuinely isn't `KeyElement`, which this parser has no way to detect
    from raw type text alone (unlike, say, `List[Int]` vs `List[Address]`
    vs `List[@@Employee]` -- all the same shape, only one of which Mojo
    would actually reject as a `Rel`/`UniqueRel` field) -- or the `multi`
    keyword (`multi @@members: @@Employee`), forcing `MultiRel` storage: a
    genuine many-to-many relation. `multi` is written on the *element*
    type directly (`@@Employee`, not `List[@@Employee]`) -- the keyword
    itself already says "many of these"; codegen is what turns the
    declared element type into the actual `List[EntityHandle[...]]`
    field, the same direction `List[@@Employee]` unwraps its own element
    type today, just reversed. `type_str` isn't required to be a bare,
    unwrapped type here, though -- `multi @@tags: List[@@Category]` is a
    field where each row can hold several `List[@@Category]` values, no
    different in kind from `multi`-ing any other element type; nothing
    about `type_str` looking container-shaped on its own says which case
    it is. There's also `ordered` (`ordered name: Type`), for a
    range-queryable field -- see `FieldModifier`. Every keyword is checked
    with a word-boundary on both sides so a field literally named
    `unique`/`forwardonlyId`/`multiplier`/`orderedBy` isn't mistaken for
    one of them; a *second* `FieldModifier` keyword on the same field is
    rejected immediately (there's only one `FieldModifier` slot to put it
    in), not collected and checked pairwise afterward. `stats` (`stats
    price: Float64`) is checked separately, in the same loop but outside
    that exclusivity check -- see `Field.is_stats`, an independent flag,
    not a fifth `FieldModifier` case, so it can combine freely with any of
    the other four (`ordered stats price: Float64` is fine, in either
    order)."""
    var bs = Scanner(body)
    var fields = List[Field]()
    while True:
        bs.skip_trivia()
        if bs.at_end():
            break

        var modifier = FieldModifier.NONE
        var modifier_keyword = String()
        var is_stats = False
        while True:
            if bs.starts_with("stats") and not is_ident_char(bs.peek_at(5)):
                is_stats = True
                bs.pos += 5
                bs.skip_trivia()
                continue
            var next_keyword: String
            var next_modifier: FieldModifier
            if bs.starts_with("unique") and not is_ident_char(bs.peek_at(6)):
                next_keyword = "unique"
                next_modifier = FieldModifier.UNIQUE
            elif bs.starts_with("forwardonly") and not is_ident_char(bs.peek_at(11)):
                next_keyword = "forwardonly"
                next_modifier = FieldModifier.FORWARD_ONLY
            elif bs.starts_with("multi") and not is_ident_char(bs.peek_at(5)):
                next_keyword = "multi"
                next_modifier = FieldModifier.MULTI
            elif bs.starts_with("ordered") and not is_ident_char(bs.peek_at(7)):
                next_keyword = "ordered"
                next_modifier = FieldModifier.ORDERED
            else:
                break
            if modifier != FieldModifier.NONE:
                raise bs.err(
                    "InvalidSquirrelSyntax: a field can't be both '"
                    + modifier_keyword
                    + "' and '"
                    + next_keyword
                    + "' -- each selects its own, mutually exclusive storage"
                    " shape"
                )
            modifier = next_modifier
            modifier_keyword = next_keyword
            bs.pos += next_keyword.byte_length()
            bs.skip_trivia()

        var name_is_marked = bs.try_consume("@@")
        var name = bs.scan_ident()
        if name.byte_length() == 0:
            raise bs.err("InvalidSquirrelSyntax: expected field name")

        for existing in fields:
            if existing.name == name:
                raise bs.err("DuplicateFieldName: " + name)

        bs.skip_trivia()
        if not bs.try_consume(":"):
            raise bs.err("InvalidSquirrelSyntax: expected ':' after field name")
        bs.skip_trivia()

        var type_str = bs.scan_type()
        if type_str.byte_length() == 0:
            raise bs.err("InvalidSquirrelSyntax: empty field type")

        var type_is_relation = type_str.startswith("@@") or is_wrapped_relation_type(type_str)
        if name_is_marked != type_is_relation:
            raise bs.err(
                "InvalidSquirrelSyntax: @@ marking must match between field"
                " name and type"
            )
        fields.append(
            Field(
                name=name,
                type_str=type_str,
                modifier=modifier,
                is_stats=is_stats,
            )
        )
        _ = bs.try_consume(",")

    return fields^


def unqualify_self_type_params(type_str: String, type_params: List[TypeParam]) -> String:
    """Collapses `Self.T` back to bare `T` wherever `T` names one of
    `type_params`'s own parameters, applied to a generic plain struct's
    own field types right after parsing -- both a hand-written one
    (`parse_hand_written_plain_struct`, where `Self.T` is the *only* form
    real Mojo accepts in its own body) and a shorthand one
    (`parse_plain_struct`, where an author might still write `Self.T`
    even though bare `T` is the intended, simpler style there). Either
    way, the extracted `type_str` feeds `codegen.
    emit_plain_struct_from_json`'s generated `from_json` companion,
    always a *free function*, where `Self` doesn't exist at all
    (confirmed the reverse case -- a free function referencing its own
    type parameter bare -- compiles and runs correctly with no
    qualification at all); a literal `Optional[Self.T]` local there
    wouldn't compile, and for the shorthand case specifically, leaving an
    already-qualified `Self.T` in place would also get double-qualified
    right back to `Self.Self.T` when `emit_plain_struct` adds its own
    `Self.` prefix on the way to generating the struct's own body
    (confirmed both failure modes directly). No-op when `type_params` is
    empty, the overwhelmingly common, non-generic case. `codegen.
    _qualify_type_params_with_self` is the exact reverse, applied when
    *generating* a struct's own body instead of extracting one already
    written (by hand, or normalized from shorthand) that might already
    carry the qualification."""
    if len(type_params) == 0:
        return type_str
    var out = String()
    var bytes = type_str.as_bytes()
    var i = 0
    var n = len(bytes)
    while i < n:
        if is_ident_char(bytes[i]):
            var start = i
            while i < n and is_ident_char(bytes[i]):
                i += 1
            var word = String(type_str[byte = start : i])
            if word == "Self" and i < n and bytes[i] == UInt8(ord(".")):
                var after_dot = i + 1
                var j = after_dot
                while j < n and is_ident_char(bytes[j]):
                    j += 1
                var next_word = String(type_str[byte = after_dot : j])
                var matched = False
                for tp in type_params:
                    if tp.name == next_word:
                        matched = True
                        break
                if matched:
                    out += next_word
                    i = j
                    continue
            out += word
        else:
            out += String(type_str[byte = i : i + 1])
            i += 1
    return out^


def parse_hand_written_struct_fields(body: String) -> List[Field]:
    """Best-effort extraction of a hand-written plain struct's own `var
    name: Type` field declarations from its body -- unlike `parse_fields`
    (`@@struct`/shorthand-plain-struct syntax: no `var` keyword, `@@`-marked
    relation fields, comma/newline-terminated types with no method bodies
    mixed in), a hand-written struct's fields are ordinary, already-valid
    Mojo (`var name: Type`), and its body can contain arbitrary methods
    afterward that this parser has no business trying to understand.
    Stops at the first token that isn't the `var` keyword (matching the
    universal Mojo convention -- and this project's own `emit_plain_struct`
    codegen -- of declaring every field before any method), rather than
    requiring the whole body to consist of field declarations; never
    raises; a name or type this can't make sense of just stops the scan
    there; whatever fields were found before that point are still fields
    it correctly understood. Every field's `type_str` is already a real,
    concrete Mojo type (no `@@` marking possible here -- a hand-written
    struct's own relation field, if any, is already spelled out as
    `EntityHandle[sqrrl__<Name>TableState]` by hand), so `modifier` is
    always `FieldModifier.NONE` -- `unique`/`forwardonly`/`multi`/`ordered`
    are relation-table storage concepts with nothing to mean for a plain
    struct's own value fields."""
    var bs = Scanner(body)
    var fields = List[Field]()
    while True:
        bs.skip_trivia()
        if bs.at_end():
            break
        if not (bs.starts_with("var") and not is_ident_char(bs.peek_at(3))):
            break
        bs.pos += 3
        bs.skip_trivia()
        var name = bs.scan_ident()
        if name.byte_length() == 0:
            break
        bs.skip_trivia()
        if not bs.try_consume(":"):
            break
        bs.skip_trivia()
        var type_str = bs.scan_type()
        if type_str.byte_length() == 0:
            break
        fields.append(Field(name=name, type_str=type_str, modifier=FieldModifier.NONE, is_stats=False))
        bs.skip_trivia()
        _ = bs.try_consume(",")

    return fields^
