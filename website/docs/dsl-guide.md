# DSL guide

`@@` marks everything Squirrel-specific — struct declarations, entity
construction, relation fields, and world threading. A `.rel` file is
otherwise just Mojo; anything not `@@`-marked passes through untouched. See
[`examples/kitchen_sink`](https://github.com/kt-734/rw-squirrel-mojo/tree/main/examples/kitchen_sink)
for all of this combined in one project.

## Declaring an entity struct

`@@struct` gets a generated table, an id allocator, and
`create`/`get_<field>`/`set_<field>`/`for_<field>` methods per field:

```
@@struct @@Person:
    name: String
    age: UInt32
```

## Constructing and using one

`@@{` brings the shared world into scope once (typically in `main`),
already a real, live, empty world; `@@}` closes the block, checking that
nothing built inside it is still alive before the function returns.
Everything between the two has to be written one level deeper, exactly
like a hand-written `try:`/`finally:` body — `@@{`/`@@}` supply that
boilerplate, not the indentation:

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
after `@@{`, which already starts empty). `@@start_init_from_json(json)` is
its reload counterpart, reconstructing the world from a previous
`sqrrl__world.to_json()` dump instead. Either may be called any number of
times after `@@{`, in any control-flow shape — including conditionally
(see `@@finalize_init_from_json()`/`@@init_from_json(...)` below for the
reload side's own cleanup step).

Every `@@init()`/`@@start_init_from_json(...)` call checks that whatever
`sqrrl__world` currently holds is empty before replacing it. If something is
still alive in it, that's a real bug worth surfacing rather than silently
discarding: it `abort`s with a `LeakedEntities` message. `@@}` runs the same
check, via an explicit `finally:` rather than relying on `sqrrl__World`'s
own `__del__`. Every `@@{` needs a matching `@@}` before its own function
ends — checked at compile time.

!!! warning "Known limitation"

    `sqrrl__World`'s own `__del__`, invoked implicitly at ordinary
    end-of-scope, has been observed to run *before* a same-scope temporary's
    own destructor — a false-positive `LeakedEntities` abort that the same
    check, called explicitly, never produces. This appears to be a Mojo
    compiler bug in destructor-insertion ordering around `deinit self`, not
    a bug in generated code (see
    [`mojo-del-destructor-ordering-bug.md`](https://github.com/kt-734/rw-squirrel-mojo/blob/main/mojo-del-destructor-ordering-bug.md)
    for a minimal, Squirrel-independent reproduction). `@@{`/`@@}` exist
    specifically to work around it: everything between them runs inside a
    `try:`, and `@@}`'s `finally:` runs the leak check explicitly, at the
    block's real exit point, for every exit path -- not relying on
    `__del__` at all. `__del__` is still generated as a backstop for
    anything that manages to skip `@@}` regardless, but the ordinary path
    through a `@@{`/`@@}` block never depends on it firing correctly.

A second, independent `@@{` anywhere else in the project is rejected
outright.

`@@finalize_init_from_json()` is required, not optional cleanup — it drops
every entity `@@start_init_from_json(...)` retained only *temporarily*
while reconstructing the world (see "JSON serialization" below for why
that retention is needed and where it lives). Skip it and the *next* leak
check — the next `@@init()`-family call, or `@@}`/`sqrrl__world.__del__` if
the function just returns — aborts: every non-`keepalive` entity the
reload retained is still "live" as far as the leak check is concerned
until this runs. Call it once a script has grabbed whatever references it
actually cares about from the reload; anything else — with no relation and
no `keepalive` tag holding it — is destroyed right then, same as any other
last handle dropping:

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

## Relation fields

A field typed `@@Type` points at another entity (refcounted: the target
stays alive as long as anything points at it). `for_<field>` is the reverse
lookup:

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

## Indexing and iterating

A tracked container (`for_<field>`'s result, or a container-typed entity
parameter) indexes with `@@name[i]`, and a further `.field` after that
reads/writes right through the indexed element:

```
print("first team member:", @@team[0].title)
@@team[0].title = "Lead Engineer"      # write-through-index
```

`for @@name in <container-call>:` binds `@@name` to the *element* type, so
`@@name.field` works directly inside the loop body, no indexing needed:

```
for @@emp in @@Employee.for_dept(@@eng):
    print(@@emp.title)
```

An ordinary, unmarked `for x in y:` is untouched, same as any other plain
Mojo code.

## Hopping through relations

A chain of `.@@relation` reads or writes follow each hop automatically. The
chain doesn't need to end in a plain field, either — ending on a relation
hop reads that relation itself, tracked the same way `get_<field>` is:

```
print(@@alice.@@job.@@dept.name)
@@alice.@@job.title = "Junior Engineer"
var @@alices_job_dept = @@alice.@@job.@@dept
```

## Field modifiers

One keyword before a field name:

| keyword       | meaning                                                              |
| ------------- | ---------------------------------------------------------------------|
| `unique`      | at most one entity may hold a given value; `for_<field>` raises instead of returning a list, and a duplicate raises on construction |
| `forwardonly` | no reverse index at all — for fields whose type isn't hashable, or where the reverse lookup is simply never needed |
| `multi`       | a genuine many-to-many relation: `Set[T]`-backed, with `add_to_<field>`/`remove_from_<field>` mutating one member at a time and `for_<field>` as the reverse query. Only ever needs declaring on *one* side |
| `ordered`     | a sorted index alongside the field's value, giving range queries (`for_<field>_greater_than`/`_less_than`/`_at_least`/`_at_most`/`_between`) in addition to the usual exact-match `for_<field>` |

```
@@struct @@Person:
    unique email: String
    forwardonly tags: List[String]
```

**`multi`** answers both directions from a single declaration:

```
@@struct @@Department:
    name: String
    multi @@projects: @@Project
```

```
_ = @@Department.add_to_projects(@@eng, @@website)
print(len(@@eng.@@projects))                          # this dept's projects
print(len(@@Department.for_projects(@@website)))      # which depts run this project
```

**`ordered`** gives range queries a hash-backed `Rel` can't answer quickly:

```
@@struct @@Employee:
    name: String
    ordered years_employed: UInt32
```

```
for @@e in @@Employee.for_years_employed_greater_than(4):
    print(@@e.name)
for @@e in @@Employee.for_years_employed_between(2, 5):
    print(@@e.name)
```

## `@@`-marked functions

Marking a function's own *name* with `@@` (`def @@name(...)`, not a
parameter) auto-threads the world through it: its definition gets `mut
sqrrl__world: sqrrl__World` inserted as its first parameter, and every call
site gets `sqrrl__world` inserted as its first argument — silently, on both
ends:

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

A call site only works inside a function that already has `sqrrl__world`
itself, via `@@init()` or its own `@@`-marked name/parameters.

## Plain structs

A bare `struct` (no `@@`) is an ordinary embedded value, not its own table.
It can hold plain fields, *and* its own `@@`-marked relation fields pointing
back at a real entity struct:

```
struct Note {
    @@author: @@Employee,
    text: String,
}

@@struct @@Person:
    name: String
    forwardonly home: Address
```

## `keepalive`

An entity normally dies the moment its last handle drops. `keepalive` on a
`@@struct` overrides that — `create` adds every new entity to an internal
set, so it survives with no relation or local variable holding it:

```
@@struct keepalive @@Project:
    name: String
```

```
_ = @@Project.create(name = "Website Revamp")    # handle discarded, entity lives on
print("all projects:", len(@@Project.all()))
```

## JSON serialization

`sqrrl__world` itself has `to_json`/a reload counterpart, dumping and
restoring every table's every live entity at once — there's no per-entity
`@@Type.to_json(...)` sugar, since a relation field only ever serializes as
the target's bare id, not its contents. `@@init()`'s reload counterpart is
`@@start_init_from_json`/`@@finalize_init_from_json` (see "Constructing and
using one" above); the dump half has no sugar at all — there's nothing to
inject, it just always dumps everything — so that's thread-`sqrrl__world`-
by-hand territory (see [Advanced features](advanced-features.md)):

```
var dump = sqrrl__world.to_json()      # -> String, every table's every live entity

var sc = sqrrl__JsonScanner(dump)
var reloaded = sqrrl__world_from_json(sc)    # -> sqrrl__World, a fresh one
```

Reconstruction proceeds in dependency order, so by the time any entity's
relation field is resolved, its target is already live in the reloaded
world. `unique` fields still enforce their constraint through reload.

For the full detail on generated method signatures, container-type
inference, and the dump/reload internals, see the
[README](https://github.com/kt-734/rw-squirrel-mojo/blob/main/README.md).
