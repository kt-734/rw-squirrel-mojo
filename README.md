# Squirrel

Squirrel is a small DSL, embedded directly in Mojo source via `@@`-prefixed
markers, that compiles `.rel` files into plain Mojo. It gives you declarative
entity structs with relational fields (one-to-many, unique, many-to-many)
and generates the refcounted storage, indexes, and accessor methods for
them, so you write a `@@struct` with a `@@dept: @@Department` field instead
of hand-rolling a table, an id allocator, and forward/backward indexes
yourself.

A `.rel` file is otherwise just Mojo — anything not `@@`-marked passes
through untouched.

## Quick start

Compile every `.rel` file under a directory into `.mojo` (writing each
generated file alongside its source, plus a shared `sqrrl__world.mojo`
and the runtime it imports):

```sh
pixi run run examples/greeter
```

Then run the result like any other Mojo program:

```sh
pixi run mojo run -I examples/greeter examples/greeter/greeter.mojo
```

Run the test suite:

```sh
pixi run test
```

`pixi run package` produces a standalone `squirrelc` bundle in `dist/`
(the runtime it writes into every project it compiles is baked into the
binary itself, via `embedded_runtime_files()` — see
`tools/generate_embedded_runtime.mojo` — and `dist/lib/` carries the Mojo
runtime shared libraries the executable itself links against, since Mojo
builds aren't statically linked): copy the whole `dist/` directory
anywhere, run `squirrelc` from anywhere, against any project directory —
verified by running it from a location with no access to this checkout or
its pixi environment at all:

```sh
pixi run package
./dist/squirrelc /path/to/your/project
```

(`pixi run build` alone produces just the bare executable, useful for
quick local iteration — but it still dynamically links against this
checkout's own pixi environment, so it isn't portable on its own; use
`pixi run package` for anything you intend to move elsewhere. Every
tagged release ships the packaged bundle — see
[Releases](https://github.com/kt-734/rw-squirrel-mojo/releases).)

## The `@@` grammar

`@@` marks everything Squirrel-specific — struct declarations, entity
construction, relation fields, and world threading. See
[`examples/kitchen_sink`](examples/kitchen_sink) for all of this combined in
one project; each piece individually:

> **A recurring design principle: trust the user, let Mojo's compiler
> catch a bad choice.** This compiler has no real type-checker of its
> own — it's a textual macro/codegen tool operating on raw type-name
> text, not something that understands Mojo's actual trait system.
> Wherever a `.rel` author opts into a capability that requires their
> field's type to support something specific — `unique` needs
> `Hashable`, `ordered` needs `Comparable`, `math` needs `+`/`<`/`>`,
> `equatable` needs `!=` (for `value_eq`) — this compiler never verifies
> that requirement itself. It just generates the code trusting the
> choice, and Mojo's own real compiler is what rejects it, with its own
> accurate error, if the type doesn't actually support what's needed.
>
> This is exactly *why* each of these is an explicit, opt-in keyword
> rather than something inferred or applied automatically: the failure
> mode (a compile error inside generated code, not the `.rel` source
> itself) stays scoped to only the schemas that actually asked for the
> capability, never risked project-wide for schemas that didn't.
> `value_eq` didn't originally follow this — it was generated for every
> struct unconditionally, so *any* struct with a single non-`Equatable`
> field carried that risk whether or not anyone wanted `value_eq` at
> all, and (since Mojo only fully type-checks a generated method once
> something actually calls it) the failure could stay completely silent
> until the day something finally did. Gating it behind `equatable` (see
> below) is what fixed that.

**Declaring an entity struct** — `@@struct` gets a generated table, an id
allocator, and `create`/`get_<field>`/`set_<field>`/`for_<field>` methods
per field:

```
@@struct @@Person:
    name: String
    age: UInt32
```

**Constructing and using one** — `@@{` brings the shared world into scope
once (typically in `main`), already a real, live, empty world; `@@}` closes
the block, checking that nothing built inside it is still alive before the
function returns. Everything between the two has to be written one level
deeper, exactly like a hand-written `try:`/`finally:` body — `@@{`/`@@}`
supply that boilerplate, not the indentation:

```
def main() raises:
    @@{
        var @@alice = @@Person { .name = "alice", .age = 30 }
        @@alice.age = 31
        print(@@alice.name, @@alice.age)
    @@}
```

Every other function that needs `sqrrl__world` takes `@@` on its own
parameter list instead of opening a block of its own. `@@init()` inside
the block re-initializes it to a fresh, empty world (rarely needed right
after `@@{`, which already starts empty — useful for actually resetting
mid-function). `@@start_init_from_json(json)` is its reload counterpart,
obtaining the same shared world by reconstructing it from a previous
`sqrrl__world.to_json()` dump (see "JSON serialization" below) instead of
building an empty one:

```
def main(dump: String) raises:
    @@{
        @@start_init_from_json(dump)
        print(@@Person.all())
    @@}
```

Either one may be called any number of times after `@@{`, in any
control-flow shape — including *conditionally*, letting a script choose
between them at runtime — since each just replaces whatever `sqrrl__world`
currently holds, rather than needing to be the one thing that first
brings it into existence (see `@@finalize_init_from_json()`/
`@@init_from_json(...)` below for the reload side's own cleanup step).

Every `@@init()`/`@@start_init_from_json(...)` call checks that whatever
`sqrrl__world` *currently* holds is empty before replacing it. If something
is still alive in it — a stray local variable, a list built out of its
handles, anything other than the world's own internal bookkeeping —
that's a real bug worth surfacing rather than silently discarding: it
`abort`s with a `LeakedEntities` message. `@@}` runs the same check, via an
explicit `finally:` rather than relying on `sqrrl__World`'s own `__del__` —
not `raises`, deliberately: a leak is the same kind of bug regardless of
when it's discovered, never a legitimate condition worth making catchable
in one case and fatal in the other (a destructor can't propagate a raise
at all). `@@start_init_from_json(...)` still needs the enclosing function
to be `raises` (reconstructing from JSON can fail for unrelated reasons —
a `unique` field's constraint, say), but plain `@@init()` alone doesn't.

Every `@@{` needs a matching `@@}` before its own function ends — checked
at compile time, not left to fail at runtime.

> **Known limitation:** `sqrrl__World`'s own `__del__`, invoked implicitly
> at ordinary end-of-scope, has been observed to run *before* a same-scope
> temporary's own destructor — a false-positive `LeakedEntities` abort that
> the same check, called explicitly, never produces. This appears to be a
> Mojo compiler bug in destructor-insertion ordering around `deinit self`,
> not a bug in generated code (see
> [`mojo-del-destructor-ordering-bug.md`](mojo-del-destructor-ordering-bug.md)
> for a minimal, Squirrel-independent reproduction). `@@{`/`@@}` exist
> specifically to work around it: everything between them runs inside a
> `try:`, and `@@}`'s `finally:` runs the leak check explicitly, at the
> block's real exit point, for every exit path (including an early
> `return` or a `raise` propagating out) — not relying on `__del__` at all.
> `__del__` is still generated as a backstop for anything that manages to
> skip `@@}` regardless (a `raise` propagating past the `try:`, say), but
> the ordinary path through a `@@{`/`@@}` block never depends on it firing
> correctly.

A second, independent `@@{` anywhere else in the project is rejected
outright — that would mean two disconnected `sqrrl__world` bindings with
no shared scope between them, defeating the whole point of threading one
world through `@@`.

`@@finalize_init_from_json()` is required, not optional cleanup — it drops
every entity `@@start_init_from_json(...)` retained only *temporarily*
while reconstructing the world (see "JSON serialization" below for why
that retention is needed and where it lives). Skip it and the *next* leak
check — the next `@@init()`-family call, or `@@}`/`sqrrl__world.__del__`
if the function just returns — aborts: every non-`keepalive` entity the
reload retained is still "live" as far as the leak check is concerned
until this runs. Call it once a script has grabbed whatever references it
actually cares about from the reload; anything else — with no relation
and no `keepalive` tag holding it — is destroyed right then, same as any
other last handle dropping:

```
def main(dump: String) raises:
    @@{
        @@start_init_from_json(dump)
        var kept = @@Person.all()      # re-establish whatever references matter first
        @@finalize_init_from_json()    # required -- drop everything else the reload retained
        print(len(kept))
    @@}
```

If a script doesn't need to grab anything from the reload beyond what real
relation fields and `keepalive` tags already keep alive on their own,
`@@init_from_json(json)` does both steps in one call —
`@@start_init_from_json(json)` immediately followed by
`@@finalize_init_from_json()` — so there's nothing to remember to call
separately:

```
def main(dump: String) raises:
    @@{
        @@init_from_json(dump)
        print(@@Person.all())
    @@}
```

**Relation fields** — a field typed `@@Type` points at another entity
(refcounted: the target stays alive as long as anything points at it).
`for_<field>` is the reverse lookup:

```
@@struct @@Department:
    name: String

@@struct @@Employee:
    title: String
    @@dept: @@Department
```

```
var @@eng = @@Department { .name = "Engineering" }
var @@alice = @@Employee { .title = "Engineer", .@@dept = @@eng }
var @@team = @@Employee.for_dept(@@eng) # List[EntityHandle[...]], indexable
var @@alices_dept = @@alice.@@dept      # a single tracked Department
```

`@@alice.@@dept` reads the relation field via instance syntax, tracking the
result the same way `for_<field>`/`create` do: a plain, unmarked variable is
rejected. Marking the last hop is required, not stylistic — there's no
plain `@@alice.dept` spelling for a relation field, only `@@alice.@@dept`;
`@@` on a hop always means "this is a relation," the same way it does
everywhere else. `@@Employee.get_dept(@@alice)` is the equivalent
table-level call, identical either way.

A wrapped relation field (`@@members: List[@@Employee]`) can be read,
indexed, and have one further field read off the indexed element, all in
a single expression — no intermediate `var @@x = @@dept.@@members;`
binding needed first:

```
print(@@dept.@@members[0].name)   # read, index, and read one more field
for @@e in @@dept.@@members:      # iterating the field's own read result
    print(@@e.name)               # also binds @@e, same as any other container
```

**Indexing** — a tracked container (`for_<field>`'s result, or a
container-typed entity parameter) indexes with `@@name[i]`, and a further
`.field` after that reads/writes right through the indexed element:

```
print("first team member:", @@team[0].title)
@@team[0].title = "Lead Engineer"      # write-through-index

var raw = @@team[1]                    # bare, untracked EntityHandle
var @@second: @@Employee = raw         # re-marked with an explicit annotation
```

**Iterating** — `for @@name in <container-call>:` binds `@@name` to the
*element* type (not the whole container, unlike `var @@x = ...`), so
`@@name.field` works directly inside the loop body, no indexing needed:

```
for @@emp in @@Employee.for_dept(@@eng):
    print(@@emp.title)
```

An ordinary, unmarked `for x in y:` (no `@@` on the target) is untouched,
same as any other plain Mojo code.

`for var @@name in ...:`/`for ref @@name in ...:` are recognized the same
way. These aren't Squirrel syntax — they're real Mojo, and sometimes
required by it: Mojo's own exclusivity checker rejects a bare loop target
(an aliased reference into the container) if the loop body indexes back
into that same container, e.g. iterating a `Dict`'s keys while also doing
`the_dict[key]` inside the loop. `var`/`ref` make the target an owned
copy/explicit reference instead, sidestepping the conflict — same fix as
in plain Mojo, just also recognized when the target is `@@`-marked.

**Container type resolution** — this is what makes `@@name[i].field`,
`for @@name in ...:`, and binding a container-returning call to a tracked
variable all work without an explicit type annotation. Every construct that
can hand back a container of entities is tracked as `Wrapper[Type]` (e.g.
`List[Employee]`, `Set[AuditLog]`) the moment it's bound:

- A struct field's own type, for `get_<field>`/`for_<field>` (`List[@@Employee]`
  or a `multi` field's `Set[...]`).
- A `@@`-marked function's declared return type, `-> Container[@@Type]:`
  (project-wide — the function and its call site can live in different
  files).
- `all()`, always `Set[...]` (see below).
- An `ordered` field's exact-match `for_<field>`, also always `Set[...]`
  — its five range-shaped siblings (`_greater_than`/`_less_than`/
  `_at_least`/`_at_most`/`_between`) stay `List[...]` like any other
  field's `for_<field>` — see "Field modifiers" below.

A container with more than one type parameter — `Dict[@@Type, V]` — tracks
only the *first* one and ignores the rest entirely: iterating a bare `Dict`
yields its keys, so `Type` (the key type) is what a `for @@name in
<dict-returning-call>():` loop actually binds to at runtime; `V` (the value
type) never enters `@@`-tracking at all.

None of this is hardcoded to `List`/`Set`/`Dict` specifically — the whole
chain (`parse_type_expr`'s recursive-descent parser, `is_container_type`/
`container_wrapper_of`/`container_element_of`/`encode_container_type`, and
`build_function_returns`' own return-type scanner) works purely off shape,
`Wrapper[Arg1, ...]`, and never branches on what `Wrapper` is actually
called. A field typed `Optional[@@Department]` gets exactly the same
treatment as `List[@@Employee]` — `create`/`get_<field>`/`set_<field>`
take/return a real `Optional[EntityHandle[...]]`, and `@@dept_var[]`
(empty brackets, Mojo's own no-argument `Optional.__getitem__`) unwraps it
through the same `@@name[i].field` machinery `List`/`Set` indexing uses,
just with an empty index expression instead of a real one — raising if the
value is `None`, same as `Optional[T]`'s own `[]` does normally. This isn't
special-cased for `Optional` either: any single-type-parameter wrapper
around a relation, including one this project has never heard of, is
tracked and indexed the same way, as long as its first type parameter is
(or resolves to) a relation.

Whenever a shape genuinely isn't tracked (an untracked `V`, an unmarked
variable, a case this inference doesn't cover), you're never actually
stuck — every generated accessor is an ordinary Mojo function that takes
the entity as a plain argument, so `@@Employee.get_name(raw)` works on any
`EntityHandle[sqrrl__EmployeeTableState]` you have lying around, tracked or
not. `@@name.field` sugar is a convenience on top of that, not the only way
in.

Field-target resolution (`relation_schema`, struct name → relation field
name → target struct name) doesn't distinguish `@@struct`s from plain
structs either — a plain struct's own relation field resolves exactly the
same way an entity's does, project-wide, whether the variable holding it
is a marked entity, a marked container, or a fully unmarked plain-struct
local declared with an explicit `var name: TypeName` annotation (the
one case this parser has no other way to learn a type for, since nothing
`@@`-marked appears in that declaration at all).

**Field modifiers** — one keyword before a field name:

| keyword       | meaning                                                              |
| ------------- | --------------------------------------------------------------------|
| `unique`      | at most one entity may hold a given value; `for_<field>` raises instead of returning a list, and a duplicate raises on construction |
| `forwardonly` | no reverse index at all — for fields whose type isn't hashable (e.g. `List[Int]`), or where the reverse lookup is simply never needed |
| `multi`       | a genuine many-to-many relation: `Set[T]`-backed, with `add_to_<field>`/`remove_from_<field>` mutating one member at a time and `for_<field>` as the reverse query. Only ever needs declaring on *one* side of the relationship — see below |
| `ordered`     | a sorted index alongside the field's value, giving range queries (`for_<field>_greater_than`/`_less_than`/`_at_least`/`_at_most`/`_between`) in addition to the usual exact-match `for_<field>` — see below |
| `math`        | earns `sum_<field>`/`avg_<field>`/`min_<field>`/`max_<field>` (whole-table, per-group, and per-value siblings) against every other field in the struct — see below |

```
@@struct @@Person:
    unique email: String
    forwardonly tags: List[String]
```

**`multi`** — declared on one struct, it already answers both directions
(no need to declare the reverse on the other struct too):

```
@@struct @@Department:
    name: String
    multi @@projects: @@Project
```

```
_ = @@Department.add_to_projects(@@eng, @@website)
print(len(@@eng.@@projects))                          # this dept's projects
print(len(@@Department.for_projects(@@website)))      # which depts run this project
_ = @@Department.remove_from_projects(@@eng, @@website)
```

**`ordered`** — a binary-searchable index, kept sorted by the field's
value, for range queries a hash-backed `Rel` can't answer in better than
linear time:

```
@@struct @@Employee:
    name: String
    ordered years_employed: UInt32
```

```
for @@e in @@Employee.for_years_employed_greater_than(4):
    print(@@e.name)           # everyone with more than 4 years

for @@e in @@Employee.for_years_employed_between(2, 5):
    print(@@e.name)           # 2..5 years, inclusive both ends
```

`for_<field>` (exact match) returns `Set[EntityHandle[...]]`, matching
`all()` and unlike every other field kind's own `for_<field>` (`List`) —
matching ids have no meaningful order to preserve at the entity level.
The five range-shaped siblings (`_greater_than`/`_less_than`/`_at_least`/
`_at_most`/`_between`) stay `List`-returning, like any other field's
`for_<field>` — their whole point is the sorted order `ordered` maintains
internally, which a `Set` would throw away.

**`math`** — unlike `unique`/`forwardonly`/`multi`/`ordered`, this isn't a
storage choice for the field it's written on; it's independent of
`modifier` entirely, so it combines freely with any of the other four
(`ordered math price: Float64`, either order). It marks a field as
eligible to be *aggregated*, earning `sum_<field>`/`avg_<field>`/
`min_<field>`/`max_<field>`, each paired against every *other* groupable
field in the same struct (any modifier but `forwardonly`, which has no
reverse index to group by):

```
@@struct @@Employee:
    name: String
    @@dept: @@Department
    math salary: Float64
```

```
print(@@Employee.sum_salary())                 # whole table, no grouping
print(@@Employee.avg_salary_for_dept(@@eng))    # one department
for @@d in @@Employee.sum_salary_by_dept():     # every department at once
    print(@@d.name)
```

Three shapes per aggregate kind: the whole-table form (`sum_salary()`,
no grouping field at all — the same `id_count()`/`is_live` walk `all()`
itself uses, building no `EntityHandle`), `_by_<field>()` (every group at
once, `Dict[GroupFieldType, ResultType]`, walking the grouping field's own
`all_bwd()` the same way `group_by_<field>`/`count_by_<field>` already
do), and `_for_<field>(value)` (one group, mirroring `for_<field>`/
`count_<field>` sitting alongside their own `_by_` siblings — cheaper when
only one group matters, since it only pays for that one bucket via
`get_bwd(value)`). `_for_`/whole-table both `raise` on an empty
group/table — there's no sensible non-raising default for an empty
average, minimum, or maximum, and raising uniformly (rather than only for
those three) keeps all four aggregate kinds behaving the same way.

An `ordered` field earns `min_<field>`/`max_<field>` for free, with no
`math` needed — `ordered` already requires `Comparable` for its own range
queries, and `min`/`max` need nothing more. `math` is what additionally
earns `sum_<field>`/`avg_<field>` (needing `+` too), and is required for
`min_<field>`/`max_<field>` on a field that isn't otherwise `ordered`
(same trust-the-user principle as `unique`/`ordered` themselves — see
above). `avg_<field>` always returns `Float64`, regardless of the
field's own declared type (`Int`, `UInt32`, ...) — an integer average
silently truncating (`total // count`) would lose information a `Float64`
promotion doesn't; `sum_`/`min_`/`max_` stay in the field's own type,
since those are exact either way. Aggregating a field grouped by itself
is skipped (`sum_salary_by_salary` doesn't exist) — every entity in one of
its own value-groups already holds that exact value, so there's nothing
to aggregate.

**Compound queries** — every `for_<field>` is a single-field lookup; there's
no DSL syntax for combining two conditions ("Engineering employees with
more than 3 years"). No sugar is needed for it, though — `EntityHandle` is
already `Hashable`/`Equatable`, so wrapping any two `List`/`Set` results
(from *any* field, `ordered` or not) in `Set(...)` and intersecting with
`&` works with what's already generated, type inferred from the argument:

```
var matches = Set(@@Employee.for_dept(@@eng)) & Set(@@Employee.for_years_employed_greater_than(3))
```

**Generic/collection types** — an ordinary Mojo generic (`List[String]`,
`List[Int]`, ...) is passed through unchanged, same as any other plain
field type. A relation field can be wrapped in one too (`List[@@Employee]`,
a *different* shape from `multi`: an ordinary one-to-many field whose value
is a whole list, not a set built up one member at a time) — it still gets a
real `for_<field>` reverse lookup, since `List[EntityHandle[...]]` is
hashable exactly when its element type is:

```
@@struct @@Department:
    name: String
    @@members: List[@@Employee]
```

**Plain structs** — a bare `struct` (no `@@`) is an ordinary embedded value,
not its own table. Real Mojo struct syntax works, or a brace-shorthand form.
Either way it can hold plain fields, *and* its own `@@`-marked relation
fields pointing back at a real entity struct:

```
struct Address {
    city: String,
}

struct Note {
    @@author: @@Employee,
    text: String,
}

@@struct @@Person:
    name: String
    forwardonly home: Address
```

`Note` above compiles to a real Mojo struct with a
`var author: EntityHandle[sqrrl__EmployeeTableState]` field — plain structs
aren't just embeddable *inside* an `@@struct`, they can embed a relation
of their own right back into one.

Reading a plain struct's own relation field works the same way as an
`@@struct`'s, through whatever variable holds the plain struct value —
including a completely unmarked one, since a plain struct is never itself
an entity needing `@@`-tracking to know its type. `var name: TypeName`
(both sides unmarked, `TypeName` a known plain struct) is enough to opt
in — no explicit annotation is needed for a marked entity/container
variable (its type is already known from its own construct/call), but a
plain, unmarked local otherwise has no way to tell this parser what it
holds:

```
var note: Note = Note(author = @@alice, text = "hi")
print(note.@@author.name)      # "note" itself is never @@-marked
```

`note.@@author` resolves against `Note`'s own relation field the same way
`@@alice.@@dept` resolves against `Employee`'s — direct Mojo field access
under the hood (`note.author`), not a `get_<field>` call, since a plain
struct has no generated table to route one through. Writing through an
unmarked prefix this way isn't supported (`note.@@author = @@bob;`
raises) — only reading is.

**Hopping through relations** — a chain of `.@@relation` reads or writes
follow each hop automatically. The chain doesn't need to end in a plain
field, either — ending on a relation hop reads that relation itself,
tracked the same way `get_<field>` is:

```
print(@@alice.@@job.@@dept.name)
@@alice.@@job.title = "Junior Engineer"
var @@alices_job_dept = @@alice.@@job.@@dept
```

**Relation cycles** — a relation cycle (any chain of relation fields that
leads back to where it started, project-wide) is rejected at compile time
with a `CyclicRelation` error, naming the whole cycle and where each
struct in it is declared:

```
CyclicRelation: A (a) -> B (b) -> A
```

This is checked before any code is generated, for two reasons: `create()`
needs every relation field's target to already exist (a cycle would mean
two structs each waiting on the other), and Mojo's `ArcPointer` has no
cycle collector — a real reference cycle would leak forever rather than
ever reaching zero. A cycle doesn't need to be direct — any of these count
as a graph edge, and a chain through any mix of them is caught the same
way:

- **Self-relations** — `@@Node` with a `@@friend: @@Node` field is a
  one-struct cycle.
- **Transitive chains** — `A -> B -> C -> A`, spanning any number of
  structs across any number of files.
- **Wrapped relation fields** — `List[@@Employee]`/`Set[@@Employee]` are
  graph edges exactly like a bare `@@Employee` field would be.
- **Plain fields naming a known struct** — `members: List[A]` (no `@@`) is
  still an edge if `A` is a declared struct: an embed-by-value collection
  can smuggle a cycle back through whatever `A`'s own fields point at.
- **Plain structs** — a `@@`-marked field *inside* a plain (non-`@@`)
  struct that's embedded into an entity struct carries the cycle through
  just as well, even though the plain struct itself is never written as
  `@@Type` on either end — caught for a hand-written plain struct too (a
  real Mojo struct, not the brace-shorthand form), since its own relation
  field is recovered back to the same `@@Employee` shape the cycle check
  already understands.

**What isn't a cycle:** a diamond — `A` pointing at both `B` and `C`,
which both point at `D` — is perfectly fine; nothing leads back to `A`.
Declaring `multi` redundantly on *both* sides of a relationship
(`Student.courses`/`Course.students`, each pointing at the other) *is*
rejected as a cycle like any other pairing — but there's no reason to
write it that way in the first place: a single `multi @@students:
@@Student` field declared on just `Course` already answers both
directions — `Course.get_students(math)`/`add_to_students`/`for_students`
(from `Course`'s own side) — with no edge back from `Student` needed at
all.

**`@@`-marked functions** — marking a function's own *name* with `@@`
(`def @@name(...)`, not a parameter) auto-threads the world through it: its
definition gets `mut sqrrl__world: sqrrl__World` inserted as its first
parameter, and every call site gets `sqrrl__world` inserted as its first
argument — silently, on both ends, so neither the signature nor the call
needs to mention it explicitly. This is how you build reusable entity
factories instead of writing every `@@Type{...}` construct inline in
`main`:

```
def @@make_department(name: String) -> @@Department:
    var @@dept = @@Department { .name = name }
    return @@dept

def @@hire(name: String, title: String, @@dept: @@Department) raises -> @@Employee:
    var @@emp = @@Employee { .name = name, .title = title, .@@dept = @@dept }
    return @@emp
```

```
var @@eng = @@make_department("Engineering")
var @@alice = @@hire("Alice", "Engineer", @@eng)
```

Writing the *definition*, `def @@name(...)`, has no precondition — it
just declares that this function receives the world as a parameter, which
becomes available for the rest of its own body from there. A *call site*
is different: calling `@@hire(...)` only works inside a function that
already has `sqrrl__world` itself, via `@@init()` or its own `@@`-marked
name/parameters. A `-> @@Type:`/`-> Container[@@Type]:` return type
(`@@make_department` above) is tracked the same way a `for_<field>`/
`create` call's return type is, so binding its result to an unmarked
variable is rejected the same way.

Ordinary code can call an `@@`-marked function too, or receive/return the
generated `EntityHandle[...]` types directly, by threading `sqrrl__world`
by hand instead of relying on `@@` to do it — see
[`ADVANCED_FEATURES.md`](ADVANCED_FEATURES.md). Writing `sqrrl__`-prefixed
names yourself is the exception, not the norm: everything in this section
so far avoids it entirely.

## Generated functions

Every `@@struct` produces two Mojo structs:

- `sqrrl__NameTableState` — internal: one `Rel`/`UniqueRel`/`ForwardOnlyRel`/
  `MultiRel` per field (whichever modifier that field uses selects), plus
  `sqrrl__cleanup_relations`, which runs automatically when an entity's last
  handle drops (releasing whatever its relation fields pointed at) — never
  called directly.
- `sqrrl__NameTable` — the table you actually call methods on, as
  `sqrrl__world.Name.<method>(...)`.

`sqrrl__NameTable`'s methods, one row per method, unprefixed:

| method | signature | notes |
| --- | --- | --- |
| `create` | `(field1: T1, field2: T2, ...) -> EntityHandle[...]` | one parameter per field, in declared order; `raises` if *any* field is `unique` |
| `get_<field>` | `(e) -> FieldType` | |
| `set_<field>` | `(e, v: FieldType)` | `raises` only if *this* field is `unique` |
| `for_<field>` | shape depends on the field's own modifier — see below | reverse lookup by value |
| `count_<field>` | `(value: FieldType) -> Int` (or `ElementType` for `multi`) | how many entities have this value — see below |
| `group_by_<field>` | shape depends on the field's own modifier — see below | every value at once, mapped to its own matching entities |
| `count_by_<field>` | shape depends on the field's own modifier — see below | every value at once, mapped to its own count — see below |
| `distinct_<field>` | `() -> Set[FieldType]` (`List` for `ordered`, `Set[ElementType]` for `multi`) | every distinct value currently in use, no entities built at all — see below |
| `sum_<field>`/`avg_<field>`/`min_<field>`/`max_<field>` | `() raises -> ResultType` (whole table); `_by_<other>() -> Dict[OtherFieldType, ResultType]`; `_for_<other>(value) raises -> ResultType` | `math`/`ordered` fields only, paired against every other groupable field — see below |
| `add_to_<field>` | `(e, value: ElementType) -> Bool` | `multi` fields only — `True` if newly added, `False` if already a member |
| `remove_from_<field>` | `(e, value: ElementType) -> Bool` | `multi` fields only — `True` if it was actually removed |
| `all` | `() -> Set[EntityHandle[...]]` | every currently-live entity in the table — generated for every struct, `keepalive` or not |
| `count` | `() -> Int` | `len(all())` without building a handle for every entity just to throw it away right after — O(1), generated for every struct |
| `value_eq` | `(a, b) -> Bool` | field-by-field comparison — `equatable`-tagged structs only — see below |
| `dont_keepalive` | `(e) -> Bool` | `keepalive`-tagged structs only — see below |

`for_<field>`'s signature and behavior depend on that field's own modifier:

| field is... | `for_<field>` signature | behavior |
| --- | --- | --- |
| plain (no modifier) | `(value: FieldType) -> List[EntityHandle[...]]` | every entity currently holding exactly `value` |
| `unique` | `(value: FieldType) raises -> EntityHandle[...]` | the one entity holding `value`; raises if none does |
| `multi` | `(value: ElementType) -> List[EntityHandle[...]]` | every entity whose set *contains* `value` — takes the bare element type, not the field's whole `Set[...]` type |
| `forwardonly` | *(not generated)* | no reverse index exists for this field at all |

A relation field (`@@dept: @@Department`) is not a special case in this
table — it's just an ordinary field whose `FieldType` happens to be
`EntityHandle[...]`, so `get_dept`/`set_dept`/`for_dept` all follow the same
plain-field row above.

`count_<field>(value)` is `len(for_<field>(value))` without building a
handle for every matching entity just to throw it away right after — for
plain/`multi`/`ordered` it's a strictly cheaper way to ask something
`for_<field>` already answers. `unique` is the one exception: `for_<field>`
*raises* if `value` isn't in use at all, so there was previously no way to
ask "is this value taken" without a `try`/`except` — `count_<field>` gives
you `0`/`1` instead, no raising, genuinely new rather than just faster:

```
print(@@Employee.count_dept(@@eng))          # how many employees in this dept
print(@@Person.count_email("a@b.com"))       # 0 or 1 -- no try/except needed
```

`group_by_<field>` is `for_<field>` turned inside out — every value at
once, mapped to its own matching entities, instead of one value looked up
at a time. It falls out of what each field kind's storage already
maintains internally (the same reverse index `for_<field>` itself reads
one bucket of), so it costs nothing new to compute, just a new way to read
it:

| field is... | `group_by_<field>` signature | behavior |
| --- | --- | --- |
| plain (no modifier) | `() -> Dict[FieldType, List[EntityHandle[...]]]` | every value currently in use, mapped to every entity holding it |
| `unique` | `() -> Dict[FieldType, EntityHandle[...]]` | every value mapped to its own single entity — no `List` wrapping, since `unique` guarantees exactly one |
| `multi` | `() -> Dict[ElementType, List[EntityHandle[...]]]` | every element mapped to every entity whose set contains it — keyed by the bare element type, like `for_<field>` is for `multi` |
| `ordered` | `() -> Dict[FieldType, List[EntityHandle[...]]]` | same shape as plain, but iterating the result visits values in ascending order (`Dict`'s own iteration order matches insertion order, and this is built by inserting in sorted order) |
| `forwardonly` | *(not generated)* | no reverse index exists for this field at all, same as `for_<field>` |

`group_by_<field>` only gives you *one* direction of a `multi` relation —
"for each element, every row whose set contains it." The other direction
("for each row, its own member set") isn't a new method at all: it's just
`get_<field>` on a value you already have, or `all()` plus `get_<field>`
per row if you want it for every row at once.

`count_by_<field>` is `group_by_<field>` without ever building the
`List[EntityHandle[...]]`/`EntityHandle` for each group, just `len()`-ing
it (`unique` isn't generated at all here — every group is exactly `1` by
construction, carrying zero information beyond what `unique` already
guarantees). Signature and behavior otherwise mirror `group_by_<field>`'s
own table above, `Int` in place of the entity/entities:

```
for entry in @@Employee.count_by_dept().items():
    print("department has", entry.value, "employees")   # no handles built at all
```

`distinct_<field>()` goes a step further than `count_by_<field>` — no
`EntityHandle` *and* no count, just which values are currently in use.
This turns out to matter for `unique` specifically: `group_by_<field>()`
gives you every value mapped to its entity, but building that entity costs
a real `handle_for` call (a `WeakPointer` upgrade + `EntityHandle`
construction) *per value*, even if all you wanted was to know which values
exist — `.keys()` afterward doesn't undo that cost, since the expensive
part already ran building the `Dict` in the first place. `distinct_<field>`
skips it entirely, reading straight from the reverse index's own keys:

```
print(@@Person.distinct_email())   # every email currently taken, no handles built
```

Returns `Set[FieldType]` for every field kind except `ordered`, which
returns `List` instead (and `Set[ElementType]` for `multi`, keyed the same
way every other method in this family is) — `ordered`'s ascending order is
made explicit in the return type itself, the same reason its range-shaped
`for_<field>_*` methods stay `List`-returning rather than `Set`, instead of
resting on `Set`'s own (real, but less obviously-ordered-to-a-reader)
iteration behavior.

When the field is itself a relation (`@@dept: @@Department`,
`multi @@projects: @@Project`), `distinct_<field>()`'s result is tracked
like any other entity container — bind it to an `@@`-marked variable, or
iterate it directly, and `@@`-marked field access on its elements works
the same way it does for `for_<field>`/`all()`:

```
for @@d in @@Employee.distinct_dept():
    print(@@d.name)
```

For a *plain* (non-relation) field, `distinct_<field>()` returns a
container of ordinary values (`String`, `UInt32`, ...), not entities —
`@@`-marking its result is rejected the same as any other non-entity
shape.

`group_by_<field>`/`count_by_<field>` get the same treatment, but only for
their *first* type parameter (the `Dict`'s key) — iterating a bare `Dict`
already yields keys, so that's the only parameter `for @@name in ...:`
binding actually needs, and it's the same trick a `@@`-marked function's
own `-> Dict[@@Type, V]:` return type already uses (the `V` there is
discarded the moment the signature is parsed, never tracked at all):

```
for @@d in @@Employee.group_by_dept():
    print("department:", @@d.name)   # @@d is Department, the key type
```

The *value* side of a `group_by_<field>`/`count_by_<field>` `Dict`
(`List[EntityHandle[...]]`/`EntityHandle[...]`/`Int` per key) isn't
`@@`-tracked at all — there's no way to bind both a `Dict`'s key and value
through the marker system yet, only whichever one iterating the bare
container already gives you for free.

`sum_<field>`/`avg_<field>`/`min_<field>`/`max_<field>` are generated for
a `math`- or `ordered`-marked field (see "Field modifiers" above), paired
against every *other* groupable field in the struct, each in three shapes:

```
print(@@Employee.sum_salary())                 # whole table, no grouping
print(@@Employee.avg_salary_for_dept(@@eng))    # one department
for @@d in @@Employee.sum_salary_by_dept():     # every department at once
    print(@@d.name)
```

`_by_<other>()` returns `Dict[OtherFieldType, ResultType]`, tracked the
same way `group_by_<field>`/`count_by_<field>` are when `OtherFieldType`
is itself a relation — `for @@d in @@Employee.sum_salary_by_dept():` binds
`@@d` to `Department`, same mechanism, same "only the key side" caveat.
`_for_<other>(value)` returns a bare `ResultType` (a scalar, not a
container), so there's nothing to `@@`-track there, same as
`count_<field>(value)`'s own plain `Int` isn't. The whole-table form
(no `_by_`/`_for_` at all) is likewise a bare scalar.

**How you get the count of a whole table** (not grouped by any field):
`sqrrl__world.Name.count()` — generated unconditionally, same as `all()`.
Not `len(all())`: that builds a handle for every live entity just to
`len()` the result and discard them; `count()` is O(1), backed by
`IdAllocator`'s own live/free bookkeeping rather than a scan.

`value_eq(a, b)` compares two handles field-by-field, deliberately *not*
what `@@alice == @@bob` gives you — `EntityHandle`'s own `==` is id-based
(needed as-is so a relation field can use it as a `Dict`/`Set` key), so two
handles pointing at the *same* row are always equal regardless of their
current field values, and two *different* rows are never equal no matter
how identical their fields are. `value_eq` is the other axis: same field
values, not necessarily the same row. A relation field is compared by its
own `==` here too (i.e. "points at the same row"), not recursed into the
target's own fields — matching how a foreign key column's equality works
in an ordinary relational database, and avoiding walking back through the
same relation graph `check_no_relation_cycles` already keeps acyclic.

`value_eq` is opt-in — a struct only gets it when tagged `equatable`
(`@@struct equatable @@Name:`, combinable with `keepalive` in either
order: `@@struct keepalive equatable @@Name:`), same trust-the-user
principle as `unique`/`ordered`/`math` (see the top of this section) —
every field's own type needs to support `!=` for it to compile, never
checked ahead of time here either. `value_eq` is also the cautionary tale
behind that principle: it used to be generated unconditionally for every
struct project-wide (not opt-in on a per-field/per-struct basis the way
the other three always were), so any struct with a single non-`Equatable`
field (most commonly an embedded plain struct, which doesn't derive
`Equatable` by default) carried a compile failure regardless of whether
anyone actually wanted `value_eq` — and, since Mojo only fully
type-checks a generated method's body once something in the reachable
call graph actually calls it, that failure stayed completely silent
until the day something finally did. Tagging `equatable` explicitly is
what confines that risk to only the structs that ask for it.

For example, an `Employee` struct with a `unique email`, a `title`, and a
`@@dept: @@Department` field generates:

```
create(email: String, title: String, dept: EntityHandle[...]) raises -> EntityHandle[...]

get_email(e) -> String              set_email(e, v: String) raises
get_title(e) -> String              set_title(e, v: String)
get_dept(e) -> EntityHandle[...]    set_dept(e, v: EntityHandle[...])

for_email(value: String) raises -> EntityHandle[...]            # unique
for_title(value: String) -> List[EntityHandle[...]]             # plain
for_dept(value: EntityHandle[...]) -> List[EntityHandle[...]]   # relation field, still just "plain"
```

**`keepalive`** — an entity normally dies the moment its last handle drops,
same as any other Mojo value; `keepalive` on a `@@struct` (`@@struct
keepalive @@Name:`) overrides that for entities of that type. `create` adds
every new entity to an internal `Set[EntityHandle[...]]`, so it survives
past whatever scope constructed it even with no relation or local variable
holding it — useful for entities you want the world itself to own rather
than tracking by hand. `dont_keepalive(e)` releases one back to ordinary
refcounted lifetime (`True` if it was actually in the set); if nothing else
references it at that point, it's destroyed immediately, same as letting
any other last handle drop.

Only a `keepalive`-tagged struct's own table gets the `keepalive` field and
`dont_keepalive` at all — a non-tagged struct's table has neither. (Whole-
world JSON reload needs somewhere to temporarily retain a non-tagged
struct's freshly reconstructed entities too, but that lives in its own,
separate `TempKeepAlives` structure, not here — see "JSON serialization"
below.)

```
@@struct keepalive @@Project:
    name: String
```

```
_ = @@Project.create(name = "Website Revamp")    # handle discarded, entity lives on
_ = @@Project.create(name = "Onboarding Redesign")
print("all projects:", len(@@Project.all()))
```

`all()` itself doesn't depend on `keepalive` at all — it walks the table's
own id allocator directly (`Table.all()`, one pass, checking which ids are
currently allocated), so it finds every live entity regardless of *why*
it's alive: a relation elsewhere, a local handle, or `keepalive`.

## JSON serialization

`sqrrl__world` itself has `to_json`/a reload counterpart, dumping and
restoring every table's every live entity at once. There's no per-entity
`@@Type.to_json(...)`/`@@Type.from_json(...)` sugar — a relation field
only ever serializes as the referenced entity's bare id, not its
contents, so one entity's JSON in isolation isn't really a self-contained
artifact; it only means anything alongside whichever other tables its
relation fields (direct or through an embedded plain struct's own
relation field) point into. Whole-world serialization is the form that's
actually self-contained, so that's what's DSL-reachable: `@@init()`'s
reload counterpart is `@@start_init_from_json`/`@@finalize_init_from_json`
(see "Constructing and using one" above); the dump half has no sugar at
all (there's nothing to inject — it just always dumps everything), so
that's thread-`sqrrl__world`-by-hand territory (see
[`ADVANCED_FEATURES.md`](ADVANCED_FEATURES.md)):

```
var dump = sqrrl__world.to_json()      # -> String, every table's every live entity

var sc = sqrrl__JsonScanner(dump)
var reloaded = sqrrl__world_from_json(sc)    # -> sqrrl__World, a fresh one
```

Every entity's own id is embedded alongside its fields in this dump —
`sqrrl__world_from_json` lands each reconstructed entity back on that
exact id, not a freshly auto-allocated one, since a relation field
elsewhere in the dump is only ever a bare id and would otherwise resolve
to the wrong row (or nothing) the moment any entity anywhere had ever
been deleted. Reconstruction proceeds in dependency order (whichever
structs a given struct's own relation fields target, reconstructed
first), so by the time any entity's relation field is resolved, its
target is already live in the reloaded world. `unique` fields still
enforce their constraint through reload, same as `create` would.

Plain-struct fields (leaf, `List[String]`, a nested plain struct, ...)
serialize/deserialize with **no code generated for them at all** for
dumping — reflection walks a struct's own fields generically.
Reconstructing one does need a generated companion, for both shorthand
and *hand-written* plain structs alike — a hand-written struct's own
fields are extracted structurally (its leading `var name: Type`
declarations, stopping at its first method) rather than parsed the way
`.rel`-declared syntax is, and a relation field embedded in one has to be
spelled out by hand too (`EntityHandle[sqrrl__EmployeeTableState]`,
there being no `@@`-marked shorthand available inside real Mojo), which
gets reversed back to the ordinary relation-field machinery
automatically. Every shape (shorthand or hand-written plain structs,
leaves, containers, relations, arbitrarily nested) round-trips correctly.

A `keepalive`-tagged struct's reconstructed entities are retained by its
own table's `keepalive` set, same as `create` does. A non-tagged struct's
have nothing else holding them yet (no relation field pointing at them,
no `keepalive` tag), so they're retained *temporarily* instead, in
`reloaded.sqrrl__temp_keep_alives` (an `Optional[TempKeepAlives]`, one
`List[EntityHandle[...]]` field per non-tagged struct) — until whichever of
`@@finalize_init_from_json()` or its hand-written equivalent,
`reloaded.sqrrl__finalize_temp_keep_alives()`, drops it. Grab whatever
references actually matter before dropping it — anything else with no
other anchor is destroyed at that point, same as any other last handle
dropping.

Always drop it through `sqrrl__finalize_temp_keep_alives()`, never by
assigning `sqrrl__temp_keep_alives = None` directly — the method exists
specifically because inlining that assignment into the same function as
the reads that come before it has been observed to corrupt those *earlier*
reads (confirmed: a `.for_<unique>` lookup partway through a function
reading back an already-collapsed table that a `.all()` call two lines
above it, in that same function, still saw correctly). Calling the method
instead — whether via `@@finalize_init_from_json()` or by hand on a
manually-threaded world — avoids it.

## Project layout

```
src/squirrel_compiler/   the compiler: parser/ (scans .rel text into
                          markers), codegen/ (marker -> Mojo text),
                          driver/ (walks a directory, resolves cross-file
                          relations, writes output -- including
                          embedded_runtime.mojo, generated, see below)
src/squirrel_runtime/    the runtime every generated file imports:
                          entity/ (EntityHandle, Table, id allocation),
                          rel/ (Rel, UniqueRel, ForwardOnlyRel, MultiRel --
                          the per-field storage backing each modifier above)
src/main.mojo            CLI entry point: `mojo run -I src src/main.mojo <dir>`,
                          or `pixi run package` for a portable `squirrelc`
                          bundle
tools/                    generate_embedded_runtime.mojo -- regenerates
                          src/squirrel_compiler/driver/embedded_runtime.mojo;
                          package_release.sh -- builds and bundles squirrelc
                          (pixi run package)
examples/                see kitchen_sink for a tour of every feature --
                          every field modifier, deep relation chains,
                          generic and hand-written plain structs, deeply
                          nested containers, and the whole-world JSON
                          dump/reload; the rest are smaller,
                          single-feature examples
test/                    one test file per compiler/runtime module
```

## How compilation works

1. **`discover_structs`/`discover_plain_structs`** parse every `.rel` file
   under the target directory (without emitting anything yet), so a
   relation field can target a struct declared in a different file.
2. **`check_no_relation_cycles`** rejects any schema whose relation fields
   form a cycle, directly or transitively (see "Relation cycles" above).
3. **`emit_file`** rewrites each file's markers into real Mojo (via
   `transform_source`) and prefixes the runtime imports it needs.

A schema-level error (a cyclic relation, a mismatched `@@` marking, ...)
is reported as `path/to/file.rel:line:col: Category: message`.

## Development

```sh
pixi run test      # runs every test/test_*.mojo file
pixi run run <dir> # compiles every .rel file under <dir>
pixi run build     # builds squirrelc for quick local iteration (not portable on its own)
pixi run package   # builds + bundles squirrelc into dist/, portable anywhere
```

`src/squirrel_compiler/driver/embedded_runtime.mojo` is generated, not
hand-written — it's what lets `squirrelc` write a fully working
`squirrel_runtime` into any project without needing this checkout's own
`src/` on disk. `test`/`run`/`build`/`package` all depend on the task that
regenerates it (`generate-embedded-runtime`, see `pixi.toml`), so it's
always rebuilt from whatever's currently under `src/squirrel_runtime/`
before any of them run — edit a runtime file and the next `pixi run`
picks it up automatically, no separate step to remember. Commit the
regenerated file alongside whatever runtime change caused it, same as any
other generated output this project checks in.

No compiler warnings are tolerated in generated or example code — treat one
as a bug the same as a hard error.

## Support this project

If Squirrel is useful to you, consider
[sponsoring on GitHub](https://github.com/sponsors/kt-734).
