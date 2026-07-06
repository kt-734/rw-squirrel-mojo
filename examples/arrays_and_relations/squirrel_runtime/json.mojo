from std.collections import Set
from sqrrl__json import sqrrl__to_json, sqrrl__from_json


trait sqrrl__JsonSerializable:
    """Opt-out hook for `sqrrl__to_json`/`sqrrl__from_json`'s generic
    struct fallback: a type conforming to this is asked for its own
    `sqrrl__to_json` instead of having its fields reflected -- the one
    type in this codebase that needs it is `EntityHandle`, whose real
    fields (an `ArcPointer` into table-internal storage) aren't what a
    relation field's serialized form should ever expose; it serializes as
    the referenced entity's bare id instead. An ordinary `@@struct`/plain
    struct never needs to conform to this -- the reflection-based fallback
    already handles arbitrary nesting with no code of its own. The method
    is `sqrrl__`-prefixed, not bare `to_json`, in case a conforming type
    (or something embedding one) already has its own unrelated method by
    that literal name."""

    def sqrrl__to_json(self) -> String:
        ...


struct sqrrl__JsonScanner(Movable):
    """A minimal, hand-written JSON tokenizer -- Mojo's stdlib has no JSON
    support to build on (confirmed: no `std.json`, `std.pickle`, or any
    general serialization module exists). Shared by every generated
    `from_json`, so the escaping/number-parsing logic is written exactly
    once rather than per field."""

    var text: String
    var pos: Int

    def __init__(out self, var text: String):
        self.text = text^
        self.pos = 0

    def _peek(self) -> UInt8:
        return self.text.as_bytes()[self.pos]

    def _at_end(self) -> Bool:
        return self.pos >= self.text.byte_length()

    def skip_ws(mut self):
        while not self._at_end() and (
            self._peek() == UInt8(ord(" "))
            or self._peek() == UInt8(ord("\t"))
            or self._peek() == UInt8(ord("\n"))
            or self._peek() == UInt8(ord("\r"))
        ):
            self.pos += 1

    def expect_byte(mut self, b: UInt8) raises:
        self.skip_ws()
        if self._at_end() or self._peek() != b:
            raise Error(
                "InvalidJson: expected '" + chr(Int(b)) + "' at byte offset " + String(self.pos)
            )
        self.pos += 1

    def try_consume_byte(mut self, b: UInt8) -> Bool:
        self.skip_ws()
        if not self._at_end() and self._peek() == b:
            self.pos += 1
            return True
        return False

    def try_consume_literal(mut self, literal: String) -> Bool:
        """`true`/`false`/`null` -- consumed whole or not at all."""
        self.skip_ws()
        var end = self.pos + literal.byte_length()
        if end <= self.text.byte_length() and String(self.text[byte = self.pos : end]) == literal:
            self.pos = end
            return True
        return False

    def parse_json_string(mut self) raises -> String:
        """A quoted JSON string, unescaping `\\"`, `\\\\`, `\\/`, `\\n`,
        `\\t`, `\\r`, `\\b`, `\\f` -- `\\uXXXX` is deliberately not
        supported yet (every field type this DSL round-trips today is
        ASCII-safe on the escaping side; a real non-ASCII `\\u` payload
        would need UTF-16 surrogate-pair handling to do properly, not a
        quick addition)."""
        self.expect_byte(UInt8(ord('"')))
        var out = String()
        while True:
            if self._at_end():
                raise Error("InvalidJson: unterminated string")
            var b = self._peek()
            if b == UInt8(ord('"')):
                self.pos += 1
                break
            if b == UInt8(ord("\\")):
                self.pos += 1
                if self._at_end():
                    raise Error("InvalidJson: unterminated escape")
                var esc = self._peek()
                if esc == UInt8(ord('"')):
                    out += '"'
                elif esc == UInt8(ord("\\")):
                    out += "\\"
                elif esc == UInt8(ord("/")):
                    out += "/"
                elif esc == UInt8(ord("n")):
                    out += "\n"
                elif esc == UInt8(ord("t")):
                    out += "\t"
                elif esc == UInt8(ord("r")):
                    out += "\r"
                elif esc == UInt8(ord("b")):
                    out += "\b"
                elif esc == UInt8(ord("f")):
                    out += "\f"
                else:
                    raise Error("InvalidJson: unsupported escape '\\" + chr(Int(esc)) + "'")
                self.pos += 1
            else:
                out += chr(Int(b))
                self.pos += 1
        return out^

    def parse_json_int(mut self) raises -> Int:
        self.skip_ws()
        var start = self.pos
        if not self._at_end() and self._peek() == UInt8(ord("-")):
            self.pos += 1
        var digit_start = self.pos
        while not self._at_end() and self._peek() >= UInt8(ord("0")) and self._peek() <= UInt8(ord("9")):
            self.pos += 1
        if self.pos == digit_start:
            raise Error("InvalidJson: expected a number at byte offset " + String(start))
        return Int(String(self.text[byte = start : self.pos]))

    def parse_json_float(mut self) raises -> Float64:
        self.skip_ws()
        var start = self.pos
        if not self._at_end() and self._peek() == UInt8(ord("-")):
            self.pos += 1
        var digit_start = self.pos
        while not self._at_end() and self._peek() >= UInt8(ord("0")) and self._peek() <= UInt8(ord("9")):
            self.pos += 1
        if not self._at_end() and self._peek() == UInt8(ord(".")):
            self.pos += 1
            while not self._at_end() and self._peek() >= UInt8(ord("0")) and self._peek() <= UInt8(ord("9")):
                self.pos += 1
        if self.pos == digit_start:
            raise Error("InvalidJson: expected a number at byte offset " + String(start))
        return Float64(String(self.text[byte = start : self.pos]))

    def parse_json_bool(mut self) raises -> Bool:
        if self.try_consume_literal("true"):
            return True
        if self.try_consume_literal("false"):
            return False
        raise Error("InvalidJson: expected 'true' or 'false' at byte offset " + String(self.pos))


