
Resolved: script-level table references now cross files. Every `@@struct` project-wide gets aggregated into one generated `sqrrl__Squirrel` (in `sqrrl__Squirrel.mojo`, written once per `convert_directory` run), obtained via `@@init()` and threaded explicitly through any function that needs it via a bare `@@` in its parameter list (`def foo(@@)`) and at call sites (`foo(@@)`). No mutable global/static state exists in Mojo, so this threading is explicit rather than implicit.

Resolved: chained relation hops (@@alice.@@employee.field, and deeper: @@alice.@@employee.@@boss.title). `FieldAccess` (parser.mojo) now collects any number of intermediate `.@@relation` segments into `hops` before the terminal (non-`@@`) `.field`. Resolving each hop's target type needs project-wide schema, not just the current file's own structs (an intermediate hop can point at a struct declared elsewhere) -- added `build_relation_schema` (driver.mojo, struct name -> relation field name -> target struct name, built once alongside `discover_structs`) and threaded it into `transform_source` (now `transform_source(source, relation_schema)`). Each hop nests one more `get_<hop>(...)` call around the expression so far -- `sqrrl__world.Employee.get_title(sqrrl__world.Person.get_employee(sqrrl__alice))` -- rather than splicing temp variables, so a chain stays usable inline (`print(@@alice.@@employee.title)`), same as a plain single-hop access. Verified end-to-end across two files (compiled and run: read `"engineer"`, wrote `"manager"`, read it back).

While testing chain writes with a string value (`@@alice.@@employee.title = "manager";`), found and fixed a pre-existing, unrelated bug: `parse_field_access` used `skip_trivia()` (skips whitespace *and* comments/string literals) right before capturing where the write value starts -- so a quoted-string write value was silently swallowed whole before `value_start` was even recorded, always producing an empty write value. Never caught before since no existing test used a string (only numeric) write value. Fixed by using `skip_whitespace()` there instead.

Resolved: nested markers inside a construct expression. Caught the asymmetry myself while explaining the gap: a relation field is *declared* with `@@` on both name and type (`@@employee: @@Employee`), but constructing one only wrote `.employee = @@bob` (name unmarked) -- and that's exactly why `@@bob` was never rewritten (nothing signaled that field's value might itself be a marker). Fixed by requiring `@@` on a relation field's name in a construct too (`.@@employee = @@bob`), matching the declaration -- a breaking syntax change, but symmetric with the existing "make sure @@ variables/fields have @@ on the name" rule above.

