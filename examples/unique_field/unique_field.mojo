from squirrel_runtime.entity import Table, EntityHandle, EntityInner, TableStateLike
from squirrel_runtime.rel import Rel, UniqueRel, ForwardOnlyRel, MultiRel, OrderedRel
from std.collections import Set
from std.os import abort
from sqrrl__Squirrel import sqrrl__init, sqrrl__Squirrel


struct sqrrl__PersonTableState(TableStateLike, Movable, ImplicitlyDeletable):
    var email: UniqueRel[String]
    var name: Rel[String]

    def __init__(out self):
        self.email = UniqueRel[String]()
        self.name = Rel[String]()

    def sqrrl__cleanup_relations(mut self, id: UInt32):
        _ = self.email.fetch_remove_fwd(id)
        _ = self.name.fetch_remove_fwd(id)


struct sqrrl__PersonTable(Movable):
    var table: Table[sqrrl__PersonTableState]

    def __init__(out self):
        self.table = Table[sqrrl__PersonTableState](sqrrl__PersonTableState())

    def create(mut self, email: String, name: String) raises -> EntityHandle[sqrrl__PersonTableState]:
        var e = self.table.create()
        self.table.state[].state.email.put(e.id(), email)
        self.table.state[].state.name.put(e.id(), name)
        return e

    def all(self) -> Set[EntityHandle[sqrrl__PersonTableState]]:
        return self.table.all()

    def get_email(self, e: EntityHandle[sqrrl__PersonTableState]) -> String:
        var got = self.table.state[].state.email.get_fwd(e.id())
        return got.take()

    def set_email(mut self, e: EntityHandle[sqrrl__PersonTableState], v: String) raises:
        self.table.state[].state.email.update(e.id(), v)

    def for_email(self, value: String) raises -> EntityHandle[sqrrl__PersonTableState]:
        var id = self.table.state[].state.email.get_bwd(value)
        return self.table.handle_for(id)

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
def main() raises:
    var sqrrl__world = sqrrl__init();
    var sqrrl__alice = sqrrl__world.Person.create(email = "alice@example.com", name = "alice");
    var sqrrl__bob = sqrrl__world.Person.create(email = "bob@example.com", name = "bob");

    var sqrrl__found = sqrrl__world.Person.for_email("bob@example.com");
    print("found by email:", sqrrl__world.Person.get_name(sqrrl__found));

    try:
        var sqrrl__carol = sqrrl__world.Person.create(email = "alice@example.com", name = "carol");
        print("should not reach here");
    except e:
        print("rejected duplicate email:", e);

    var sqrrl__matches = sqrrl__world.Person.for_name("alice");
    print("for_name is not unique, so it returns a list:", len(sqrrl__matches), "match(es)");
    print("indexed into it:", sqrrl__world.Person.get_name(sqrrl__matches[0]));

    print(sqrrl__world.Person.get_name(sqrrl__alice), sqrrl__world.Person.get_name(sqrrl__bob));
