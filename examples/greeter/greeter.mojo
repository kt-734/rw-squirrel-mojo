from squirrel_runtime.entity import Table, EntityHandle, EntityInner, TableStateLike
from squirrel_runtime.rel import Rel, UniqueRel, ForwardOnlyRel, MultiRel, OrderedRel
from std.collections import Set
from std.os import abort
from sqrrl__Squirrel import sqrrl__init, sqrrl__Squirrel


struct sqrrl__PersonTableState(TableStateLike, Movable, ImplicitlyDeletable):
    var name: Rel[String]
    var age: Rel[UInt32]

    def __init__(out self):
        self.name = Rel[String]()
        self.age = Rel[UInt32]()

    def sqrrl__cleanup_relations(mut self, id: UInt32):
        _ = self.name.fetch_remove_fwd(id)
        _ = self.age.fetch_remove_fwd(id)


struct sqrrl__PersonTable(Movable):
    var table: Table[sqrrl__PersonTableState]

    def __init__(out self):
        self.table = Table[sqrrl__PersonTableState](sqrrl__PersonTableState())

    def create(mut self, name: String, age: UInt32) -> EntityHandle[sqrrl__PersonTableState]:
        var e = self.table.create()
        self.table.state[].state.name.put(e.id(), name)
        self.table.state[].state.age.put(e.id(), age)
        return e

    def all(self) -> Set[EntityHandle[sqrrl__PersonTableState]]:
        return self.table.all()

    def get_name(self, e: EntityHandle[sqrrl__PersonTableState]) -> String:
        var got = self.table.state[].state.name.get_fwd(e.id())
        return got.take()

    def set_name(mut self, e: EntityHandle[sqrrl__PersonTableState], v: String):
        self.table.state[].state.name.update(e.id(), v)

    def for_name(self, value: String) -> List[EntityHandle[sqrrl__PersonTableState]]:
        var ids = self.table.state[].state.name.get_bwd(value)
        var out = List[EntityHandle[sqrrl__PersonTableState]]()
        for id in ids:
            out.append(self.table.handle_for(id))
        return out^

    def get_age(self, e: EntityHandle[sqrrl__PersonTableState]) -> UInt32:
        var got = self.table.state[].state.age.get_fwd(e.id())
        return got.take()

    def set_age(mut self, e: EntityHandle[sqrrl__PersonTableState], v: UInt32):
        self.table.state[].state.age.update(e.id(), v)

    def for_age(self, value: UInt32) -> List[EntityHandle[sqrrl__PersonTableState]]:
        var ids = self.table.state[].state.age.get_bwd(value)
        var out = List[EntityHandle[sqrrl__PersonTableState]]()
        for id in ids:
            out.append(self.table.handle_for(id))
        return out^
def main() raises:
    var sqrrl__world = sqrrl__init();
    var sqrrl__alice = sqrrl__world.Person.create(name = "alice", age = 30);
    sqrrl__world.Person.set_age(sqrrl__alice, 31);
    print(sqrrl__world.Person.get_name(sqrrl__alice), sqrrl__world.Person.get_age(sqrrl__alice));
