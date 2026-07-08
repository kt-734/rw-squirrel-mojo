# Examples

Every example lives under
[`examples/`](https://github.com/kt-734/rw-squirrel-mojo/tree/main/examples)
and runs the same way:

```sh
pixi run run examples/<name>
pixi run mojo run -I examples/<name> examples/<name>/<entry>.mojo
```

## Start here

**[`greeter`](https://github.com/kt-734/rw-squirrel-mojo/tree/main/examples/greeter)**
— the smallest possible project: one `@@struct`, one entity, a field read
and a field write. If you're looking for the minimal shape of a Squirrel
program, this is it.

**[`unique_field`](https://github.com/kt-734/rw-squirrel-mojo/tree/main/examples/unique_field)**
— `unique email: String`: constructing a duplicate raises, `for_email(...)`
returns the one match directly (not a list), and a non-`unique` field's
`for_<field>` is compared side by side, including indexing into its result
with `@@matches[0]`.

## Relations

**[`arrays_and_relations`](https://github.com/kt-734/rw-squirrel-mojo/tree/main/examples/arrays_and_relations)**
— a `@@dept: @@Department` relation field, its generated `for_dept` reverse
lookup, and a hand-written (non-`@@`-marked) Mojo function that threads
`sqrrl__world` by hand and hands back a plain `EntityHandle` — showing the
escape hatch [Advanced features](advanced-features.md) covers in full.

**[`company`](https://github.com/kt-734/rw-squirrel-mojo/tree/main/examples/company)**
— a relation field pointing the *other* direction (`@@Person` holding
`@@employee: @@Employee`), across multiple files.

**[`org`](https://github.com/kt-734/rw-squirrel-mojo/tree/main/examples/org)**
— entity construction factored into `@@`-marked functions
(`@@make_department`, `@@hire`, `@@make_team`) imported across files, with
`main` itself never writing a `@@Type{...}` construct directly:

```
from logic.factories import @@make_department, @@hire, @@make_person, @@make_team

def main() raises:
    @@declare();
    @@init();
    var @@dept = @@make_department("Engineering");
    var @@emp = @@hire("Engineer", @@dept);
    var @@alice = @@make_person("alice", @@emp);
```

## The full tour

**[`kitchen_sink`](https://github.com/kt-734/rw-squirrel-mojo/tree/main/examples/kitchen_sink)**
— every field modifier (`unique`, `forwardonly`, `multi`, `ordered`,
`keepalive`) in one schema, plus plain structs and relation-hopping, in a
single project. Start here once `greeter` feels too small.

**[`kitchen_sink_plus`](https://github.com/kt-734/rw-squirrel-mojo/tree/main/examples/kitchen_sink_plus)**
— deep relation chains and diamonds, generic and hand-written plain
structs, deeply nested containers, and the whole-world JSON dump/reload
(`@@start_init_from_json`/`@@finalize_init_from_json`) in one script. The
one to read once you need to know how a specific combination of features
actually interacts.