Restructured `Construct` (parser.mojo) from an opaque `body: String` to `fields: List[ConstructField]` (`parse_construct_fields`, replacing `rewrite_construct_body`), each carrying `name`, `is_relation`, and raw `value` text. Codegen's new `build_create_call`/`resolve_construct_value` (codegen.mojo) validates each field's marking against `relation_schema[type_name]` (mismatch either direction is rejected, same as a struct declaration's own name/type mismatch), and -- only for fields marked `@@` -- checks whether `value` itself starts with `@@`: a bare reference (`@@bob`) rewrites to `sqrrl__bob`; a nested construct (`@@Employee { .title = "engineer" }`) recurses through `build_create_call` again, so nesting works to any depth. A plain (non-`@@`) value passes through untouched either way (e.g. `.@@employee = raw_bob`, a previously-bound plain variable, still works).

While implementing this, hit the *same* `skip_trivia()`-swallows-a-string-literal bug as the field-write fix above, in the sibling code path (`parse_construct_fields`' own value-start capture) -- fixed the same way (`skip_whitespace()` instead).

Verified end-to-end: `.@@employee = @@bob` and `.@@employee = @@Employee { .title = "engineer" }` both compile and run correctly (printed `"engineer"`).

Resolved: an entity variable should cross function boundaries. Added `@@name: @@Type` (`MarkerKind.ENTITY_PARAM` in parser.mojo) -- same shape as a `@@struct` relation field, just written in a `def`'s own parameter list instead of a struct body: `def print_name(@@subject: @@Person, @@) raises:`. It rewrites to a properly typed Mojo parameter (`sqrrl__subject: EntityHandle[sqrrl__PersonTableState]`) and registers `subject -> Person` in that function's own `entity_to_type`, so `@@subject.field` works inside it -- still needs `sqrrl__world` too (via `@@init()` or the existing bare `@@` marker) for the field access itself. Passing the value at the call site needed no new syntax: a bare `@@alice` there already rewrites to a plain reference (`print_name(@@alice, @@);` -> `print_name(sqrrl__alice, sqrrl__world);`). Verified end-to-end (compiled and run, printed the expected value).

Resolved: what happens if a @@Person is created in two different functions? -- one shared table now. There's a single `sqrrl__Squirrel` instance (obtained via `@@init()`) holding one `PersonTable` for the whole project; both functions construct into the same table, not two separate ones, as long as both have `sqrrl__world` in scope (via `@@init()` or `@@` in their own parameter list).

Resolved: make sure @@ variables or fields have @@ on the variable/field name. Struct fields already enforced this (`parse_fields` rejects `@@name: Type`/`name: @@Type` mismatches). Entity variables didn't: `var @@alice = Person { .name = "alice" };` (`@@` on the variable, not on the construct) skipped the construct rewrite entirely, since `Person{...}` isn't itself a marker -- generating genuinely broken Mojo (`Person` undeclared, un-stripped `.field = ` syntax) that only failed if `@@alice.field` was used later (a misleading "was never constructed" error), or not at all otherwise (confirmed: converted with no error when `alice` was never field-accessed again). Fixed in `transform_source`'s `NAME_REF` handling (codegen.mojo): when a `@@`-marked name is being declared (`@@name = `), the right-hand side is now required to itself start with `@@` (either a `@@Type{...}` construct or another `@@`-marked entity), raising a clear `InvalidSquirrelSyntax` immediately rather than deferring to whatever happens downstream.

Resolved: reject cycles. A `@@struct` relation cycle (direct, self, or transitive through any number of hops -- `A -> B -> C -> A`) is now rejected at compile time (`check_no_relation_cycles` in driver.mojo, run project-wide right after struct discovery) with a clear `CyclicRelation: A -> B -> C -> A` error. Two reasons this had to be caught rather than left to fail downstream: relation fields aren't `Optional`, so `create()` needs the target to already exist -- a cycle has no valid first struct to construct, and previously only surfaced as a confusing type error the first time someone called `.create()` (confirmed: Mojo itself compiles the circular cross-file imports fine). Separately, Mojo's `ArcPointer` has no cycle collector, so two entities holding live references to each other would leak forever even if construction were somehow possible.

Resolved: is the following cycle caught -- yes, now (it wasn't at first). `Other` is a plain (non-`@@`) `struct`, so it was invisible to the original check: `discover_structs` only looks for the literal `@@struct` token, and `Person.other: Other` is a plain field, which `_relation_targets` only followed when its type matched a *known* struct name. Fixed by adding `discover_plain_structs`/`Scanner.find_next_plain_struct_decl` (parses bare `struct` blocks project-wide, purely for graph-building -- they never get a generated Table/State pair) and extending `_relation_targets` to also treat a plain field as an edge when its type names any known struct (`@@` or plain). `Person -> Other -> Person` is now caught: `CyclicRelation: Person -> Other -> Person`.

Resolved: yes, also caught -- with the typo fixed (`Another`, not `Anther`), two plain-struct hops instead of one: `CyclicRelation: Person -> Another -> Other -> Person`. Confirms the fix generalizes to a chain, not just the single-hop case above.

@@struct Employee {
    title: String,
}

struct Other {
    @@person: @@Person
}

struct Another {
    other: Other
}

@@struct Person {
    name: String,
    another: Another,
    @@employee: @@Employee
}
