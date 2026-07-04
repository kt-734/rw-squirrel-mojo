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
generated file alongside its source, plus a shared `sqrrl__Squirrel.mojo`
and a copy of the runtime):

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

## The `@@` grammar

`@@` marks everything Squirrel-specific — struct declarations, entity
construction, relation fields, and world threading. See
[`examples/kitchen_sink`](examples/kitchen_sink) for all of this combined in
one project; each piece individually:

**Declaring an entity struct** — `@@struct` gets a generated table, an id
allocator, and `create`/`get_<field>`/`set_<field>`/`for_<field>` methods
per field:

```
@@struct @@Person:
    name: String
    age: UInt32
```

**Constructing and using one** — `@@init()` obtains the shared world once
(typically in `main`); every other function that needs it takes `@@` on its
own parameter list instead of calling `@@init()` again:

```
def main() raises:
    @@init();
    var @@alice = @@Person { .name = "alice", .age = 30 };
    @@alice.age = 31;
    print(@@alice.name, @@alice.age);
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
var @@eng = @@Department { .name = "Engineering" };
var @@alice = @@Employee { .title = "Engineer", .@@dept = @@eng };
var @@team = @@Employee.for_dept(@@eng);        # List[EntityHandle[...]], indexable
var @@alices_dept = @@Employee.get_dept(@@alice); # a single tracked Department
```

**Indexing** — a tracked container (`for_<field>`'s result, or a
container-typed entity parameter) indexes with `@@name[i]`, and a further
`.field` after that reads/writes right through the indexed element:

```
print("first team member:", @@team[0].title);
@@team[0].title = "Lead Engineer";     # write-through-index

var raw = @@team[1];                   # bare, untracked EntityHandle
var @@second: @@Employee = raw;        # re-marked with an explicit annotation
```

**Iterating** — `for @@name in <container-call>:` binds `@@name` to the
*element* type (not the whole container, unlike `var @@x = ...`), so
`@@name.field` works directly inside the loop body, no indexing needed:

```
for @@emp in @@Employee.for_dept(@@eng):
    print(@@emp.title);
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

Whenever a shape genuinely isn't tracked (an untracked `V`, an unmarked
variable, a case this inference doesn't cover), you're never actually
stuck — every generated accessor is an ordinary Mojo function that takes
the entity as a plain argument, so `@@Employee.get_name(raw)` works on any
`EntityHandle[sqrrl__EmployeeTableState]` you have lying around, tracked or
not. `@@name.field` sugar is a convenience on top of that, not the only way
in.

**Field modifiers** — one keyword before a field name:

| keyword       | meaning                                                              |
| ------------- | --------------------------------------------------------------------|
| `unique`      | at most one entity may hold a given value; `for_<field>` raises instead of returning a list, and a duplicate raises on construction |
| `forwardonly` | no reverse index at all — for fields whose type isn't hashable (e.g. `List[Int]`), or where the reverse lookup is simply never needed |
| `multi`       | a genuine many-to-many relation: `Set[T]`-backed, with `add_to_<field>`/`remove_from_<field>` mutating one member at a time and `for_<field>` as the reverse query. Only ever needs declaring on *one* side of the relationship — see below |
| `ordered`     | a sorted index alongside the field's value, giving range queries (`for_<field>_greater_than`/`_less_than`/`_at_least`/`_at_most`/`_between`) in addition to the usual exact-match `for_<field>` — see below |

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
_ = @@Department.add_to_projects(@@eng, @@website);
print(len(@@Department.get_projects(@@eng)));        # this dept's projects
print(len(@@Department.for_projects(@@website)));    # which depts run this project
_ = @@Department.remove_from_projects(@@eng, @@website);
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
    print(@@e.name);          # everyone with more than 4 years

for @@e in @@Employee.for_years_employed_between(2, 5):
    print(@@e.name);          # 2..5 years, inclusive both ends
```

