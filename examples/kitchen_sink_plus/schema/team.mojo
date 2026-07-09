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
from schema.person import sqrrl__PersonTableState
from schema.person import sqrrl__PersonTable
from schema.employee import sqrrl__EmployeeTableState
from schema.employee import sqrrl__EmployeeTable
from schema.assignment import Assignment


struct sqrrl__TeamTableState(TableStateLike, Movable, ImplicitlyDeletable):
    var name: Rel[String]
    var lead: ForwardOnlyRel[Assignment]
    var members: Rel[List[EntityHandle[sqrrl__PersonTableState]]]
    var advisor: Rel[Optional[EntityHandle[sqrrl__EmployeeTableState]]]

    def __init__(out self):
        self.name = Rel[String]()
        self.lead = ForwardOnlyRel[Assignment]()
        self.members = Rel[List[EntityHandle[sqrrl__PersonTableState]]]()
        self.advisor = Rel[Optional[EntityHandle[sqrrl__EmployeeTableState]]]()

    def sqrrl__cleanup_relations(mut self, id: UInt32):
        _ = self.name.fetch_remove_fwd(id)
        _ = self.lead.fetch_remove_fwd(id)
        _ = self.members.fetch_remove_fwd(id)
        _ = self.advisor.fetch_remove_fwd(id)


