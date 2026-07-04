from squirrel_runtime.entity import Table, EntityHandle, EntityInner, TableStateLike
from squirrel_runtime.rel import Rel, UniqueRel, ForwardOnlyRel, MultiRel, OrderedRel
from std.collections import Set
from std.os import abort


struct sqrrl__AuditLogTableState(TableStateLike, Movable, ImplicitlyDeletable):
    var message: Rel[String]

    def __init__(out self):
        self.message = Rel[String]()

    def sqrrl__cleanup_relations(mut self, id: UInt32):
        _ = self.message.fetch_remove_fwd(id)


struct sqrrl__AuditLogTable(Movable):
    var table: Table[sqrrl__AuditLogTableState]
    var keepalive: Set[EntityHandle[sqrrl__AuditLogTableState]]

    def __init__(out self):
        self.table = Table[sqrrl__AuditLogTableState](sqrrl__AuditLogTableState())
        self.keepalive = Set[EntityHandle[sqrrl__AuditLogTableState]]()

    def create(mut self, message: String) -> EntityHandle[sqrrl__AuditLogTableState]:
        var e = self.table.create()
        self.table.state[].state.message.put(e.id(), message)
        self.keepalive.add(e.copy())
        return e

    def all(self) -> Set[EntityHandle[sqrrl__AuditLogTableState]]:
        return self.table.all()

    def dont_keepalive(mut self, e: EntityHandle[sqrrl__AuditLogTableState]) -> Bool:
        try:
            self.keepalive.remove(e)
            return True
        except:
            return False

    def get_message(self, e: EntityHandle[sqrrl__AuditLogTableState]) -> String:
        var got = self.table.state[].state.message.get_fwd(e.id())
        return got.take()

    def set_message(mut self, e: EntityHandle[sqrrl__AuditLogTableState], v: String):
        self.table.state[].state.message.update(e.id(), v)

    def for_message(self, value: String) -> List[EntityHandle[sqrrl__AuditLogTableState]]:
        var ids = self.table.state[].state.message.get_bwd(value)
        var out = List[EntityHandle[sqrrl__AuditLogTableState]]()
        for id in ids:
            out.append(self.table.handle_for(id))
        return out^
