# `__del__` runs before a same-scope temporary's own destructor, breaking strong-count checks

**Mojo version:** `1.0.0b3.dev2026070206 (b5217d26)`

## Summary

A struct's `__del__(deinit self)`, invoked implicitly when a local variable
falls out of scope at the end of a function, appears to run *before* a
temporary value created from one of that struct's own methods earlier in the
same function has actually been destroyed — even though normal reverse-
declaration-order (LIFO) semantics say the temporary, being "younger," should
be destroyed first. The result: an `ArcPointer`'s strong count, read from
inside `__del__`, is one higher than it should be.

Calling the exact same check *explicitly*, from an ordinary method call
instead of from `__del__`, gives the correct count.

## Minimal reproduction

```mojo
from std.memory import ArcPointer
from std.os import abort


struct Handle(Movable):
    var marker: ArcPointer[Int]

    def __init__(out self, var marker: ArcPointer[Int]):
        self.marker = marker^


struct World(Movable):
    var marker: ArcPointer[Int]

    def __init__(out self):
        self.marker = ArcPointer(0)

    def make(mut self) -> Handle:
        return Handle(self.marker.copy())

    def check(mut self):
        if self.marker.count() > 1:
            abort("still referenced: strong count=" + String(self.marker.count()))

    def __del__(deinit self):
        self.check()


def main() raises:
    var w = World()
    _ = w.make()
    print("done")
```

**Expected:** `make()`'s returned `Handle` is discarded (bound to `_`)
immediately, dropping the copied `ArcPointer` and decrementing the strong
count back to 1. `print("done")` runs. `w` then falls out of scope, `__del__`
runs, `self.marker.count()` reads `1`, no abort.

**Actual:** `print("done")` never runs at all — the program aborts before
reaching it:

```
ABORT: main.mojo:23:18: still referenced: strong count=2
```

`self.marker.count()` reads `2` inside `__del__`, as if the `Handle` returned
by `make()` (and immediately discarded) were still alive. `__del__` appears
to fire immediately after `w`'s own last textual mention (the `w.make()`
call), *before* the discarded `Handle`'s temporary has been cleaned up —
rather than after every other local in the function, as LIFO destruction
order would predict.

## Contrast: the identical check, called explicitly, is correct

Adding one line — calling the exact same `check()` method manually, instead
of relying on `__del__` — makes it pass:

```mojo
def main() raises:
    var w = World()
    _ = w.make()
    print("done")
    w.check()   # <-- added
```

```
done
```

No abort. `self.marker.count()` correctly reads `1` this time. The only
difference between the two programs is *how* `check()`/`__del__` gets
invoked — the logic inside `check()` is untouched.

## Notes

- This isn't about borrowed references or origins — `ArcPointer` is an owned,
  reference-counted value, not a borrow tied to a lifetime parameter. The
  issue looks like a destructor-*ordering* bug in ASAP-destruction/liveness
  analysis specifically around `deinit self` / `__del__`, not a borrow-
  checking issue.
- Reproduces identically whether the discarded value is bound to a bare `_`
  or to a named `var` later discarded via explicit transfer (`_ = t^`).
- Adding *any* later statement that also touches `w` (even one unrelated to
  the leak) moves `__del__`'s insertion point later and the bug disappears —
  consistent with `__del__` being inserted at `w`'s own last-mention point
  rather than at the true end of scope.
- Found while debugging a project ([Squirrel](https://github.com/kt-734/rw-squirrel-mojo))
  that generates code relying on `__del__` to catch a "did you forget to
  drop this" bug class — the exact same shape (a container struct owning an
  `ArcPointer`-backed resource, handed out via a method, checked for leftover
  strong references in `__del__`) triggers this every time, making that
  container struct's own `__del__`-based safety check unreliable.