struct sqrrl__TeamTable(Movable):
    var table: Table[sqrrl__TeamTableState]

    def __init__(out self):
        self.table = Table[sqrrl__TeamTableState](sqrrl__TeamTableState())

    def create(mut self, name: String, lead: Assignment, members: List[EntityHandle[sqrrl__PersonTableState]], advisor: Optional[EntityHandle[sqrrl__EmployeeTableState]]) -> EntityHandle[sqrrl__TeamTableState]:
        var e = self.table.create()
        self.table.state[].state.name.put(e.id(), name)
        self.table.state[].state.lead.put(e.id(), lead)
        self.table.state[].state.members.put(e.id(), members)
        self.table.state[].state.advisor.put(e.id(), advisor)
        return e

    def sqrrl__create_with_id(mut self, sqrrl__id: UInt32, name: String, lead: Assignment, members: List[EntityHandle[sqrrl__PersonTableState]], advisor: Optional[EntityHandle[sqrrl__EmployeeTableState]]) raises -> EntityHandle[sqrrl__TeamTableState]:
        var e = self.table.create_with_id(sqrrl__id)
        self.table.state[].state.name.put(e.id(), name)
        self.table.state[].state.lead.put(e.id(), lead)
        self.table.state[].state.members.put(e.id(), members)
        self.table.state[].state.advisor.put(e.id(), advisor)
        return e

    def all(self) -> Set[EntityHandle[sqrrl__TeamTableState]]:
        return self.table.all()

    def count(self) -> Int:
        return self.table.count()

    def value_eq(self, a: EntityHandle[sqrrl__TeamTableState], b: EntityHandle[sqrrl__TeamTableState]) -> Bool:
        if self.get_name(a) != self.get_name(b):
            return False
        if self.get_lead(a) != self.get_lead(b):
            return False
        if self.get_members(a) != self.get_members(b):
            return False
        if self.get_advisor(a) != self.get_advisor(b):
            return False
        return True

    def get_name(self, e: EntityHandle[sqrrl__TeamTableState]) -> String:
        var got = self.table.state[].state.name.get_fwd(e.id())
        return got.take()

    def set_name(mut self, e: EntityHandle[sqrrl__TeamTableState], v: String):
        self.table.state[].state.name.update(e.id(), v)

    def for_name(self, value: String) -> List[EntityHandle[sqrrl__TeamTableState]]:
        var ids = self.table.state[].state.name.get_bwd(value)
        var out = List[EntityHandle[sqrrl__TeamTableState]]()
        for id in ids:
            out.append(self.table.handle_for(id))
        return out^

    def count_name(self, value: String) -> Int:
        return len(self.table.state[].state.name.get_bwd(value))

    def group_by_name(self) -> Dict[String, List[EntityHandle[sqrrl__TeamTableState]]]:
        ref buckets = self.table.state[].state.name.all_bwd()
        var out = Dict[String, List[EntityHandle[sqrrl__TeamTableState]]]()
        for entry in buckets.items():
            var handles = List[EntityHandle[sqrrl__TeamTableState]]()
            for id in entry.value:
                handles.append(self.table.handle_for(id))
            out[entry.key] = handles^
        return out^

    def count_by_name(self) -> Dict[String, Int]:
        ref buckets = self.table.state[].state.name.all_bwd()
        var out = Dict[String, Int]()
        for entry in buckets.items():
            out[entry.key] = len(entry.value)
        return out^

    def distinct_name(self) -> Set[String]:
        var out = Set[String]()
        for key in self.table.state[].state.name.all_bwd().keys():
            out.add(key)
        return out^

    def get_lead(self, e: EntityHandle[sqrrl__TeamTableState]) -> Assignment:
        var got = self.table.state[].state.lead.get_fwd(e.id())
        return got.take()

    def set_lead(mut self, e: EntityHandle[sqrrl__TeamTableState], v: Assignment):
        self.table.state[].state.lead.update(e.id(), v)


    def get_members(self, e: EntityHandle[sqrrl__TeamTableState]) -> List[EntityHandle[sqrrl__PersonTableState]]:
        var got = self.table.state[].state.members.get_fwd(e.id())
        return got.take()

    def set_members(mut self, e: EntityHandle[sqrrl__TeamTableState], v: List[EntityHandle[sqrrl__PersonTableState]]):
        self.table.state[].state.members.update(e.id(), v)

    def for_members(self, value: List[EntityHandle[sqrrl__PersonTableState]]) -> List[EntityHandle[sqrrl__TeamTableState]]:
        var ids = self.table.state[].state.members.get_bwd(value)
        var out = List[EntityHandle[sqrrl__TeamTableState]]()
        for id in ids:
            out.append(self.table.handle_for(id))
        return out^

    def count_members(self, value: List[EntityHandle[sqrrl__PersonTableState]]) -> Int:
        return len(self.table.state[].state.members.get_bwd(value))

    def group_by_members(self) -> Dict[List[EntityHandle[sqrrl__PersonTableState]], List[EntityHandle[sqrrl__TeamTableState]]]:
        ref buckets = self.table.state[].state.members.all_bwd()
        var out = Dict[List[EntityHandle[sqrrl__PersonTableState]], List[EntityHandle[sqrrl__TeamTableState]]]()
        for entry in buckets.items():
            var handles = List[EntityHandle[sqrrl__TeamTableState]]()
            for id in entry.value:
                handles.append(self.table.handle_for(id))
            out[entry.key] = handles^
        return out^

    def count_by_members(self) -> Dict[List[EntityHandle[sqrrl__PersonTableState]], Int]:
        ref buckets = self.table.state[].state.members.all_bwd()
        var out = Dict[List[EntityHandle[sqrrl__PersonTableState]], Int]()
        for entry in buckets.items():
            out[entry.key] = len(entry.value)
        return out^

    def distinct_members(self) -> Set[List[EntityHandle[sqrrl__PersonTableState]]]:
        var out = Set[List[EntityHandle[sqrrl__PersonTableState]]]()
        for key in self.table.state[].state.members.all_bwd().keys():
            out.add(key)
        return out^

    def get_advisor(self, e: EntityHandle[sqrrl__TeamTableState]) -> Optional[EntityHandle[sqrrl__EmployeeTableState]]:
        var got = self.table.state[].state.advisor.get_fwd(e.id())
        return got.take()

    def set_advisor(mut self, e: EntityHandle[sqrrl__TeamTableState], v: Optional[EntityHandle[sqrrl__EmployeeTableState]]):
        self.table.state[].state.advisor.update(e.id(), v)

    def for_advisor(self, value: Optional[EntityHandle[sqrrl__EmployeeTableState]]) -> List[EntityHandle[sqrrl__TeamTableState]]:
        var ids = self.table.state[].state.advisor.get_bwd(value)
        var out = List[EntityHandle[sqrrl__TeamTableState]]()
        for id in ids:
            out.append(self.table.handle_for(id))
        return out^

    def count_advisor(self, value: Optional[EntityHandle[sqrrl__EmployeeTableState]]) -> Int:
        return len(self.table.state[].state.advisor.get_bwd(value))

    def group_by_advisor(self) -> Dict[Optional[EntityHandle[sqrrl__EmployeeTableState]], List[EntityHandle[sqrrl__TeamTableState]]]:
        ref buckets = self.table.state[].state.advisor.all_bwd()
        var out = Dict[Optional[EntityHandle[sqrrl__EmployeeTableState]], List[EntityHandle[sqrrl__TeamTableState]]]()
        for entry in buckets.items():
            var handles = List[EntityHandle[sqrrl__TeamTableState]]()
            for id in entry.value:
                handles.append(self.table.handle_for(id))
            out[entry.key] = handles^
        return out^

    def count_by_advisor(self) -> Dict[Optional[EntityHandle[sqrrl__EmployeeTableState]], Int]:
        ref buckets = self.table.state[].state.advisor.all_bwd()
        var out = Dict[Optional[EntityHandle[sqrrl__EmployeeTableState]], Int]()
        for entry in buckets.items():
            out[entry.key] = len(entry.value)
        return out^

    def distinct_advisor(self) -> Set[Optional[EntityHandle[sqrrl__EmployeeTableState]]]:
        var out = Set[Optional[EntityHandle[sqrrl__EmployeeTableState]]]()
        for key in self.table.state[].state.advisor.all_bwd().keys():
            out.add(key)
        return out^

    def sqrrl__to_json(self, e: EntityHandle[sqrrl__TeamTableState]) -> String:
        var out = String("{")
        out += "\"name\":" + sqrrl__to_json(self.get_name(e))
        out += ","
        out += "\"lead\":" + sqrrl__to_json(self.get_lead(e))
        out += ","
        out += "\"members\":" + sqrrl__to_json(self.get_members(e))
        out += ","
        out += "\"advisor\":" + sqrrl__to_json(self.get_advisor(e))
        out += "}"
        return out^

    def sqrrl__from_json(mut self, mut sqrrl__tbl_Person: sqrrl__PersonTable, mut sqrrl__tbl_Employee: sqrrl__EmployeeTable, mut sc: sqrrl__JsonScanner) raises -> EntityHandle[sqrrl__TeamTableState]:
        var sqrrl__parsed_name: Optional[String] = None
        var sqrrl__parsed_lead: Optional[Assignment] = None
        var sqrrl__parsed_members: Optional[List[EntityHandle[sqrrl__PersonTableState]]] = None
        var sqrrl__parsed_advisor: Optional[Optional[EntityHandle[sqrrl__EmployeeTableState]]] = None
        sc.expect_byte(UInt8(ord("{")))
        if not sc.try_consume_byte(UInt8(ord("}"))):
            while True:
                var sqrrl__key = sc.parse_json_string()
                sc.expect_byte(UInt8(ord(":")))
                if sqrrl__key == "name":
                    sqrrl__parsed_name = sqrrl__from_json[String](sc)
                elif sqrrl__key == "lead":
                    sqrrl__parsed_lead = sqrrl__Assignment_from_json(sqrrl__tbl_Person, sc)
                elif sqrrl__key == "members":
                    var sqrrl__parsed_members_tmp = List[EntityHandle[sqrrl__PersonTableState]]()
                    sc.expect_byte(UInt8(ord("[")))
                    if not sc.try_consume_byte(UInt8(ord("]"))):
                        while True:
                            sqrrl__parsed_members_tmp.append(sqrrl__tbl_Person.table.handle_for(UInt32(sc.parse_json_int())))
                            if sc.try_consume_byte(UInt8(ord(","))):
                                continue
                            sc.expect_byte(UInt8(ord("]")))
                            break
                    sqrrl__parsed_members = sqrrl__parsed_members_tmp^
                elif sqrrl__key == "advisor":
                    if sc.try_consume_literal("null"):
                        sqrrl__parsed_advisor = Optional[EntityHandle[sqrrl__EmployeeTableState]](None)
                    else:
                        sqrrl__parsed_advisor = Optional[EntityHandle[sqrrl__EmployeeTableState]](sqrrl__tbl_Employee.table.handle_for(UInt32(sc.parse_json_int())))
                if sc.try_consume_byte(UInt8(ord(","))):
                    continue
                sc.expect_byte(UInt8(ord("}")))
                break
        return self.create(sqrrl__parsed_name.take(), sqrrl__parsed_lead.take(), sqrrl__parsed_members.take(), sqrrl__parsed_advisor.take())

    def sqrrl__from_json_with_id(mut self, mut sqrrl__tbl_Person: sqrrl__PersonTable, mut sqrrl__tbl_Employee: sqrrl__EmployeeTable, sqrrl__id: UInt32, mut sc: sqrrl__JsonScanner) raises -> EntityHandle[sqrrl__TeamTableState]:
        var sqrrl__parsed_name: Optional[String] = None
        var sqrrl__parsed_lead: Optional[Assignment] = None
        var sqrrl__parsed_members: Optional[List[EntityHandle[sqrrl__PersonTableState]]] = None
        var sqrrl__parsed_advisor: Optional[Optional[EntityHandle[sqrrl__EmployeeTableState]]] = None
        sc.expect_byte(UInt8(ord("{")))
        if not sc.try_consume_byte(UInt8(ord("}"))):
            while True:
                var sqrrl__key = sc.parse_json_string()
                sc.expect_byte(UInt8(ord(":")))
                if sqrrl__key == "name":
                    sqrrl__parsed_name = sqrrl__from_json[String](sc)
                elif sqrrl__key == "lead":
                    sqrrl__parsed_lead = sqrrl__Assignment_from_json(sqrrl__tbl_Person, sc)
                elif sqrrl__key == "members":
                    var sqrrl__parsed_members_tmp = List[EntityHandle[sqrrl__PersonTableState]]()
                    sc.expect_byte(UInt8(ord("[")))
                    if not sc.try_consume_byte(UInt8(ord("]"))):
                        while True:
                            sqrrl__parsed_members_tmp.append(sqrrl__tbl_Person.table.handle_for(UInt32(sc.parse_json_int())))
                            if sc.try_consume_byte(UInt8(ord(","))):
                                continue
                            sc.expect_byte(UInt8(ord("]")))
                            break
                    sqrrl__parsed_members = sqrrl__parsed_members_tmp^
                elif sqrrl__key == "advisor":
                    if sc.try_consume_literal("null"):
                        sqrrl__parsed_advisor = Optional[EntityHandle[sqrrl__EmployeeTableState]](None)
                    else:
                        sqrrl__parsed_advisor = Optional[EntityHandle[sqrrl__EmployeeTableState]](sqrrl__tbl_Employee.table.handle_for(UInt32(sc.parse_json_int())))
                if sc.try_consume_byte(UInt8(ord(","))):
                    continue
                sc.expect_byte(UInt8(ord("}")))
                break
        return self.sqrrl__create_with_id(sqrrl__id, sqrrl__parsed_name.take(), sqrrl__parsed_lead.take(), sqrrl__parsed_members.take(), sqrrl__parsed_advisor.take())

    def sqrrl__all_to_json(self) -> String:
        var out = String("[")
        var sqrrl__first = True
        for sqrrl__e in self.all():
            if not sqrrl__first:
                out += ","
            sqrrl__first = False
            out += "[" + String(sqrrl__e.id()) + "," + self.sqrrl__to_json(sqrrl__e) + "]"
        out += "]"
        return out^

    def sqrrl__all_from_json(mut self, mut sqrrl__tbl_Person: sqrrl__PersonTable, mut sqrrl__tbl_Employee: sqrrl__EmployeeTable, mut sqrrl__temp: List[EntityHandle[sqrrl__TeamTableState]], mut sc: sqrrl__JsonScanner) raises:
        sc.expect_byte(UInt8(ord("[")))
        if not sc.try_consume_byte(UInt8(ord("]"))):
            while True:
                sc.expect_byte(UInt8(ord("[")))
                var sqrrl__id = UInt32(sc.parse_json_int())
                sc.expect_byte(UInt8(ord(",")))
                var sqrrl__e = self.sqrrl__from_json_with_id(sqrrl__tbl_Person, sqrrl__tbl_Employee, sqrrl__id, sc)
                sqrrl__temp.append(sqrrl__e^)
                sc.expect_byte(UInt8(ord("]")))
                if sc.try_consume_byte(UInt8(ord(","))):
                    continue
                sc.expect_byte(UInt8(ord("]")))
                break
