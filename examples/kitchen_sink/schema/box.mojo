from squirrel_runtime.entity import Table, EntityHandle, EntityInner, TableStateLike
from squirrel_runtime.rel import Rel, UniqueRel, ForwardOnlyRel, MultiRel, OrderedRel
from std.collections import Set
from std.os import abort


struct Box[T: Copyable & ImplicitlyDeletable](Copyable, Movable, ImplicitlyDeletable):
    var value: Self.T

    def __init__(out self, var value: Self.T):
        self.value = value^


