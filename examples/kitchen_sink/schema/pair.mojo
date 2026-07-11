from squirrel_runtime.entity import Table, EntityHandle, EntityInner, TableStateLike
from squirrel_runtime.rel import Rel, UniqueRel, ForwardOnlyRel, MultiRel, OrderedRel
from std.collections import Set
from std.os import abort


struct Pair[A: Copyable & ImplicitlyDeletable, B: Copyable & ImplicitlyDeletable](Copyable, Movable, ImplicitlyDeletable):
    var first: Self.A
    var second: Self.B

    def __init__(out self, var first: Self.A, var second: Self.B):
        self.first = first^
        self.second = second^


