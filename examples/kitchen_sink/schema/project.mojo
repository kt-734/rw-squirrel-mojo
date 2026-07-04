from squirrel_runtime.entity import Table, EntityHandle, EntityInner, TableStateLike
from squirrel_runtime.rel import Rel, UniqueRel, ForwardOnlyRel, MultiRel, OrderedRel
from std.collections import Set
from std.os import abort


struct sqrrl__ProjectTableState(TableStateLike, Movable, ImplicitlyDeletable):
    var name: Rel[String]

    def __init__(out self):
        self.name = Rel[String]()

    def sqrrl__cleanup_relations(mut self, id: UInt32):
        _ = self.name.fetch_remove_fwd(id)


struct sqrrl__ProjectTable(Movable):
    var table: Table[sqrrl__ProjectTableState]

    def __init__(out self):
        self.table = Table[sqrrl__ProjectTableState](sqrrl__ProjectTableState())

    def create(mut self, name: String) -> EntityHandle[sqrrl__ProjectTableState]:
        var e = self.table.create()
        self.table.state[].state.name.put(e.id(), name)
        return e

    def all(self) -> Set[EntityHandle[sqrrl__ProjectTableState]]:
        return self.table.all()

    def get_name(self, e: EntityHandle[sqrrl__ProjectTableState]) -> String:
        var got = self.table.state[].state.name.get_fwd(e.id())
        return got.take()

    def set_name(mut self, e: EntityHandle[sqrrl__ProjectTableState], v: String):
        self.table.state[].state.name.update(e.id(), v)

    def for_name(self, value: String) -> List[EntityHandle[sqrrl__ProjectTableState]]:
        var ids = self.table.state[].state.name.get_bwd(value)
        var out = List[EntityHandle[sqrrl__ProjectTableState]]()
        for id in ids:
            out.append(self.table.handle_for(id))
        return out^
