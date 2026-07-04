from squirrel_runtime.entity import Table, EntityHandle, EntityInner, TableStateLike
from squirrel_runtime.rel import Rel, UniqueRel, ForwardOnlyRel, MultiRel, OrderedRel
from std.collections import Set
from std.os import abort


struct Address(Copyable, Movable, ImplicitlyDeletable):
    var city: String

    def __init__(out self, var city: String):
        self.city = city^
