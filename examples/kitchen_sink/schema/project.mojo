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
from schema.vendor import sqrrl__VendorTableState
from schema.vendor import sqrrl__VendorTable
from schema.money import Money


struct sqrrl__ProjectTableState(TableStateLike, Movable, ImplicitlyDeletable):
    var name: Rel[String]
    var priority: OrderedRel[UInt32]
    var vendor: Rel[EntityHandle[sqrrl__VendorTableState]]
    var budget: ForwardOnlyRel[Money]

    def __init__(out self):
        self.name = Rel[String]()
        self.priority = OrderedRel[UInt32]()
        self.vendor = Rel[EntityHandle[sqrrl__VendorTableState]]()
        self.budget = ForwardOnlyRel[Money]()

    def sqrrl__cleanup_relations(mut self, id: UInt32):
        _ = self.name.fetch_remove_fwd(id)
        _ = self.priority.fetch_remove_fwd(id)
        _ = self.vendor.fetch_remove_fwd(id)
        _ = self.budget.fetch_remove_fwd(id)


struct sqrrl__ProjectTable(Movable):
    var table: Table[sqrrl__ProjectTableState]

    def __init__(out self):
        self.table = Table[sqrrl__ProjectTableState](sqrrl__ProjectTableState())

    def create(mut self, name: String, priority: UInt32, vendor: EntityHandle[sqrrl__VendorTableState], budget: Money) -> EntityHandle[sqrrl__ProjectTableState]:
        var e = self.table.create()
        self.table.state[].state.name.put(e.id(), name)
        self.table.state[].state.priority.put(e.id(), priority)
        self.table.state[].state.vendor.put(e.id(), vendor)
        self.table.state[].state.budget.put(e.id(), budget)
        return e

    def sqrrl__create_with_id(mut self, sqrrl__id: UInt32, name: String, priority: UInt32, vendor: EntityHandle[sqrrl__VendorTableState], budget: Money) raises -> EntityHandle[sqrrl__ProjectTableState]:
        var e = self.table.create_with_id(sqrrl__id)
        self.table.state[].state.name.put(e.id(), name)
        self.table.state[].state.priority.put(e.id(), priority)
        self.table.state[].state.vendor.put(e.id(), vendor)
        self.table.state[].state.budget.put(e.id(), budget)
        return e

    def all(self) -> Set[EntityHandle[sqrrl__ProjectTableState]]:
        return self.table.all()

    def count(self) -> Int:
        return self.table.count()

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

    def count_name(self, value: String) -> Int:
        return len(self.table.state[].state.name.get_bwd(value))

    def group_by_name(self) -> Dict[String, List[EntityHandle[sqrrl__ProjectTableState]]]:
        ref buckets = self.table.state[].state.name.all_bwd()
        var out = Dict[String, List[EntityHandle[sqrrl__ProjectTableState]]]()
        for entry in buckets.items():
            var handles = List[EntityHandle[sqrrl__ProjectTableState]]()
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

    def get_priority(self, e: EntityHandle[sqrrl__ProjectTableState]) -> UInt32:
        var got = self.table.state[].state.priority.get_fwd(e.id())
        return got.take()

    def set_priority(mut self, e: EntityHandle[sqrrl__ProjectTableState], v: UInt32):
        self.table.state[].state.priority.update(e.id(), v)

    def for_priority(self, value: UInt32) -> Set[EntityHandle[sqrrl__ProjectTableState]]:
        var ids = self.table.state[].state.priority.get_bwd(value)
        var out = Set[EntityHandle[sqrrl__ProjectTableState]]()
        for id in ids:
            out.add(self.table.handle_for(id))
        return out^

    def count_priority(self, value: UInt32) -> Int:
        return len(self.table.state[].state.priority.get_bwd(value))

    def for_priority_greater_than(self, value: UInt32) -> List[EntityHandle[sqrrl__ProjectTableState]]:
        var ids = self.table.state[].state.priority.greater_than(value)
        var out = List[EntityHandle[sqrrl__ProjectTableState]]()
        for id in ids:
            out.append(self.table.handle_for(id))
        return out^

    def for_priority_less_than(self, value: UInt32) -> List[EntityHandle[sqrrl__ProjectTableState]]:
        var ids = self.table.state[].state.priority.less_than(value)
        var out = List[EntityHandle[sqrrl__ProjectTableState]]()
        for id in ids:
            out.append(self.table.handle_for(id))
        return out^

    def for_priority_at_least(self, value: UInt32) -> List[EntityHandle[sqrrl__ProjectTableState]]:
        var ids = self.table.state[].state.priority.at_least(value)
        var out = List[EntityHandle[sqrrl__ProjectTableState]]()
        for id in ids:
            out.append(self.table.handle_for(id))
        return out^

    def for_priority_at_most(self, value: UInt32) -> List[EntityHandle[sqrrl__ProjectTableState]]:
        var ids = self.table.state[].state.priority.at_most(value)
        var out = List[EntityHandle[sqrrl__ProjectTableState]]()
        for id in ids:
            out.append(self.table.handle_for(id))
        return out^

    def for_priority_between(self, low: UInt32, high: UInt32) -> List[EntityHandle[sqrrl__ProjectTableState]]:
        var ids = self.table.state[].state.priority.between(low, high)
        var out = List[EntityHandle[sqrrl__ProjectTableState]]()
        for id in ids:
            out.append(self.table.handle_for(id))
        return out^

    def group_by_priority(self) -> Dict[UInt32, List[EntityHandle[sqrrl__ProjectTableState]]]:
        var buckets = self.table.state[].state.priority.all_bwd()
        var out = Dict[UInt32, List[EntityHandle[sqrrl__ProjectTableState]]]()
        for entry in buckets.items():
            var handles = List[EntityHandle[sqrrl__ProjectTableState]]()
            for id in entry.value:
                handles.append(self.table.handle_for(id))
            out[entry.key] = handles^
        return out^

    def count_by_priority(self) -> Dict[UInt32, Int]:
        var buckets = self.table.state[].state.priority.all_bwd()
        var out = Dict[UInt32, Int]()
        for entry in buckets.items():
            out[entry.key] = len(entry.value)
        return out^

    def distinct_priority(self) -> List[UInt32]:
        var out = List[UInt32]()
        for key in self.table.state[].state.priority.all_bwd().keys():
            out.append(key)
        return out^

    def get_vendor(self, e: EntityHandle[sqrrl__ProjectTableState]) -> EntityHandle[sqrrl__VendorTableState]:
        var got = self.table.state[].state.vendor.get_fwd(e.id())
        return got.take()

    def set_vendor(mut self, e: EntityHandle[sqrrl__ProjectTableState], v: EntityHandle[sqrrl__VendorTableState]):
        self.table.state[].state.vendor.update(e.id(), v)

    def for_vendor(self, value: EntityHandle[sqrrl__VendorTableState]) -> List[EntityHandle[sqrrl__ProjectTableState]]:
        var ids = self.table.state[].state.vendor.get_bwd(value)
        var out = List[EntityHandle[sqrrl__ProjectTableState]]()
        for id in ids:
            out.append(self.table.handle_for(id))
        return out^

    def count_vendor(self, value: EntityHandle[sqrrl__VendorTableState]) -> Int:
        return len(self.table.state[].state.vendor.get_bwd(value))

    def group_by_vendor(self) -> Dict[EntityHandle[sqrrl__VendorTableState], List[EntityHandle[sqrrl__ProjectTableState]]]:
        ref buckets = self.table.state[].state.vendor.all_bwd()
        var out = Dict[EntityHandle[sqrrl__VendorTableState], List[EntityHandle[sqrrl__ProjectTableState]]]()
        for entry in buckets.items():
            var handles = List[EntityHandle[sqrrl__ProjectTableState]]()
            for id in entry.value:
                handles.append(self.table.handle_for(id))
            out[entry.key] = handles^
        return out^

    def count_by_vendor(self) -> Dict[EntityHandle[sqrrl__VendorTableState], Int]:
        ref buckets = self.table.state[].state.vendor.all_bwd()
        var out = Dict[EntityHandle[sqrrl__VendorTableState], Int]()
        for entry in buckets.items():
            out[entry.key] = len(entry.value)
        return out^

    def distinct_vendor(self) -> Set[EntityHandle[sqrrl__VendorTableState]]:
        var out = Set[EntityHandle[sqrrl__VendorTableState]]()
        for key in self.table.state[].state.vendor.all_bwd().keys():
            out.add(key)
        return out^

    def get_budget(self, e: EntityHandle[sqrrl__ProjectTableState]) -> Money:
        var got = self.table.state[].state.budget.get_fwd(e.id())
        return got.take()

    def set_budget(mut self, e: EntityHandle[sqrrl__ProjectTableState], v: Money):
        self.table.state[].state.budget.update(e.id(), v)


    def min_priority(self) raises -> UInt32:
        var sqrrl__ids = List[UInt32]()
        for sqrrl__i in range(self.table.state[].id_count()):
            var sqrrl__id = UInt32(sqrrl__i)
            if self.table.state[].is_live(sqrrl__id):
                sqrrl__ids.append(sqrrl__id)
        if len(sqrrl__ids) == 0:
            raise Error("min_priority: table has no entities")
        var sqrrl__opt = self.table.state[].state.priority.get_fwd(sqrrl__ids[0])
        var sqrrl__result = sqrrl__opt.take()
        for sqrrl__i in range(1, len(sqrrl__ids)):
            var sqrrl__opt2 = self.table.state[].state.priority.get_fwd(sqrrl__ids[sqrrl__i])
            var sqrrl__v = sqrrl__opt2.take()
            if sqrrl__v < sqrrl__result:
                sqrrl__result = sqrrl__v
        return sqrrl__result

    def max_priority(self) raises -> UInt32:
        var sqrrl__ids = List[UInt32]()
        for sqrrl__i in range(self.table.state[].id_count()):
            var sqrrl__id = UInt32(sqrrl__i)
            if self.table.state[].is_live(sqrrl__id):
                sqrrl__ids.append(sqrrl__id)
        if len(sqrrl__ids) == 0:
            raise Error("max_priority: table has no entities")
        var sqrrl__opt = self.table.state[].state.priority.get_fwd(sqrrl__ids[0])
        var sqrrl__result = sqrrl__opt.take()
        for sqrrl__i in range(1, len(sqrrl__ids)):
            var sqrrl__opt2 = self.table.state[].state.priority.get_fwd(sqrrl__ids[sqrrl__i])
            var sqrrl__v = sqrrl__opt2.take()
            if sqrrl__v > sqrrl__result:
                sqrrl__result = sqrrl__v
        return sqrrl__result

    def min_priority_by_name(self) -> Dict[String, UInt32]:
        ref sqrrl__buckets = self.table.state[].state.name.all_bwd()
        var out = Dict[String, UInt32]()
        for entry in sqrrl__buckets.items():
            var sqrrl__ids = List[UInt32]()
            for sqrrl__id in entry.value:
                sqrrl__ids.append(sqrrl__id)
            var sqrrl__opt = self.table.state[].state.priority.get_fwd(sqrrl__ids[0])
            var sqrrl__result = sqrrl__opt.take()
            for sqrrl__i in range(1, len(sqrrl__ids)):
                var sqrrl__opt2 = self.table.state[].state.priority.get_fwd(sqrrl__ids[sqrrl__i])
                var sqrrl__v = sqrrl__opt2.take()
                if sqrrl__v < sqrrl__result:
                    sqrrl__result = sqrrl__v
            out[entry.key] = sqrrl__result
        return out^

    def min_priority_for_name(self, value: String) raises -> UInt32:
        var sqrrl__ids = List[UInt32]()
        for sqrrl__id in self.table.state[].state.name.get_bwd(value):
            sqrrl__ids.append(sqrrl__id)
        if len(sqrrl__ids) == 0:
            raise Error("min_priority_for_name: no entities found for this value")
        var sqrrl__opt = self.table.state[].state.priority.get_fwd(sqrrl__ids[0])
        var sqrrl__result = sqrrl__opt.take()
        for sqrrl__i in range(1, len(sqrrl__ids)):
            var sqrrl__opt2 = self.table.state[].state.priority.get_fwd(sqrrl__ids[sqrrl__i])
            var sqrrl__v = sqrrl__opt2.take()
            if sqrrl__v < sqrrl__result:
                sqrrl__result = sqrrl__v
        return sqrrl__result

    def max_priority_by_name(self) -> Dict[String, UInt32]:
        ref sqrrl__buckets = self.table.state[].state.name.all_bwd()
        var out = Dict[String, UInt32]()
        for entry in sqrrl__buckets.items():
            var sqrrl__ids = List[UInt32]()
            for sqrrl__id in entry.value:
                sqrrl__ids.append(sqrrl__id)
            var sqrrl__opt = self.table.state[].state.priority.get_fwd(sqrrl__ids[0])
            var sqrrl__result = sqrrl__opt.take()
            for sqrrl__i in range(1, len(sqrrl__ids)):
                var sqrrl__opt2 = self.table.state[].state.priority.get_fwd(sqrrl__ids[sqrrl__i])
                var sqrrl__v = sqrrl__opt2.take()
                if sqrrl__v > sqrrl__result:
                    sqrrl__result = sqrrl__v
            out[entry.key] = sqrrl__result
        return out^

    def max_priority_for_name(self, value: String) raises -> UInt32:
        var sqrrl__ids = List[UInt32]()
        for sqrrl__id in self.table.state[].state.name.get_bwd(value):
            sqrrl__ids.append(sqrrl__id)
        if len(sqrrl__ids) == 0:
            raise Error("max_priority_for_name: no entities found for this value")
        var sqrrl__opt = self.table.state[].state.priority.get_fwd(sqrrl__ids[0])
        var sqrrl__result = sqrrl__opt.take()
        for sqrrl__i in range(1, len(sqrrl__ids)):
            var sqrrl__opt2 = self.table.state[].state.priority.get_fwd(sqrrl__ids[sqrrl__i])
            var sqrrl__v = sqrrl__opt2.take()
            if sqrrl__v > sqrrl__result:
                sqrrl__result = sqrrl__v
        return sqrrl__result

    def min_priority_by_vendor(self) -> Dict[EntityHandle[sqrrl__VendorTableState], UInt32]:
        ref sqrrl__buckets = self.table.state[].state.vendor.all_bwd()
        var out = Dict[EntityHandle[sqrrl__VendorTableState], UInt32]()
        for entry in sqrrl__buckets.items():
            var sqrrl__ids = List[UInt32]()
            for sqrrl__id in entry.value:
                sqrrl__ids.append(sqrrl__id)
            var sqrrl__opt = self.table.state[].state.priority.get_fwd(sqrrl__ids[0])
            var sqrrl__result = sqrrl__opt.take()
            for sqrrl__i in range(1, len(sqrrl__ids)):
                var sqrrl__opt2 = self.table.state[].state.priority.get_fwd(sqrrl__ids[sqrrl__i])
                var sqrrl__v = sqrrl__opt2.take()
                if sqrrl__v < sqrrl__result:
                    sqrrl__result = sqrrl__v
            out[entry.key] = sqrrl__result
        return out^

    def min_priority_for_vendor(self, value: EntityHandle[sqrrl__VendorTableState]) raises -> UInt32:
        var sqrrl__ids = List[UInt32]()
        for sqrrl__id in self.table.state[].state.vendor.get_bwd(value):
            sqrrl__ids.append(sqrrl__id)
        if len(sqrrl__ids) == 0:
            raise Error("min_priority_for_vendor: no entities found for this value")
        var sqrrl__opt = self.table.state[].state.priority.get_fwd(sqrrl__ids[0])
        var sqrrl__result = sqrrl__opt.take()
        for sqrrl__i in range(1, len(sqrrl__ids)):
            var sqrrl__opt2 = self.table.state[].state.priority.get_fwd(sqrrl__ids[sqrrl__i])
            var sqrrl__v = sqrrl__opt2.take()
            if sqrrl__v < sqrrl__result:
                sqrrl__result = sqrrl__v
        return sqrrl__result

    def max_priority_by_vendor(self) -> Dict[EntityHandle[sqrrl__VendorTableState], UInt32]:
        ref sqrrl__buckets = self.table.state[].state.vendor.all_bwd()
        var out = Dict[EntityHandle[sqrrl__VendorTableState], UInt32]()
        for entry in sqrrl__buckets.items():
            var sqrrl__ids = List[UInt32]()
            for sqrrl__id in entry.value:
                sqrrl__ids.append(sqrrl__id)
            var sqrrl__opt = self.table.state[].state.priority.get_fwd(sqrrl__ids[0])
            var sqrrl__result = sqrrl__opt.take()
            for sqrrl__i in range(1, len(sqrrl__ids)):
                var sqrrl__opt2 = self.table.state[].state.priority.get_fwd(sqrrl__ids[sqrrl__i])
                var sqrrl__v = sqrrl__opt2.take()
                if sqrrl__v > sqrrl__result:
                    sqrrl__result = sqrrl__v
            out[entry.key] = sqrrl__result
        return out^

    def max_priority_for_vendor(self, value: EntityHandle[sqrrl__VendorTableState]) raises -> UInt32:
        var sqrrl__ids = List[UInt32]()
        for sqrrl__id in self.table.state[].state.vendor.get_bwd(value):
            sqrrl__ids.append(sqrrl__id)
        if len(sqrrl__ids) == 0:
            raise Error("max_priority_for_vendor: no entities found for this value")
        var sqrrl__opt = self.table.state[].state.priority.get_fwd(sqrrl__ids[0])
        var sqrrl__result = sqrrl__opt.take()
        for sqrrl__i in range(1, len(sqrrl__ids)):
            var sqrrl__opt2 = self.table.state[].state.priority.get_fwd(sqrrl__ids[sqrrl__i])
            var sqrrl__v = sqrrl__opt2.take()
            if sqrrl__v > sqrrl__result:
                sqrrl__result = sqrrl__v
        return sqrrl__result

    def sqrrl__to_json(self, e: EntityHandle[sqrrl__ProjectTableState]) -> String:
        var out = String("{")
        out += "\"name\":" + sqrrl__to_json(self.get_name(e))
        out += ","
        out += "\"priority\":" + sqrrl__to_json(self.get_priority(e))
        out += ","
        out += "\"vendor\":" + sqrrl__to_json(self.get_vendor(e))
        out += ","
        out += "\"budget\":" + sqrrl__to_json(self.get_budget(e))
        out += "}"
        return out^

    def sqrrl__from_json(mut self, mut sqrrl__tbl_Vendor: sqrrl__VendorTable, mut sc: sqrrl__JsonScanner) raises -> EntityHandle[sqrrl__ProjectTableState]:
        var sqrrl__parsed_name: Optional[String] = None
        var sqrrl__parsed_priority: Optional[UInt32] = None
        var sqrrl__parsed_vendor: Optional[EntityHandle[sqrrl__VendorTableState]] = None
        var sqrrl__parsed_budget: Optional[Money] = None
        sc.expect_byte(UInt8(ord("{")))
        if not sc.try_consume_byte(UInt8(ord("}"))):
            while True:
                var sqrrl__key = sc.parse_json_string()
                sc.expect_byte(UInt8(ord(":")))
                if sqrrl__key == "name":
                    sqrrl__parsed_name = sqrrl__from_json[String](sc)
                elif sqrrl__key == "priority":
                    sqrrl__parsed_priority = sqrrl__from_json[UInt32](sc)
                elif sqrrl__key == "vendor":
                    sqrrl__parsed_vendor = sqrrl__tbl_Vendor.table.handle_for(UInt32(sc.parse_json_int()))
                elif sqrrl__key == "budget":
                    sqrrl__parsed_budget = sqrrl__Money_from_json(sc)
                if sc.try_consume_byte(UInt8(ord(","))):
                    continue
                sc.expect_byte(UInt8(ord("}")))
                break
        return self.create(sqrrl__parsed_name.take(), sqrrl__parsed_priority.take(), sqrrl__parsed_vendor.take(), sqrrl__parsed_budget.take())

    def sqrrl__from_json_with_id(mut self, mut sqrrl__tbl_Vendor: sqrrl__VendorTable, sqrrl__id: UInt32, mut sc: sqrrl__JsonScanner) raises -> EntityHandle[sqrrl__ProjectTableState]:
        var sqrrl__parsed_name: Optional[String] = None
        var sqrrl__parsed_priority: Optional[UInt32] = None
        var sqrrl__parsed_vendor: Optional[EntityHandle[sqrrl__VendorTableState]] = None
        var sqrrl__parsed_budget: Optional[Money] = None
        sc.expect_byte(UInt8(ord("{")))
        if not sc.try_consume_byte(UInt8(ord("}"))):
            while True:
                var sqrrl__key = sc.parse_json_string()
                sc.expect_byte(UInt8(ord(":")))
                if sqrrl__key == "name":
                    sqrrl__parsed_name = sqrrl__from_json[String](sc)
                elif sqrrl__key == "priority":
                    sqrrl__parsed_priority = sqrrl__from_json[UInt32](sc)
                elif sqrrl__key == "vendor":
                    sqrrl__parsed_vendor = sqrrl__tbl_Vendor.table.handle_for(UInt32(sc.parse_json_int()))
                elif sqrrl__key == "budget":
                    sqrrl__parsed_budget = sqrrl__Money_from_json(sc)
                if sc.try_consume_byte(UInt8(ord(","))):
                    continue
                sc.expect_byte(UInt8(ord("}")))
                break
        return self.sqrrl__create_with_id(sqrrl__id, sqrrl__parsed_name.take(), sqrrl__parsed_priority.take(), sqrrl__parsed_vendor.take(), sqrrl__parsed_budget.take())

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

    def sqrrl__all_from_json(mut self, mut sqrrl__tbl_Vendor: sqrrl__VendorTable, mut sqrrl__temp: List[EntityHandle[sqrrl__ProjectTableState]], mut sc: sqrrl__JsonScanner) raises:
        sc.expect_byte(UInt8(ord("[")))
        if not sc.try_consume_byte(UInt8(ord("]"))):
            while True:
                sc.expect_byte(UInt8(ord("[")))
                var sqrrl__id = UInt32(sc.parse_json_int())
                sc.expect_byte(UInt8(ord(",")))
                var sqrrl__e = self.sqrrl__from_json_with_id(sqrrl__tbl_Vendor, sqrrl__id, sc)
                sqrrl__temp.append(sqrrl__e^)
                sc.expect_byte(UInt8(ord("]")))
                if sc.try_consume_byte(UInt8(ord(","))):
                    continue
                sc.expect_byte(UInt8(ord("]")))
                break

