from squirrel_runtime.entity import Table, EntityHandle, EntityInner, TableStateLike
from squirrel_runtime.rel import Rel, UniqueRel, ForwardOnlyRel, MultiRel, OrderedRel
from std.collections import Set
from std.os import abort


struct Money(Copyable, Movable, ImplicitlyDeletable):
    var cents: Int64

    def __init__(out self, var cents: Int64):
        self.cents = cents