def sqrrl__escape_json_string(s: String) -> String:
    """The write-side counterpart to `sqrrl__JsonScanner.parse_json_string`
    -- escapes exactly the characters that method unescapes, nothing
    more."""
    var out = String('"')
    for b in s.as_bytes():
        if b == UInt8(ord('"')):
            out += '\\"'
        elif b == UInt8(ord("\\")):
            out += "\\\\"
        elif b == UInt8(ord("\n")):
            out += "\\n"
        elif b == UInt8(ord("\t")):
            out += "\\t"
        elif b == UInt8(ord("\r")):
            out += "\\r"
        elif b == UInt8(ord("\b")):
            out += "\\b"
        elif b == UInt8(ord("\f")):
            out += "\\f"
        else:
            out += chr(Int(b))
    out += '"'
    return out^


# `list_to_json`/`list_from_json`/`set_to_json`/`set_from_json`/
# `optional_to_json`/`optional_from_json`/`dict_to_json`/`dict_from_json`
# used to be generated per-project into `sqrrl__json.mojo`, conditionally
# on whether that project's schema actually used the corresponding
# container (`emit_json_module`'s `wrappers_needed` check) -- but unlike
# `sqrrl__to_json[T]`/`sqrrl__from_json[T]`'s own dispatch table (which
# genuinely can't be static: there's no way to ask Mojo's type system "is
# `T` a container of anything" generically, so the dispatcher needs a
# literal `elif T == List[String]:` branch per concrete type the schema
# uses), these helpers are already fully generic over their element
# type(s) and need nothing project-specific. Moving them here means
# `emit_json_module` only has to generate the dispatch table itself.
#
# The one wrinkle: each helper recurses into its element(s) via
# `sqrrl__to_json`/`sqrrl__from_json`, which are themselves generated
# per-project into `sqrrl__json.mojo` -- so this file importing from
# `sqrrl__json` while `sqrrl__json.mojo`'s own dispatcher calls back into
# these helpers is a genuine two-way dependency, atypical for
# `squirrel_runtime` (everything else here has generated code import FROM
# the runtime, never the reverse). Confirmed this particular shape --
# a runtime file and a generated file importing each other -- compiles
# and runs correctly in this Mojo version.
#
# Unprefixed (unlike `sqrrl__to_json`/`sqrrl__from_json` themselves)
# since they're only ever called from generated bodies, never spliced
# into `.rel`-authored code, so there's nothing for them to collide with
# (same reasoning `Rel`/`UniqueRel`/`MultiRel` stay unprefixed).
def list_to_json[X: Copyable](lst: List[X]) -> String:
    var out = String("[")
    for i in range(len(lst)):
        if i > 0:
            out += ","
        out += sqrrl__to_json(lst[i])
    out += "]"
    return out^


