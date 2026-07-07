from squirrel_runtime.entity import Table, EntityHandle, EntityInner, TableStateLike
from squirrel_runtime.rel import Rel, UniqueRel, ForwardOnlyRel, MultiRel, OrderedRel
from std.collections import Set
from std.os import abort
from sqrrl__json import sqrrl__to_json, sqrrl__from_json
from squirrel_runtime.json import sqrrl__JsonScanner
from sqrrl__json import sqrrl__Box_from_json
from sqrrl__json import sqrrl__Address_from_json
from sqrrl__json import sqrrl__Pair_from_json
from sqrrl__json import sqrrl__ContactInfo_from_json
from sqrrl__json import sqrrl__Assignment_from_json
from sqrrl__json import sqrrl__Profile_from_json
from sqrrl__json import sqrrl__Money_from_json


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

    def sqrrl__create_with_id(mut self, sqrrl__id: UInt32, message: String) raises -> EntityHandle[sqrrl__AuditLogTableState]:
        var e = self.table.create_with_id(sqrrl__id)
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

    def to_json(self, e: EntityHandle[sqrrl__AuditLogTableState]) -> String:
        var out = String("{")
        out += "\"message\":" + sqrrl__to_json(self.get_message(e))
        out += "}"
        return out^

    def from_json(mut self, mut sc: sqrrl__JsonScanner) raises -> EntityHandle[sqrrl__AuditLogTableState]:
        var sqrrl__parsed_message: Optional[String] = None
        sc.expect_byte(UInt8(ord("{")))
        if not sc.try_consume_byte(UInt8(ord("}"))):
            while True:
                var sqrrl__key = sc.parse_json_string()
                sc.expect_byte(UInt8(ord(":")))
                if sqrrl__key == "message":
                    sqrrl__parsed_message = sqrrl__from_json[String](sc)
                if sc.try_consume_byte(UInt8(ord(","))):
                    continue
                sc.expect_byte(UInt8(ord("}")))
                break
        return self.create(sqrrl__parsed_message.take())

    def sqrrl__from_json_with_id(mut self, sqrrl__id: UInt32, mut sc: sqrrl__JsonScanner) raises -> EntityHandle[sqrrl__AuditLogTableState]:
        var sqrrl__parsed_message: Optional[String] = None
        sc.expect_byte(UInt8(ord("{")))
        if not sc.try_consume_byte(UInt8(ord("}"))):
            while True:
                var sqrrl__key = sc.parse_json_string()
                sc.expect_byte(UInt8(ord(":")))
                if sqrrl__key == "message":
                    sqrrl__parsed_message = sqrrl__from_json[String](sc)
                if sc.try_consume_byte(UInt8(ord(","))):
                    continue
                sc.expect_byte(UInt8(ord("}")))
                break
        return self.sqrrl__create_with_id(sqrrl__id, sqrrl__parsed_message.take())

    def all_to_json(self) -> String:
        var out = String("[")
        var sqrrl__first = True
        for sqrrl__e in self.all():
            if not sqrrl__first:
                out += ","
            sqrrl__first = False
            out += "[" + String(sqrrl__e.id()) + "," + self.to_json(sqrrl__e) + "]"
        out += "]"
        return out^

    def all_from_json(mut self, mut sc: sqrrl__JsonScanner) raises:
        sc.expect_byte(UInt8(ord("[")))
        if not sc.try_consume_byte(UInt8(ord("]"))):
            while True:
                sc.expect_byte(UInt8(ord("[")))
                var sqrrl__id = UInt32(sc.parse_json_int())
                sc.expect_byte(UInt8(ord(",")))
                _ = self.sqrrl__from_json_with_id(sqrrl__id, sc)
                sc.expect_byte(UInt8(ord("]")))
                if sc.try_consume_byte(UInt8(ord(","))):
                    continue
                sc.expect_byte(UInt8(ord("]")))
                break
