# Getting started

![](images/emblems/getting-started.png){ align=right width="180" }

Squirrel isn't published as a package manager package — but you don't need
to build it yourself either. A tagged release ships a ready-to-run
`squirrelc` bundle; nothing about using it requires pixi, Mojo's own
toolchain, or a checkout of this repository.

## Install the compiler

Download and unpack the latest release for Linux x86_64:

```sh
curl -LO https://github.com/kt-734/rw-squirrel-mojo/releases/latest/download/squirrelc-linux-x86_64.tar.gz
tar -xzf squirrelc-linux-x86_64.tar.gz
```

Linux x86_64 is the only release built today. Other OSes/architectures are
planned closer to a 1.0.0 release — until then, building from source
(below) on the target machine itself is the way to get `squirrelc` running
anywhere else. Note this inherits Mojo's own platform support: Mojo
doesn't run natively on Windows yet, so on Windows that means WSL rather
than a native build.

This unpacks a `squirrelc` executable and a `lib/` directory next to it —
`squirrelc` looks for its libraries there, so move or copy the *pair*
together (don't separate `squirrelc` from its `lib/`):

```sh
mkdir -p ~/.local/squirrel && mv squirrelc lib ~/.local/squirrel/
export PATH="$HOME/.local/squirrel:$PATH"   # add to your shell profile to keep it
```

### Building from source instead

If you'd rather build it yourself — say, to pick up an unreleased fix —
clone the repo and use [pixi](https://pixi.sh):

```sh
git clone https://github.com/kt-734/rw-squirrel-mojo.git
cd rw-squirrel-mojo
pixi install
pixi run package
```

`pixi run package` builds `squirrelc` and bundles the Mojo runtime shared
libraries it links against into `dist/lib/` (Mojo builds aren't statically
linked, so the bare executable alone only runs on the exact machine that
built it) — the same bundle a tagged release ships. `pixi run build` alone
produces just the executable, useful for quick local iteration, but it
isn't portable off of this checkout on its own.

## Compile a project

A Squirrel project is a directory of `.rel` files, anywhere on disk.
Compiling walks every `.rel` file under it, writes a generated `.mojo` file
alongside each source file, writes a shared `sqrrl__world.mojo`, and writes
the runtime package the generated code imports:

```sh
squirrelc examples/greeter
```

Then run the result like any other Mojo program — this part does need
Mojo's own toolchain installed separately (`-I` tells it where to resolve
the runtime package the generated code imports):

```sh
mojo run -I examples/greeter examples/greeter/greeter.mojo
```

Building from source instead of installing a release, the same compile
step also works straight from source, via pixi, from inside the checkout:

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
    @@{
        var @@alice = @@Person { .name = "alice", .age = 30 }
        @@alice.age = 31
        print(@@alice.name, @@alice.age)
    @@}
```

Compile and run it the same way as above. `@@{` brings a shared
`sqrrl__world` into scope — once, project-wide, already a real, empty
world — and `@@}` closes the block. Everything else in this file is
ordinary Mojo; only the `@@`-marked pieces get rewritten.

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