def list_from_json[X: Copyable & ImplicitlyDeletable](mut sc: sqrrl__JsonScanner) raises -> List[X]:
    var lst = List[X]()
    sc.expect_byte(UInt8(ord("[")))
    if not sc.try_consume_byte(UInt8(ord("]"))):
        while True:
            lst.append(sqrrl__from_json[X](sc))
            if sc.try_consume_byte(UInt8(ord(","))):
                continue
            sc.expect_byte(UInt8(ord("]")))
            break
    return lst^


def set_to_json[X: Copyable & ImplicitlyDeletable & Hashable & Equatable](s: Set[X]) -> String:
    var out = String("[")
    var first = True
    for elem in s:
        if not first:
            out += ","
        first = False
        out += sqrrl__to_json(elem)
    out += "]"
    return out^


def set_from_json[
    X: Copyable & ImplicitlyDeletable & Hashable & Equatable
](mut sc: sqrrl__JsonScanner) raises -> Set[X]:
    var s = Set[X]()
    sc.expect_byte(UInt8(ord("[")))
    if not sc.try_consume_byte(UInt8(ord("]"))):
        while True:
            s.add(sqrrl__from_json[X](sc))
            if sc.try_consume_byte(UInt8(ord(","))):
                continue
            sc.expect_byte(UInt8(ord("]")))
            break
    return s^


def optional_to_json[X: Copyable](opt: Optional[X]) -> String:
    if opt:
        return sqrrl__to_json(opt.value())
    return "null"


def optional_from_json[
    X: Copyable & ImplicitlyDeletable
](mut sc: sqrrl__JsonScanner) raises -> Optional[X]:
    if sc.try_consume_literal("null"):
        return None
    return sqrrl__from_json[X](sc)


def dict_to_json[
    K: Copyable & ImplicitlyDeletable & Hashable & Equatable, V: Copyable & ImplicitlyDeletable
](d: Dict[K, V]) -> String:
    # JSON objects require string keys, so a `Dict[K, V]` for arbitrary
    # `K` -- not just `String` -- can't serialize as a JSON object the
    # way a struct's own fields do; an array of `[key, value]` pairs
    # works for any `K`/`V` uniformly instead.
    var out = String("[")
    var first = True
    for entry in d.items():
        if not first:
            out += ","
        first = False
        out += "[" + sqrrl__to_json(entry.key) + "," + sqrrl__to_json(entry.value) + "]"
    out += "]"
    return out^


def dict_from_json[
    K: Copyable & ImplicitlyDeletable & Hashable & Equatable, V: Copyable & ImplicitlyDeletable
](mut sc: sqrrl__JsonScanner) raises -> Dict[K, V]:
    var d = Dict[K, V]()
    sc.expect_byte(UInt8(ord("[")))
    if not sc.try_consume_byte(UInt8(ord("]"))):
        while True:
            sc.expect_byte(UInt8(ord("[")))
            var k = sqrrl__from_json[K](sc)
            sc.expect_byte(UInt8(ord(",")))
            var v = sqrrl__from_json[V](sc)
            sc.expect_byte(UInt8(ord("]")))
            d[k^] = v^
            if sc.try_consume_byte(UInt8(ord(","))):
                continue
            sc.expect_byte(UInt8(ord("]")))
            break
    return d^
