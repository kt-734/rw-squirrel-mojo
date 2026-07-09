# Getting started

Squirrel isn't published as a package — you build it from source, via
[pixi](https://pixi.sh). Building it once gets you a standalone compiler
executable you can put anywhere; nothing about using it afterward requires
pixi, Mojo's toolchain, or this repository to still be around.

## Build the compiler

Install pixi itself first, if you don't already have it — see
[pixi.sh](https://pixi.sh) for platform-specific instructions. Then:

```sh
git clone https://github.com/kt-734/rw-squirrel-mojo.git
cd rw-squirrel-mojo
pixi install
pixi run build
```

This produces a `squirrelc` executable in the repo root. It's fully
standalone — the whole runtime it needs to write into every project it
compiles is baked into the binary itself, so it can be copied anywhere
(`/usr/local/bin`, wherever) and run from any working directory, with no
dependency on this checkout still existing:

```sh
cp squirrelc /usr/local/bin/   # optional -- or just reference it by path
```

## Compile a project

A Squirrel project is a directory of `.rel` files, anywhere on disk.
Compiling walks every `.rel` file under it, writes a generated `.mojo` file
alongside each source file, writes a shared `sqrrl__world.mojo`, and writes
the runtime package the generated code imports:

```sh
squirrelc examples/greeter
```

Then run the result like any other Mojo program (this part still needs
Mojo's own toolchain — `-I` tells it where to resolve the runtime package
the generated code imports):

```sh
pixi run mojo run -I examples/greeter examples/greeter/greeter.mojo
```

Without building `squirrelc` first, the same compile step also works
straight from source, via pixi, from inside this checkout:

```sh
pixi run run examples/greeter
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