`for_<field>` (exact match) returns `Set[EntityHandle[...]]`, matching
`all()` and unlike every other field kind's own `for_<field>` (`List`) —
matching ids have no meaningful order to preserve at the entity level.
The five range-shaped siblings (`_greater_than`/`_less_than`/`_at_least`/
`_at_most`/`_between`) stay `List`-returning, like any other field's
`for_<field>` — their whole point is the sorted order `ordered` maintains
internally, which a `Set` would throw away.

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

**Hopping through relations** — a chain of `.@@relation` reads or writes
follow each hop automatically:

```
print(@@alice.@@job.@@dept.name);
@@alice.@@job.title = "Junior Engineer";
```

**`@@`-marked functions** — marking a function's own *name* with `@@`
(`def @@name(...)`, not a parameter) auto-threads the world through it: its
definition gets `mut sqrrl__world: sqrrl__Squirrel` inserted as its first
parameter, and every call site gets `sqrrl__world` inserted as its first
argument — silently, on both ends, so neither the signature nor the call
needs to mention it explicitly. This is how you build reusable entity
factories instead of writing every `@@Type{...}` construct inline in
`main`:

```
def @@make_department(name: String) -> @@Department:
    var @@dept = @@Department { .name = name };
    return @@dept;

def @@hire(name: String, title: String, @@dept: @@Department) raises -> @@Employee:
    var @@emp = @@Employee { .name = name, .title = title, .@@dept = @@dept };
    return @@emp;
```

```
var @@eng = @@make_department("Engineering");
var @@alice = @@hire("Alice", "Engineer", @@eng);
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
| `add_to_<field>` | `(e, value: ElementType) -> Bool` | `multi` fields only — `True` if newly added, `False` if already a member |
| `remove_from_<field>` | `(e, value: ElementType) -> Bool` | `multi` fields only — `True` if it was actually removed |
| `all` | `() -> Set[EntityHandle[...]]` | every currently-live entity in the table — generated for every struct, `keepalive` or not (see below) |
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

```
@@struct keepalive @@Project:
    name: String
```

```
_ = @@Project.create(name = "Website Revamp");   # handle discarded, entity lives on
_ = @@Project.create(name = "Onboarding Redesign");
print("all projects:", len(@@Project.all()));
```

`all()` itself doesn't depend on `keepalive` at all — it walks the table's
own id allocator directly (`Table.all()`, one pass, checking which ids are
currently allocated), so it finds every live entity regardless of *why*
it's alive: a relation elsewhere, a local handle, or `keepalive`. Every
struct gets `all()`; only a `keepalive`-tagged one also gets the `Set`
field and `dont_keepalive`.

## Project layout

```
src/squirrel_compiler/   the compiler: parser.mojo (scans .rel text into
                          markers), codegen.mojo (marker -> Mojo text),
                          driver.mojo (walks a directory, resolves
                          cross-file relations, writes output)
src/squirrel_runtime/    the runtime every generated file imports:
                          entity/ (EntityHandle, Table, id allocation),
                          rel/ (Rel, UniqueRel, ForwardOnlyRel, MultiRel --
                          the per-field storage backing each modifier above)
src/main.mojo            CLI entry point: `mojo run -I src src/main.mojo <dir>`
examples/                see kitchen_sink for a tour of every feature;
                          the others are smaller, single-feature examples
test/                    one test file per compiler/runtime module
```

## How compilation works

1. **`discover_structs`/`discover_plain_structs`** parse every `.rel` file
   under the target directory (without emitting anything yet), so a
   relation field can target a struct declared in a different file.
2. **`check_no_relation_cycles`** rejects any schema whose relation fields
   form a cycle, directly or transitively — required both because
   `create()` needs every relation field's target to already exist, and
   because Mojo's `ArcPointer` has no cycle collector.
3. **`emit_file`** rewrites each file's markers into real Mojo (via
   `transform_source`) and prefixes the runtime imports it needs.

A schema-level error (a cyclic relation, a mismatched `@@` marking, ...)
is reported as `path/to/file.rel:line:col: Category: message`.

## Development

```sh
pixi run test        # runs every test/test_*.mojo file
pixi run run <dir>    # compiles every .rel file under <dir>
```

No compiler warnings are tolerated in generated or example code — treat one
as a bug the same as a hard error.
