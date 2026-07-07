from squirrel_runtime.entity import Table, EntityHandle, EntityInner, TableStateLike
from squirrel_runtime.rel import Rel, UniqueRel, ForwardOnlyRel, MultiRel, OrderedRel
from std.collections import Set
from std.os import abort
from schema.person import sqrrl__PersonTableState


struct Assignment(Copyable, Movable, ImplicitlyDeletable):
    var person: EntityHandle[sqrrl__PersonTableState]
    var role: String

    def __init__(out self, var person: EntityHandle[sqrrl__PersonTableState], var role: String):
        self.person = person^
        self.role = role^

