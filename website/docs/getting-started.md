# Getting started

Squirrel is built and run through [pixi](https://pixi.sh). Everything below
assumes you're at the root of the repo.

## Install

```sh
pixi install
```

This pulls in Mojo itself (pinned in `pixi.toml`) — there's nothing else to
set up.

## Compile a project

A Squirrel project is a directory of `.rel` files. Compiling walks every
`.rel` file under it, writes a generated `.mojo` file alongside each source
file, writes a shared `sqrrl__world.mojo`, and copies the runtime in:

```sh
pixi run run examples/greeter
```

Then run the result like any other Mojo program:

```sh
pixi run mojo run -I examples/greeter examples/greeter/greeter.mojo
```

## Write your first schema

Create a directory with one `.rel` file:

```
@@struct @@Person:
    name: String
    age: UInt32

def main() raises:
    @@declare()
    @@init()
    var @@alice = @@Person { .name = "alice", .age = 30 }
    @@alice.age = 31
    print(@@alice.name, @@alice.age)
```

Compile and run it the same way as above. `@@declare()` brings a shared
`sqrrl__world` into scope — once, project-wide — and `@@init()` builds it.
Everything else in this file is ordinary Mojo; only the `@@`-marked pieces
get rewritten.

## Run the test suite

```sh
pixi run test
```

## Where to go next

- [DSL guide](dsl-guide.md) — the full `@@` grammar: relations, field
  modifiers, iteration, JSON serialization.
- [Examples](examples.md) — a tour of the example projects, from a minimal
  greeter to a multi-file schema with deep relation chains.
- [Advanced features](advanced-features.md) — threading `sqrrl__world` by
  hand, for boundaries the `@@` sugar doesn't reach.
