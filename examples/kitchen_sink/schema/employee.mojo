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
from schema.department import sqrrl__DepartmentTableState
from schema.department import sqrrl__DepartmentTable
from schema.profile import Profile


struct sqrrl__EmployeeTableState(TableStateLike, Movable, ImplicitlyDeletable):
    var email: UniqueRel[String]
    var title: Rel[String]
    var years_employed: OrderedRel[UInt32]
    var salary: Rel[Float64]
    var dept: Rel[EntityHandle[sqrrl__DepartmentTableState]]
    var profile: ForwardOnlyRel[Profile]

    def __init__(out self):
        self.email = UniqueRel[String]()
        self.title = Rel[String]()
        self.years_employed = OrderedRel[UInt32]()
        self.salary = Rel[Float64]()
        self.dept = Rel[EntityHandle[sqrrl__DepartmentTableState]]()
        self.profile = ForwardOnlyRel[Profile]()

    def sqrrl__cleanup_relations(mut self, id: UInt32):
        _ = self.email.fetch_remove_fwd(id)
        _ = self.title.fetch_remove_fwd(id)
        _ = self.years_employed.fetch_remove_fwd(id)
        _ = self.salary.fetch_remove_fwd(id)
        _ = self.dept.fetch_remove_fwd(id)
        _ = self.profile.fetch_remove_fwd(id)


struct sqrrl__EmployeeTable(Movable):
    var table: Table[sqrrl__EmployeeTableState]

    def __init__(out self):
        self.table = Table[sqrrl__EmployeeTableState](sqrrl__EmployeeTableState())

    def create(mut self, email: String, title: String, years_employed: UInt32, salary: Float64, dept: EntityHandle[sqrrl__DepartmentTableState], profile: Profile) raises -> EntityHandle[sqrrl__EmployeeTableState]:
        var e = self.table.create()
        self.table.state[].state.email.put(e.id(), email)
        self.table.state[].state.title.put(e.id(), title)
        self.table.state[].state.years_employed.put(e.id(), years_employed)
        self.table.state[].state.salary.put(e.id(), salary)
        self.table.state[].state.dept.put(e.id(), dept)
        self.table.state[].state.profile.put(e.id(), profile)
        return e

    def sqrrl__create_with_id(mut self, sqrrl__id: UInt32, email: String, title: String, years_employed: UInt32, salary: Float64, dept: EntityHandle[sqrrl__DepartmentTableState], profile: Profile) raises -> EntityHandle[sqrrl__EmployeeTableState]:
        var e = self.table.create_with_id(sqrrl__id)
        self.table.state[].state.email.put(e.id(), email)
        self.table.state[].state.title.put(e.id(), title)
        self.table.state[].state.years_employed.put(e.id(), years_employed)
        self.table.state[].state.salary.put(e.id(), salary)
        self.table.state[].state.dept.put(e.id(), dept)
        self.table.state[].state.profile.put(e.id(), profile)
        return e

    def all(self) -> Set[EntityHandle[sqrrl__EmployeeTableState]]:
        return self.table.all()

    def count(self) -> Int:
        return self.table.count()

    def value_eq(self, a: EntityHandle[sqrrl__EmployeeTableState], b: EntityHandle[sqrrl__EmployeeTableState]) -> Bool:
        if self.get_email(a) != self.get_email(b):
            return False
        if self.get_title(a) != self.get_title(b):
            return False
        if self.get_years_employed(a) != self.get_years_employed(b):
            return False
        if self.get_salary(a) != self.get_salary(b):
            return False
        if self.get_dept(a) != self.get_dept(b):
            return False
        if self.get_profile(a) != self.get_profile(b):
            return False
        return True

    def get_email(self, e: EntityHandle[sqrrl__EmployeeTableState]) -> String:
        var got = self.table.state[].state.email.get_fwd(e.id())
        return got.take()

    def set_email(mut self, e: EntityHandle[sqrrl__EmployeeTableState], v: String) raises:
        self.table.state[].state.email.update(e.id(), v)

    def for_email(self, value: String) raises -> EntityHandle[sqrrl__EmployeeTableState]:
        var id = self.table.state[].state.email.get_bwd(value)
        return self.table.handle_for(id)

    def count_email(self, value: String) -> Int:
        return 1 if value in self.table.state[].state.email.all_bwd() else 0

    def group_by_email(self) -> Dict[String, EntityHandle[sqrrl__EmployeeTableState]]:
        ref ids = self.table.state[].state.email.all_bwd()
        var out = Dict[String, EntityHandle[sqrrl__EmployeeTableState]]()
        for entry in ids.items():
            out[entry.key] = self.table.handle_for(entry.value)
        return out^

    def distinct_email(self) -> Set[String]:
        var out = Set[String]()
        for key in self.table.state[].state.email.all_bwd().keys():
            out.add(key)
        return out^

    def get_title(self, e: EntityHandle[sqrrl__EmployeeTableState]) -> String:
        var got = self.table.state[].state.title.get_fwd(e.id())
        return got.take()

    def set_title(mut self, e: EntityHandle[sqrrl__EmployeeTableState], v: String):
        self.table.state[].state.title.update(e.id(), v)

    def for_title(self, value: String) -> List[EntityHandle[sqrrl__EmployeeTableState]]:
        var ids = self.table.state[].state.title.get_bwd(value)
        var out = List[EntityHandle[sqrrl__EmployeeTableState]]()
        for id in ids:
            out.append(self.table.handle_for(id))
        return out^

    def count_title(self, value: String) -> Int:
        return len(self.table.state[].state.title.get_bwd(value))

    def group_by_title(self) -> Dict[String, List[EntityHandle[sqrrl__EmployeeTableState]]]:
        ref buckets = self.table.state[].state.title.all_bwd()
        var out = Dict[String, List[EntityHandle[sqrrl__EmployeeTableState]]]()
        for entry in buckets.items():
            var handles = List[EntityHandle[sqrrl__EmployeeTableState]]()
            for id in entry.value:
                handles.append(self.table.handle_for(id))
            out[entry.key] = handles^
        return out^

    def count_by_title(self) -> Dict[String, Int]:
        ref buckets = self.table.state[].state.title.all_bwd()
        var out = Dict[String, Int]()
        for entry in buckets.items():
            out[entry.key] = len(entry.value)
        return out^

    def distinct_title(self) -> Set[String]:
        var out = Set[String]()
        for key in self.table.state[].state.title.all_bwd().keys():
            out.add(key)
        return out^

    def get_years_employed(self, e: EntityHandle[sqrrl__EmployeeTableState]) -> UInt32:
        var got = self.table.state[].state.years_employed.get_fwd(e.id())
        return got.take()

    def set_years_employed(mut self, e: EntityHandle[sqrrl__EmployeeTableState], v: UInt32):
        self.table.state[].state.years_employed.update(e.id(), v)

    def for_years_employed(self, value: UInt32) -> Set[EntityHandle[sqrrl__EmployeeTableState]]:
        var ids = self.table.state[].state.years_employed.get_bwd(value)
        var out = Set[EntityHandle[sqrrl__EmployeeTableState]]()
        for id in ids:
            out.add(self.table.handle_for(id))
        return out^

    def count_years_employed(self, value: UInt32) -> Int:
        return len(self.table.state[].state.years_employed.get_bwd(value))

    def for_years_employed_greater_than(self, value: UInt32) -> List[EntityHandle[sqrrl__EmployeeTableState]]:
        var ids = self.table.state[].state.years_employed.greater_than(value)
        var out = List[EntityHandle[sqrrl__EmployeeTableState]]()
        for id in ids:
            out.append(self.table.handle_for(id))
        return out^

    def for_years_employed_less_than(self, value: UInt32) -> List[EntityHandle[sqrrl__EmployeeTableState]]:
        var ids = self.table.state[].state.years_employed.less_than(value)
        var out = List[EntityHandle[sqrrl__EmployeeTableState]]()
        for id in ids:
            out.append(self.table.handle_for(id))
        return out^

    def for_years_employed_at_least(self, value: UInt32) -> List[EntityHandle[sqrrl__EmployeeTableState]]:
        var ids = self.table.state[].state.years_employed.at_least(value)
        var out = List[EntityHandle[sqrrl__EmployeeTableState]]()
        for id in ids:
            out.append(self.table.handle_for(id))
        return out^

    def for_years_employed_at_most(self, value: UInt32) -> List[EntityHandle[sqrrl__EmployeeTableState]]:
        var ids = self.table.state[].state.years_employed.at_most(value)
        var out = List[EntityHandle[sqrrl__EmployeeTableState]]()
        for id in ids:
            out.append(self.table.handle_for(id))
        return out^

    def for_years_employed_between(self, low: UInt32, high: UInt32) -> List[EntityHandle[sqrrl__EmployeeTableState]]:
        var ids = self.table.state[].state.years_employed.between(low, high)
        var out = List[EntityHandle[sqrrl__EmployeeTableState]]()
        for id in ids:
            out.append(self.table.handle_for(id))
        return out^

    def group_by_years_employed(self) -> Dict[UInt32, List[EntityHandle[sqrrl__EmployeeTableState]]]:
        var buckets = self.table.state[].state.years_employed.all_bwd()
        var out = Dict[UInt32, List[EntityHandle[sqrrl__EmployeeTableState]]]()
        for entry in buckets.items():
            var handles = List[EntityHandle[sqrrl__EmployeeTableState]]()
            for id in entry.value:
                handles.append(self.table.handle_for(id))
            out[entry.key] = handles^
        return out^

    def count_by_years_employed(self) -> Dict[UInt32, Int]:
        var buckets = self.table.state[].state.years_employed.all_bwd()
        var out = Dict[UInt32, Int]()
        for entry in buckets.items():
            out[entry.key] = len(entry.value)
        return out^

    def distinct_years_employed(self) -> List[UInt32]:
        var out = List[UInt32]()
        for key in self.table.state[].state.years_employed.all_bwd().keys():
            out.append(key)
        return out^

    def get_salary(self, e: EntityHandle[sqrrl__EmployeeTableState]) -> Float64:
        var got = self.table.state[].state.salary.get_fwd(e.id())
        return got.take()

    def set_salary(mut self, e: EntityHandle[sqrrl__EmployeeTableState], v: Float64):
        self.table.state[].state.salary.update(e.id(), v)

    def for_salary(self, value: Float64) -> List[EntityHandle[sqrrl__EmployeeTableState]]:
        var ids = self.table.state[].state.salary.get_bwd(value)
        var out = List[EntityHandle[sqrrl__EmployeeTableState]]()
        for id in ids:
            out.append(self.table.handle_for(id))
        return out^

    def count_salary(self, value: Float64) -> Int:
        return len(self.table.state[].state.salary.get_bwd(value))

    def group_by_salary(self) -> Dict[Float64, List[EntityHandle[sqrrl__EmployeeTableState]]]:
        ref buckets = self.table.state[].state.salary.all_bwd()
        var out = Dict[Float64, List[EntityHandle[sqrrl__EmployeeTableState]]]()
        for entry in buckets.items():
            var handles = List[EntityHandle[sqrrl__EmployeeTableState]]()
            for id in entry.value:
                handles.append(self.table.handle_for(id))
            out[entry.key] = handles^
        return out^

    def count_by_salary(self) -> Dict[Float64, Int]:
        ref buckets = self.table.state[].state.salary.all_bwd()
        var out = Dict[Float64, Int]()
        for entry in buckets.items():
            out[entry.key] = len(entry.value)
        return out^

    def distinct_salary(self) -> Set[Float64]:
        var out = Set[Float64]()
        for key in self.table.state[].state.salary.all_bwd().keys():
            out.add(key)
        return out^

    def get_dept(self, e: EntityHandle[sqrrl__EmployeeTableState]) -> EntityHandle[sqrrl__DepartmentTableState]:
        var got = self.table.state[].state.dept.get_fwd(e.id())
        return got.take()

    def set_dept(mut self, e: EntityHandle[sqrrl__EmployeeTableState], v: EntityHandle[sqrrl__DepartmentTableState]):
        self.table.state[].state.dept.update(e.id(), v)

    def for_dept(self, value: EntityHandle[sqrrl__DepartmentTableState]) -> List[EntityHandle[sqrrl__EmployeeTableState]]:
        var ids = self.table.state[].state.dept.get_bwd(value)
        var out = List[EntityHandle[sqrrl__EmployeeTableState]]()
        for id in ids:
            out.append(self.table.handle_for(id))
        return out^

    def count_dept(self, value: EntityHandle[sqrrl__DepartmentTableState]) -> Int:
        return len(self.table.state[].state.dept.get_bwd(value))

    def group_by_dept(self) -> Dict[EntityHandle[sqrrl__DepartmentTableState], List[EntityHandle[sqrrl__EmployeeTableState]]]:
        ref buckets = self.table.state[].state.dept.all_bwd()
        var out = Dict[EntityHandle[sqrrl__DepartmentTableState], List[EntityHandle[sqrrl__EmployeeTableState]]]()
        for entry in buckets.items():
            var handles = List[EntityHandle[sqrrl__EmployeeTableState]]()
            for id in entry.value:
                handles.append(self.table.handle_for(id))
            out[entry.key] = handles^
        return out^

    def count_by_dept(self) -> Dict[EntityHandle[sqrrl__DepartmentTableState], Int]:
        ref buckets = self.table.state[].state.dept.all_bwd()
        var out = Dict[EntityHandle[sqrrl__DepartmentTableState], Int]()
        for entry in buckets.items():
            out[entry.key] = len(entry.value)
        return out^

    def distinct_dept(self) -> Set[EntityHandle[sqrrl__DepartmentTableState]]:
        var out = Set[EntityHandle[sqrrl__DepartmentTableState]]()
        for key in self.table.state[].state.dept.all_bwd().keys():
            out.add(key)
        return out^

    def get_profile(self, e: EntityHandle[sqrrl__EmployeeTableState]) -> Profile:
        var got = self.table.state[].state.profile.get_fwd(e.id())
        return got.take()

    def set_profile(mut self, e: EntityHandle[sqrrl__EmployeeTableState], v: Profile):
        self.table.state[].state.profile.update(e.id(), v)


    def min_years_employed(self) raises -> UInt32:
        var sqrrl__ids = List[UInt32]()
        for sqrrl__i in range(self.table.state[].id_count()):
            var sqrrl__id = UInt32(sqrrl__i)
            if self.table.state[].is_live(sqrrl__id):
                sqrrl__ids.append(sqrrl__id)
        if len(sqrrl__ids) == 0:
            raise Error("min_years_employed: table has no entities")
        var sqrrl__opt = self.table.state[].state.years_employed.get_fwd(sqrrl__ids[0])
        var sqrrl__result = sqrrl__opt.take()
        for sqrrl__i in range(1, len(sqrrl__ids)):
            var sqrrl__opt2 = self.table.state[].state.years_employed.get_fwd(sqrrl__ids[sqrrl__i])
            var sqrrl__v = sqrrl__opt2.take()
            if sqrrl__v < sqrrl__result:
                sqrrl__result = sqrrl__v
        return sqrrl__result

    def max_years_employed(self) raises -> UInt32:
        var sqrrl__ids = List[UInt32]()
        for sqrrl__i in range(self.table.state[].id_count()):
            var sqrrl__id = UInt32(sqrrl__i)
            if self.table.state[].is_live(sqrrl__id):
                sqrrl__ids.append(sqrrl__id)
        if len(sqrrl__ids) == 0:
            raise Error("max_years_employed: table has no entities")
        var sqrrl__opt = self.table.state[].state.years_employed.get_fwd(sqrrl__ids[0])
        var sqrrl__result = sqrrl__opt.take()
        for sqrrl__i in range(1, len(sqrrl__ids)):
            var sqrrl__opt2 = self.table.state[].state.years_employed.get_fwd(sqrrl__ids[sqrrl__i])
            var sqrrl__v = sqrrl__opt2.take()
            if sqrrl__v > sqrrl__result:
                sqrrl__result = sqrrl__v
        return sqrrl__result

    def min_years_employed_by_email(self) -> Dict[String, UInt32]:
        ref sqrrl__ids = self.table.state[].state.email.all_bwd()
        var out = Dict[String, UInt32]()
        for entry in sqrrl__ids.items():
            var sqrrl__opt = self.table.state[].state.years_employed.get_fwd(entry.value)
            out[entry.key] = sqrrl__opt.take()
        return out^

    def min_years_employed_for_email(self, value: String) raises -> UInt32:
        var sqrrl__id = self.table.state[].state.email.get_bwd(value)
        var sqrrl__opt = self.table.state[].state.years_employed.get_fwd(sqrrl__id)
        return sqrrl__opt.take()

    def max_years_employed_by_email(self) -> Dict[String, UInt32]:
        ref sqrrl__ids = self.table.state[].state.email.all_bwd()
        var out = Dict[String, UInt32]()
        for entry in sqrrl__ids.items():
            var sqrrl__opt = self.table.state[].state.years_employed.get_fwd(entry.value)
            out[entry.key] = sqrrl__opt.take()
        return out^

    def max_years_employed_for_email(self, value: String) raises -> UInt32:
        var sqrrl__id = self.table.state[].state.email.get_bwd(value)
        var sqrrl__opt = self.table.state[].state.years_employed.get_fwd(sqrrl__id)
        return sqrrl__opt.take()

    def min_years_employed_by_title(self) -> Dict[String, UInt32]:
        ref sqrrl__buckets = self.table.state[].state.title.all_bwd()
        var out = Dict[String, UInt32]()
        for entry in sqrrl__buckets.items():
            var sqrrl__ids = List[UInt32]()
            for sqrrl__id in entry.value:
                sqrrl__ids.append(sqrrl__id)
            var sqrrl__opt = self.table.state[].state.years_employed.get_fwd(sqrrl__ids[0])
            var sqrrl__result = sqrrl__opt.take()
            for sqrrl__i in range(1, len(sqrrl__ids)):
                var sqrrl__opt2 = self.table.state[].state.years_employed.get_fwd(sqrrl__ids[sqrrl__i])
                var sqrrl__v = sqrrl__opt2.take()
                if sqrrl__v < sqrrl__result:
                    sqrrl__result = sqrrl__v
            out[entry.key] = sqrrl__result
        return out^

    def min_years_employed_for_title(self, value: String) raises -> UInt32:
        var sqrrl__ids = List[UInt32]()
        for sqrrl__id in self.table.state[].state.title.get_bwd(value):
            sqrrl__ids.append(sqrrl__id)
        if len(sqrrl__ids) == 0:
            raise Error("min_years_employed_for_title: no entities found for this value")
        var sqrrl__opt = self.table.state[].state.years_employed.get_fwd(sqrrl__ids[0])
        var sqrrl__result = sqrrl__opt.take()
        for sqrrl__i in range(1, len(sqrrl__ids)):
            var sqrrl__opt2 = self.table.state[].state.years_employed.get_fwd(sqrrl__ids[sqrrl__i])
            var sqrrl__v = sqrrl__opt2.take()
            if sqrrl__v < sqrrl__result:
                sqrrl__result = sqrrl__v
        return sqrrl__result

    def max_years_employed_by_title(self) -> Dict[String, UInt32]:
        ref sqrrl__buckets = self.table.state[].state.title.all_bwd()
        var out = Dict[String, UInt32]()
        for entry in sqrrl__buckets.items():
            var sqrrl__ids = List[UInt32]()
            for sqrrl__id in entry.value:
                sqrrl__ids.append(sqrrl__id)
            var sqrrl__opt = self.table.state[].state.years_employed.get_fwd(sqrrl__ids[0])
            var sqrrl__result = sqrrl__opt.take()
            for sqrrl__i in range(1, len(sqrrl__ids)):
                var sqrrl__opt2 = self.table.state[].state.years_employed.get_fwd(sqrrl__ids[sqrrl__i])
                var sqrrl__v = sqrrl__opt2.take()
                if sqrrl__v > sqrrl__result:
                    sqrrl__result = sqrrl__v
            out[entry.key] = sqrrl__result
        return out^

    def max_years_employed_for_title(self, value: String) raises -> UInt32:
        var sqrrl__ids = List[UInt32]()
        for sqrrl__id in self.table.state[].state.title.get_bwd(value):
            sqrrl__ids.append(sqrrl__id)
        if len(sqrrl__ids) == 0:
            raise Error("max_years_employed_for_title: no entities found for this value")
        var sqrrl__opt = self.table.state[].state.years_employed.get_fwd(sqrrl__ids[0])
        var sqrrl__result = sqrrl__opt.take()
        for sqrrl__i in range(1, len(sqrrl__ids)):
            var sqrrl__opt2 = self.table.state[].state.years_employed.get_fwd(sqrrl__ids[sqrrl__i])
            var sqrrl__v = sqrrl__opt2.take()
            if sqrrl__v > sqrrl__result:
                sqrrl__result = sqrrl__v
        return sqrrl__result

    def min_years_employed_by_salary(self) -> Dict[Float64, UInt32]:
        ref sqrrl__buckets = self.table.state[].state.salary.all_bwd()
        var out = Dict[Float64, UInt32]()
        for entry in sqrrl__buckets.items():
            var sqrrl__ids = List[UInt32]()
            for sqrrl__id in entry.value:
                sqrrl__ids.append(sqrrl__id)
            var sqrrl__opt = self.table.state[].state.years_employed.get_fwd(sqrrl__ids[0])
            var sqrrl__result = sqrrl__opt.take()
            for sqrrl__i in range(1, len(sqrrl__ids)):
                var sqrrl__opt2 = self.table.state[].state.years_employed.get_fwd(sqrrl__ids[sqrrl__i])
                var sqrrl__v = sqrrl__opt2.take()
                if sqrrl__v < sqrrl__result:
                    sqrrl__result = sqrrl__v
            out[entry.key] = sqrrl__result
        return out^

    def min_years_employed_for_salary(self, value: Float64) raises -> UInt32:
        var sqrrl__ids = List[UInt32]()
        for sqrrl__id in self.table.state[].state.salary.get_bwd(value):
            sqrrl__ids.append(sqrrl__id)
        if len(sqrrl__ids) == 0:
            raise Error("min_years_employed_for_salary: no entities found for this value")
        var sqrrl__opt = self.table.state[].state.years_employed.get_fwd(sqrrl__ids[0])
        var sqrrl__result = sqrrl__opt.take()
        for sqrrl__i in range(1, len(sqrrl__ids)):
            var sqrrl__opt2 = self.table.state[].state.years_employed.get_fwd(sqrrl__ids[sqrrl__i])
            var sqrrl__v = sqrrl__opt2.take()
            if sqrrl__v < sqrrl__result:
                sqrrl__result = sqrrl__v
        return sqrrl__result

    def max_years_employed_by_salary(self) -> Dict[Float64, UInt32]:
        ref sqrrl__buckets = self.table.state[].state.salary.all_bwd()
        var out = Dict[Float64, UInt32]()
        for entry in sqrrl__buckets.items():
            var sqrrl__ids = List[UInt32]()
            for sqrrl__id in entry.value:
                sqrrl__ids.append(sqrrl__id)
            var sqrrl__opt = self.table.state[].state.years_employed.get_fwd(sqrrl__ids[0])
            var sqrrl__result = sqrrl__opt.take()
            for sqrrl__i in range(1, len(sqrrl__ids)):
                var sqrrl__opt2 = self.table.state[].state.years_employed.get_fwd(sqrrl__ids[sqrrl__i])
                var sqrrl__v = sqrrl__opt2.take()
                if sqrrl__v > sqrrl__result:
                    sqrrl__result = sqrrl__v
            out[entry.key] = sqrrl__result
        return out^

    def max_years_employed_for_salary(self, value: Float64) raises -> UInt32:
        var sqrrl__ids = List[UInt32]()
        for sqrrl__id in self.table.state[].state.salary.get_bwd(value):
            sqrrl__ids.append(sqrrl__id)
        if len(sqrrl__ids) == 0:
            raise Error("max_years_employed_for_salary: no entities found for this value")
        var sqrrl__opt = self.table.state[].state.years_employed.get_fwd(sqrrl__ids[0])
        var sqrrl__result = sqrrl__opt.take()
        for sqrrl__i in range(1, len(sqrrl__ids)):
            var sqrrl__opt2 = self.table.state[].state.years_employed.get_fwd(sqrrl__ids[sqrrl__i])
            var sqrrl__v = sqrrl__opt2.take()
            if sqrrl__v > sqrrl__result:
                sqrrl__result = sqrrl__v
        return sqrrl__result

    def min_years_employed_by_dept(self) -> Dict[EntityHandle[sqrrl__DepartmentTableState], UInt32]:
        ref sqrrl__buckets = self.table.state[].state.dept.all_bwd()
        var out = Dict[EntityHandle[sqrrl__DepartmentTableState], UInt32]()
        for entry in sqrrl__buckets.items():
            var sqrrl__ids = List[UInt32]()
            for sqrrl__id in entry.value:
                sqrrl__ids.append(sqrrl__id)
            var sqrrl__opt = self.table.state[].state.years_employed.get_fwd(sqrrl__ids[0])
            var sqrrl__result = sqrrl__opt.take()
            for sqrrl__i in range(1, len(sqrrl__ids)):
                var sqrrl__opt2 = self.table.state[].state.years_employed.get_fwd(sqrrl__ids[sqrrl__i])
                var sqrrl__v = sqrrl__opt2.take()
                if sqrrl__v < sqrrl__result:
                    sqrrl__result = sqrrl__v
            out[entry.key] = sqrrl__result
        return out^

    def min_years_employed_for_dept(self, value: EntityHandle[sqrrl__DepartmentTableState]) raises -> UInt32:
        var sqrrl__ids = List[UInt32]()
        for sqrrl__id in self.table.state[].state.dept.get_bwd(value):
            sqrrl__ids.append(sqrrl__id)
        if len(sqrrl__ids) == 0:
            raise Error("min_years_employed_for_dept: no entities found for this value")
        var sqrrl__opt = self.table.state[].state.years_employed.get_fwd(sqrrl__ids[0])
        var sqrrl__result = sqrrl__opt.take()
        for sqrrl__i in range(1, len(sqrrl__ids)):
            var sqrrl__opt2 = self.table.state[].state.years_employed.get_fwd(sqrrl__ids[sqrrl__i])
            var sqrrl__v = sqrrl__opt2.take()
            if sqrrl__v < sqrrl__result:
                sqrrl__result = sqrrl__v
        return sqrrl__result

    def max_years_employed_by_dept(self) -> Dict[EntityHandle[sqrrl__DepartmentTableState], UInt32]:
        ref sqrrl__buckets = self.table.state[].state.dept.all_bwd()
        var out = Dict[EntityHandle[sqrrl__DepartmentTableState], UInt32]()
        for entry in sqrrl__buckets.items():
            var sqrrl__ids = List[UInt32]()
            for sqrrl__id in entry.value:
                sqrrl__ids.append(sqrrl__id)
            var sqrrl__opt = self.table.state[].state.years_employed.get_fwd(sqrrl__ids[0])
            var sqrrl__result = sqrrl__opt.take()
            for sqrrl__i in range(1, len(sqrrl__ids)):
                var sqrrl__opt2 = self.table.state[].state.years_employed.get_fwd(sqrrl__ids[sqrrl__i])
                var sqrrl__v = sqrrl__opt2.take()
                if sqrrl__v > sqrrl__result:
                    sqrrl__result = sqrrl__v
            out[entry.key] = sqrrl__result
        return out^

    def max_years_employed_for_dept(self, value: EntityHandle[sqrrl__DepartmentTableState]) raises -> UInt32:
        var sqrrl__ids = List[UInt32]()
        for sqrrl__id in self.table.state[].state.dept.get_bwd(value):
            sqrrl__ids.append(sqrrl__id)
        if len(sqrrl__ids) == 0:
            raise Error("max_years_employed_for_dept: no entities found for this value")
        var sqrrl__opt = self.table.state[].state.years_employed.get_fwd(sqrrl__ids[0])
        var sqrrl__result = sqrrl__opt.take()
        for sqrrl__i in range(1, len(sqrrl__ids)):
            var sqrrl__opt2 = self.table.state[].state.years_employed.get_fwd(sqrrl__ids[sqrrl__i])
            var sqrrl__v = sqrrl__opt2.take()
            if sqrrl__v > sqrrl__result:
                sqrrl__result = sqrrl__v
        return sqrrl__result

    def sum_salary(self) raises -> Float64:
        var sqrrl__ids = List[UInt32]()
        for sqrrl__i in range(self.table.state[].id_count()):
            var sqrrl__id = UInt32(sqrrl__i)
            if self.table.state[].is_live(sqrrl__id):
                sqrrl__ids.append(sqrrl__id)
        if len(sqrrl__ids) == 0:
            raise Error("sum_salary: table has no entities")
        var sqrrl__opt = self.table.state[].state.salary.get_fwd(sqrrl__ids[0])
        var sqrrl__result = sqrrl__opt.take()
        for sqrrl__i in range(1, len(sqrrl__ids)):
            var sqrrl__opt2 = self.table.state[].state.salary.get_fwd(sqrrl__ids[sqrrl__i])
            sqrrl__result = sqrrl__result + sqrrl__opt2.take()
        return sqrrl__result

    def avg_salary(self) raises -> Float64:
        var sqrrl__ids = List[UInt32]()
        for sqrrl__i in range(self.table.state[].id_count()):
            var sqrrl__id = UInt32(sqrrl__i)
            if self.table.state[].is_live(sqrrl__id):
                sqrrl__ids.append(sqrrl__id)
        if len(sqrrl__ids) == 0:
            raise Error("avg_salary: table has no entities")
        var sqrrl__opt = self.table.state[].state.salary.get_fwd(sqrrl__ids[0])
        var sqrrl__result = sqrrl__opt.take()
        for sqrrl__i in range(1, len(sqrrl__ids)):
            var sqrrl__opt2 = self.table.state[].state.salary.get_fwd(sqrrl__ids[sqrrl__i])
            sqrrl__result = sqrrl__result + sqrrl__opt2.take()
        return Float64(sqrrl__result) / Float64(len(sqrrl__ids))

    def min_salary(self) raises -> Float64:
        var sqrrl__ids = List[UInt32]()
        for sqrrl__i in range(self.table.state[].id_count()):
            var sqrrl__id = UInt32(sqrrl__i)
            if self.table.state[].is_live(sqrrl__id):
                sqrrl__ids.append(sqrrl__id)
        if len(sqrrl__ids) == 0:
            raise Error("min_salary: table has no entities")
        var sqrrl__opt = self.table.state[].state.salary.get_fwd(sqrrl__ids[0])
        var sqrrl__result = sqrrl__opt.take()
        for sqrrl__i in range(1, len(sqrrl__ids)):
            var sqrrl__opt2 = self.table.state[].state.salary.get_fwd(sqrrl__ids[sqrrl__i])
            var sqrrl__v = sqrrl__opt2.take()
            if sqrrl__v < sqrrl__result:
                sqrrl__result = sqrrl__v
        return sqrrl__result

    def max_salary(self) raises -> Float64:
        var sqrrl__ids = List[UInt32]()
        for sqrrl__i in range(self.table.state[].id_count()):
            var sqrrl__id = UInt32(sqrrl__i)
            if self.table.state[].is_live(sqrrl__id):
                sqrrl__ids.append(sqrrl__id)
        if len(sqrrl__ids) == 0:
            raise Error("max_salary: table has no entities")
        var sqrrl__opt = self.table.state[].state.salary.get_fwd(sqrrl__ids[0])
        var sqrrl__result = sqrrl__opt.take()
        for sqrrl__i in range(1, len(sqrrl__ids)):
            var sqrrl__opt2 = self.table.state[].state.salary.get_fwd(sqrrl__ids[sqrrl__i])
            var sqrrl__v = sqrrl__opt2.take()
            if sqrrl__v > sqrrl__result:
                sqrrl__result = sqrrl__v
        return sqrrl__result

    def sum_salary_by_email(self) -> Dict[String, Float64]:
        ref sqrrl__ids = self.table.state[].state.email.all_bwd()
        var out = Dict[String, Float64]()
        for entry in sqrrl__ids.items():
            var sqrrl__opt = self.table.state[].state.salary.get_fwd(entry.value)
            out[entry.key] = sqrrl__opt.take()
        return out^

    def sum_salary_for_email(self, value: String) raises -> Float64:
        var sqrrl__id = self.table.state[].state.email.get_bwd(value)
        var sqrrl__opt = self.table.state[].state.salary.get_fwd(sqrrl__id)
        return sqrrl__opt.take()

    def avg_salary_by_email(self) -> Dict[String, Float64]:
        ref sqrrl__ids = self.table.state[].state.email.all_bwd()
        var out = Dict[String, Float64]()
        for entry in sqrrl__ids.items():
            var sqrrl__opt = self.table.state[].state.salary.get_fwd(entry.value)
            out[entry.key] = Float64(sqrrl__opt.take())
        return out^

    def avg_salary_for_email(self, value: String) raises -> Float64:
        var sqrrl__id = self.table.state[].state.email.get_bwd(value)
        var sqrrl__opt = self.table.state[].state.salary.get_fwd(sqrrl__id)
        return Float64(sqrrl__opt.take())

    def min_salary_by_email(self) -> Dict[String, Float64]:
        ref sqrrl__ids = self.table.state[].state.email.all_bwd()
        var out = Dict[String, Float64]()
        for entry in sqrrl__ids.items():
            var sqrrl__opt = self.table.state[].state.salary.get_fwd(entry.value)
            out[entry.key] = sqrrl__opt.take()
        return out^

    def min_salary_for_email(self, value: String) raises -> Float64:
        var sqrrl__id = self.table.state[].state.email.get_bwd(value)
        var sqrrl__opt = self.table.state[].state.salary.get_fwd(sqrrl__id)
        return sqrrl__opt.take()

    def max_salary_by_email(self) -> Dict[String, Float64]:
        ref sqrrl__ids = self.table.state[].state.email.all_bwd()
        var out = Dict[String, Float64]()
        for entry in sqrrl__ids.items():
            var sqrrl__opt = self.table.state[].state.salary.get_fwd(entry.value)
            out[entry.key] = sqrrl__opt.take()
        return out^

    def max_salary_for_email(self, value: String) raises -> Float64:
        var sqrrl__id = self.table.state[].state.email.get_bwd(value)
        var sqrrl__opt = self.table.state[].state.salary.get_fwd(sqrrl__id)
        return sqrrl__opt.take()

    def sum_salary_by_title(self) -> Dict[String, Float64]:
        ref sqrrl__buckets = self.table.state[].state.title.all_bwd()
        var out = Dict[String, Float64]()
        for entry in sqrrl__buckets.items():
            var sqrrl__ids = List[UInt32]()
            for sqrrl__id in entry.value:
                sqrrl__ids.append(sqrrl__id)
            var sqrrl__opt = self.table.state[].state.salary.get_fwd(sqrrl__ids[0])
            var sqrrl__result = sqrrl__opt.take()
            for sqrrl__i in range(1, len(sqrrl__ids)):
                var sqrrl__opt2 = self.table.state[].state.salary.get_fwd(sqrrl__ids[sqrrl__i])
                sqrrl__result = sqrrl__result + sqrrl__opt2.take()
            out[entry.key] = sqrrl__result
        return out^

    def sum_salary_for_title(self, value: String) raises -> Float64:
        var sqrrl__ids = List[UInt32]()
        for sqrrl__id in self.table.state[].state.title.get_bwd(value):
            sqrrl__ids.append(sqrrl__id)
        if len(sqrrl__ids) == 0:
            raise Error("sum_salary_for_title: no entities found for this value")
        var sqrrl__opt = self.table.state[].state.salary.get_fwd(sqrrl__ids[0])
        var sqrrl__result = sqrrl__opt.take()
        for sqrrl__i in range(1, len(sqrrl__ids)):
            var sqrrl__opt2 = self.table.state[].state.salary.get_fwd(sqrrl__ids[sqrrl__i])
            sqrrl__result = sqrrl__result + sqrrl__opt2.take()
        return sqrrl__result

    def avg_salary_by_title(self) -> Dict[String, Float64]:
        ref sqrrl__buckets = self.table.state[].state.title.all_bwd()
        var out = Dict[String, Float64]()
        for entry in sqrrl__buckets.items():
            var sqrrl__ids = List[UInt32]()
            for sqrrl__id in entry.value:
                sqrrl__ids.append(sqrrl__id)
            var sqrrl__opt = self.table.state[].state.salary.get_fwd(sqrrl__ids[0])
            var sqrrl__result = sqrrl__opt.take()
            for sqrrl__i in range(1, len(sqrrl__ids)):
                var sqrrl__opt2 = self.table.state[].state.salary.get_fwd(sqrrl__ids[sqrrl__i])
                sqrrl__result = sqrrl__result + sqrrl__opt2.take()
            out[entry.key] = Float64(sqrrl__result) / Float64(len(sqrrl__ids))
        return out^

    def avg_salary_for_title(self, value: String) raises -> Float64:
        var sqrrl__ids = List[UInt32]()
        for sqrrl__id in self.table.state[].state.title.get_bwd(value):
            sqrrl__ids.append(sqrrl__id)
        if len(sqrrl__ids) == 0:
            raise Error("avg_salary_for_title: no entities found for this value")
        var sqrrl__opt = self.table.state[].state.salary.get_fwd(sqrrl__ids[0])
        var sqrrl__result = sqrrl__opt.take()
        for sqrrl__i in range(1, len(sqrrl__ids)):
            var sqrrl__opt2 = self.table.state[].state.salary.get_fwd(sqrrl__ids[sqrrl__i])
            sqrrl__result = sqrrl__result + sqrrl__opt2.take()
        return Float64(sqrrl__result) / Float64(len(sqrrl__ids))

    def min_salary_by_title(self) -> Dict[String, Float64]:
        ref sqrrl__buckets = self.table.state[].state.title.all_bwd()
        var out = Dict[String, Float64]()
        for entry in sqrrl__buckets.items():
            var sqrrl__ids = List[UInt32]()
            for sqrrl__id in entry.value:
                sqrrl__ids.append(sqrrl__id)
            var sqrrl__opt = self.table.state[].state.salary.get_fwd(sqrrl__ids[0])
            var sqrrl__result = sqrrl__opt.take()
            for sqrrl__i in range(1, len(sqrrl__ids)):
                var sqrrl__opt2 = self.table.state[].state.salary.get_fwd(sqrrl__ids[sqrrl__i])
                var sqrrl__v = sqrrl__opt2.take()
                if sqrrl__v < sqrrl__result:
                    sqrrl__result = sqrrl__v
            out[entry.key] = sqrrl__result
        return out^

    def min_salary_for_title(self, value: String) raises -> Float64:
        var sqrrl__ids = List[UInt32]()
        for sqrrl__id in self.table.state[].state.title.get_bwd(value):
            sqrrl__ids.append(sqrrl__id)
        if len(sqrrl__ids) == 0:
            raise Error("min_salary_for_title: no entities found for this value")
        var sqrrl__opt = self.table.state[].state.salary.get_fwd(sqrrl__ids[0])
        var sqrrl__result = sqrrl__opt.take()
        for sqrrl__i in range(1, len(sqrrl__ids)):
            var sqrrl__opt2 = self.table.state[].state.salary.get_fwd(sqrrl__ids[sqrrl__i])
            var sqrrl__v = sqrrl__opt2.take()
            if sqrrl__v < sqrrl__result:
                sqrrl__result = sqrrl__v
        return sqrrl__result

    def max_salary_by_title(self) -> Dict[String, Float64]:
        ref sqrrl__buckets = self.table.state[].state.title.all_bwd()
        var out = Dict[String, Float64]()
        for entry in sqrrl__buckets.items():
            var sqrrl__ids = List[UInt32]()
            for sqrrl__id in entry.value:
                sqrrl__ids.append(sqrrl__id)
            var sqrrl__opt = self.table.state[].state.salary.get_fwd(sqrrl__ids[0])
            var sqrrl__result = sqrrl__opt.take()
            for sqrrl__i in range(1, len(sqrrl__ids)):
                var sqrrl__opt2 = self.table.state[].state.salary.get_fwd(sqrrl__ids[sqrrl__i])
                var sqrrl__v = sqrrl__opt2.take()
                if sqrrl__v > sqrrl__result:
                    sqrrl__result = sqrrl__v
            out[entry.key] = sqrrl__result
        return out^

    def max_salary_for_title(self, value: String) raises -> Float64:
        var sqrrl__ids = List[UInt32]()
        for sqrrl__id in self.table.state[].state.title.get_bwd(value):
            sqrrl__ids.append(sqrrl__id)
        if len(sqrrl__ids) == 0:
            raise Error("max_salary_for_title: no entities found for this value")
        var sqrrl__opt = self.table.state[].state.salary.get_fwd(sqrrl__ids[0])
        var sqrrl__result = sqrrl__opt.take()
        for sqrrl__i in range(1, len(sqrrl__ids)):
            var sqrrl__opt2 = self.table.state[].state.salary.get_fwd(sqrrl__ids[sqrrl__i])
            var sqrrl__v = sqrrl__opt2.take()
            if sqrrl__v > sqrrl__result:
                sqrrl__result = sqrrl__v
        return sqrrl__result

    def sum_salary_by_years_employed(self) -> Dict[UInt32, Float64]:
        var sqrrl__buckets = self.table.state[].state.years_employed.all_bwd()
        var out = Dict[UInt32, Float64]()
        for entry in sqrrl__buckets.items():
            var sqrrl__ids = List[UInt32]()
            for sqrrl__id in entry.value:
                sqrrl__ids.append(sqrrl__id)
            var sqrrl__opt = self.table.state[].state.salary.get_fwd(sqrrl__ids[0])
            var sqrrl__result = sqrrl__opt.take()
            for sqrrl__i in range(1, len(sqrrl__ids)):
                var sqrrl__opt2 = self.table.state[].state.salary.get_fwd(sqrrl__ids[sqrrl__i])
                sqrrl__result = sqrrl__result + sqrrl__opt2.take()
            out[entry.key] = sqrrl__result
        return out^

    def sum_salary_for_years_employed(self, value: UInt32) raises -> Float64:
        var sqrrl__ids = List[UInt32]()
        for sqrrl__id in self.table.state[].state.years_employed.get_bwd(value):
            sqrrl__ids.append(sqrrl__id)
        if len(sqrrl__ids) == 0:
            raise Error("sum_salary_for_years_employed: no entities found for this value")
        var sqrrl__opt = self.table.state[].state.salary.get_fwd(sqrrl__ids[0])
        var sqrrl__result = sqrrl__opt.take()
        for sqrrl__i in range(1, len(sqrrl__ids)):
            var sqrrl__opt2 = self.table.state[].state.salary.get_fwd(sqrrl__ids[sqrrl__i])
            sqrrl__result = sqrrl__result + sqrrl__opt2.take()
        return sqrrl__result

    def avg_salary_by_years_employed(self) -> Dict[UInt32, Float64]:
        var sqrrl__buckets = self.table.state[].state.years_employed.all_bwd()
        var out = Dict[UInt32, Float64]()
        for entry in sqrrl__buckets.items():
            var sqrrl__ids = List[UInt32]()
            for sqrrl__id in entry.value:
                sqrrl__ids.append(sqrrl__id)
            var sqrrl__opt = self.table.state[].state.salary.get_fwd(sqrrl__ids[0])
            var sqrrl__result = sqrrl__opt.take()
            for sqrrl__i in range(1, len(sqrrl__ids)):
                var sqrrl__opt2 = self.table.state[].state.salary.get_fwd(sqrrl__ids[sqrrl__i])
                sqrrl__result = sqrrl__result + sqrrl__opt2.take()
            out[entry.key] = Float64(sqrrl__result) / Float64(len(sqrrl__ids))
        return out^

    def avg_salary_for_years_employed(self, value: UInt32) raises -> Float64:
        var sqrrl__ids = List[UInt32]()
        for sqrrl__id in self.table.state[].state.years_employed.get_bwd(value):
            sqrrl__ids.append(sqrrl__id)
        if len(sqrrl__ids) == 0:
            raise Error("avg_salary_for_years_employed: no entities found for this value")
        var sqrrl__opt = self.table.state[].state.salary.get_fwd(sqrrl__ids[0])
        var sqrrl__result = sqrrl__opt.take()
        for sqrrl__i in range(1, len(sqrrl__ids)):
            var sqrrl__opt2 = self.table.state[].state.salary.get_fwd(sqrrl__ids[sqrrl__i])
            sqrrl__result = sqrrl__result + sqrrl__opt2.take()
        return Float64(sqrrl__result) / Float64(len(sqrrl__ids))

    def min_salary_by_years_employed(self) -> Dict[UInt32, Float64]:
        var sqrrl__buckets = self.table.state[].state.years_employed.all_bwd()
        var out = Dict[UInt32, Float64]()
        for entry in sqrrl__buckets.items():
            var sqrrl__ids = List[UInt32]()
            for sqrrl__id in entry.value:
                sqrrl__ids.append(sqrrl__id)
            var sqrrl__opt = self.table.state[].state.salary.get_fwd(sqrrl__ids[0])
            var sqrrl__result = sqrrl__opt.take()
            for sqrrl__i in range(1, len(sqrrl__ids)):
                var sqrrl__opt2 = self.table.state[].state.salary.get_fwd(sqrrl__ids[sqrrl__i])
                var sqrrl__v = sqrrl__opt2.take()
                if sqrrl__v < sqrrl__result:
                    sqrrl__result = sqrrl__v
            out[entry.key] = sqrrl__result
        return out^

    def min_salary_for_years_employed(self, value: UInt32) raises -> Float64:
        var sqrrl__ids = List[UInt32]()
        for sqrrl__id in self.table.state[].state.years_employed.get_bwd(value):
            sqrrl__ids.append(sqrrl__id)
        if len(sqrrl__ids) == 0:
            raise Error("min_salary_for_years_employed: no entities found for this value")
        var sqrrl__opt = self.table.state[].state.salary.get_fwd(sqrrl__ids[0])
        var sqrrl__result = sqrrl__opt.take()
        for sqrrl__i in range(1, len(sqrrl__ids)):
            var sqrrl__opt2 = self.table.state[].state.salary.get_fwd(sqrrl__ids[sqrrl__i])
            var sqrrl__v = sqrrl__opt2.take()
            if sqrrl__v < sqrrl__result:
                sqrrl__result = sqrrl__v
        return sqrrl__result

    def max_salary_by_years_employed(self) -> Dict[UInt32, Float64]:
        var sqrrl__buckets = self.table.state[].state.years_employed.all_bwd()
        var out = Dict[UInt32, Float64]()
        for entry in sqrrl__buckets.items():
            var sqrrl__ids = List[UInt32]()
            for sqrrl__id in entry.value:
                sqrrl__ids.append(sqrrl__id)
            var sqrrl__opt = self.table.state[].state.salary.get_fwd(sqrrl__ids[0])
            var sqrrl__result = sqrrl__opt.take()
            for sqrrl__i in range(1, len(sqrrl__ids)):
                var sqrrl__opt2 = self.table.state[].state.salary.get_fwd(sqrrl__ids[sqrrl__i])
                var sqrrl__v = sqrrl__opt2.take()
                if sqrrl__v > sqrrl__result:
                    sqrrl__result = sqrrl__v
            out[entry.key] = sqrrl__result
        return out^

    def max_salary_for_years_employed(self, value: UInt32) raises -> Float64:
        var sqrrl__ids = List[UInt32]()
        for sqrrl__id in self.table.state[].state.years_employed.get_bwd(value):
            sqrrl__ids.append(sqrrl__id)
        if len(sqrrl__ids) == 0:
            raise Error("max_salary_for_years_employed: no entities found for this value")
        var sqrrl__opt = self.table.state[].state.salary.get_fwd(sqrrl__ids[0])
        var sqrrl__result = sqrrl__opt.take()
        for sqrrl__i in range(1, len(sqrrl__ids)):
            var sqrrl__opt2 = self.table.state[].state.salary.get_fwd(sqrrl__ids[sqrrl__i])
            var sqrrl__v = sqrrl__opt2.take()
            if sqrrl__v > sqrrl__result:
                sqrrl__result = sqrrl__v
        return sqrrl__result

    def sum_salary_by_dept(self) -> Dict[EntityHandle[sqrrl__DepartmentTableState], Float64]:
        ref sqrrl__buckets = self.table.state[].state.dept.all_bwd()
        var out = Dict[EntityHandle[sqrrl__DepartmentTableState], Float64]()
        for entry in sqrrl__buckets.items():
            var sqrrl__ids = List[UInt32]()
            for sqrrl__id in entry.value:
                sqrrl__ids.append(sqrrl__id)
            var sqrrl__opt = self.table.state[].state.salary.get_fwd(sqrrl__ids[0])
            var sqrrl__result = sqrrl__opt.take()
            for sqrrl__i in range(1, len(sqrrl__ids)):
                var sqrrl__opt2 = self.table.state[].state.salary.get_fwd(sqrrl__ids[sqrrl__i])
                sqrrl__result = sqrrl__result + sqrrl__opt2.take()
            out[entry.key] = sqrrl__result
        return out^

    def sum_salary_for_dept(self, value: EntityHandle[sqrrl__DepartmentTableState]) raises -> Float64:
        var sqrrl__ids = List[UInt32]()
        for sqrrl__id in self.table.state[].state.dept.get_bwd(value):
            sqrrl__ids.append(sqrrl__id)
        if len(sqrrl__ids) == 0:
            raise Error("sum_salary_for_dept: no entities found for this value")
        var sqrrl__opt = self.table.state[].state.salary.get_fwd(sqrrl__ids[0])
        var sqrrl__result = sqrrl__opt.take()
        for sqrrl__i in range(1, len(sqrrl__ids)):
            var sqrrl__opt2 = self.table.state[].state.salary.get_fwd(sqrrl__ids[sqrrl__i])
            sqrrl__result = sqrrl__result + sqrrl__opt2.take()
        return sqrrl__result

    def avg_salary_by_dept(self) -> Dict[EntityHandle[sqrrl__DepartmentTableState], Float64]:
        ref sqrrl__buckets = self.table.state[].state.dept.all_bwd()
        var out = Dict[EntityHandle[sqrrl__DepartmentTableState], Float64]()
        for entry in sqrrl__buckets.items():
            var sqrrl__ids = List[UInt32]()
            for sqrrl__id in entry.value:
                sqrrl__ids.append(sqrrl__id)
            var sqrrl__opt = self.table.state[].state.salary.get_fwd(sqrrl__ids[0])
            var sqrrl__result = sqrrl__opt.take()
            for sqrrl__i in range(1, len(sqrrl__ids)):
                var sqrrl__opt2 = self.table.state[].state.salary.get_fwd(sqrrl__ids[sqrrl__i])
                sqrrl__result = sqrrl__result + sqrrl__opt2.take()
            out[entry.key] = Float64(sqrrl__result) / Float64(len(sqrrl__ids))
        return out^

    def avg_salary_for_dept(self, value: EntityHandle[sqrrl__DepartmentTableState]) raises -> Float64:
        var sqrrl__ids = List[UInt32]()
        for sqrrl__id in self.table.state[].state.dept.get_bwd(value):
            sqrrl__ids.append(sqrrl__id)
        if len(sqrrl__ids) == 0:
            raise Error("avg_salary_for_dept: no entities found for this value")
        var sqrrl__opt = self.table.state[].state.salary.get_fwd(sqrrl__ids[0])
        var sqrrl__result = sqrrl__opt.take()
        for sqrrl__i in range(1, len(sqrrl__ids)):
            var sqrrl__opt2 = self.table.state[].state.salary.get_fwd(sqrrl__ids[sqrrl__i])
            sqrrl__result = sqrrl__result + sqrrl__opt2.take()
        return Float64(sqrrl__result) / Float64(len(sqrrl__ids))

    def min_salary_by_dept(self) -> Dict[EntityHandle[sqrrl__DepartmentTableState], Float64]:
        ref sqrrl__buckets = self.table.state[].state.dept.all_bwd()
        var out = Dict[EntityHandle[sqrrl__DepartmentTableState], Float64]()
        for entry in sqrrl__buckets.items():
            var sqrrl__ids = List[UInt32]()
            for sqrrl__id in entry.value:
                sqrrl__ids.append(sqrrl__id)
            var sqrrl__opt = self.table.state[].state.salary.get_fwd(sqrrl__ids[0])
            var sqrrl__result = sqrrl__opt.take()
            for sqrrl__i in range(1, len(sqrrl__ids)):
                var sqrrl__opt2 = self.table.state[].state.salary.get_fwd(sqrrl__ids[sqrrl__i])
                var sqrrl__v = sqrrl__opt2.take()
                if sqrrl__v < sqrrl__result:
                    sqrrl__result = sqrrl__v
            out[entry.key] = sqrrl__result
        return out^

    def min_salary_for_dept(self, value: EntityHandle[sqrrl__DepartmentTableState]) raises -> Float64:
        var sqrrl__ids = List[UInt32]()
        for sqrrl__id in self.table.state[].state.dept.get_bwd(value):
            sqrrl__ids.append(sqrrl__id)
        if len(sqrrl__ids) == 0:
            raise Error("min_salary_for_dept: no entities found for this value")
        var sqrrl__opt = self.table.state[].state.salary.get_fwd(sqrrl__ids[0])
        var sqrrl__result = sqrrl__opt.take()
        for sqrrl__i in range(1, len(sqrrl__ids)):
            var sqrrl__opt2 = self.table.state[].state.salary.get_fwd(sqrrl__ids[sqrrl__i])
            var sqrrl__v = sqrrl__opt2.take()
            if sqrrl__v < sqrrl__result:
                sqrrl__result = sqrrl__v
        return sqrrl__result

    def max_salary_by_dept(self) -> Dict[EntityHandle[sqrrl__DepartmentTableState], Float64]:
        ref sqrrl__buckets = self.table.state[].state.dept.all_bwd()
        var out = Dict[EntityHandle[sqrrl__DepartmentTableState], Float64]()
        for entry in sqrrl__buckets.items():
            var sqrrl__ids = List[UInt32]()
            for sqrrl__id in entry.value:
                sqrrl__ids.append(sqrrl__id)
            var sqrrl__opt = self.table.state[].state.salary.get_fwd(sqrrl__ids[0])
            var sqrrl__result = sqrrl__opt.take()
            for sqrrl__i in range(1, len(sqrrl__ids)):
                var sqrrl__opt2 = self.table.state[].state.salary.get_fwd(sqrrl__ids[sqrrl__i])
                var sqrrl__v = sqrrl__opt2.take()
                if sqrrl__v > sqrrl__result:
                    sqrrl__result = sqrrl__v
            out[entry.key] = sqrrl__result
        return out^

    def max_salary_for_dept(self, value: EntityHandle[sqrrl__DepartmentTableState]) raises -> Float64:
        var sqrrl__ids = List[UInt32]()
        for sqrrl__id in self.table.state[].state.dept.get_bwd(value):
            sqrrl__ids.append(sqrrl__id)
        if len(sqrrl__ids) == 0:
            raise Error("max_salary_for_dept: no entities found for this value")
        var sqrrl__opt = self.table.state[].state.salary.get_fwd(sqrrl__ids[0])
        var sqrrl__result = sqrrl__opt.take()
        for sqrrl__i in range(1, len(sqrrl__ids)):
            var sqrrl__opt2 = self.table.state[].state.salary.get_fwd(sqrrl__ids[sqrrl__i])
            var sqrrl__v = sqrrl__opt2.take()
            if sqrrl__v > sqrrl__result:
                sqrrl__result = sqrrl__v
        return sqrrl__result

    def sqrrl__to_json(self, e: EntityHandle[sqrrl__EmployeeTableState]) -> String:
        var out = String("{")
        out += "\"email\":" + sqrrl__to_json(self.get_email(e))
        out += ","
        out += "\"title\":" + sqrrl__to_json(self.get_title(e))
        out += ","
        out += "\"years_employed\":" + sqrrl__to_json(self.get_years_employed(e))
        out += ","
        out += "\"salary\":" + sqrrl__to_json(self.get_salary(e))
        out += ","
        out += "\"dept\":" + sqrrl__to_json(self.get_dept(e))
        out += ","
        out += "\"profile\":" + sqrrl__to_json(self.get_profile(e))
        out += "}"
        return out^

    def sqrrl__from_json(mut self, mut sqrrl__tbl_Department: sqrrl__DepartmentTable, mut sc: sqrrl__JsonScanner) raises -> EntityHandle[sqrrl__EmployeeTableState]:
        var sqrrl__parsed_email: Optional[String] = None
        var sqrrl__parsed_title: Optional[String] = None
        var sqrrl__parsed_years_employed: Optional[UInt32] = None
        var sqrrl__parsed_salary: Optional[Float64] = None
        var sqrrl__parsed_dept: Optional[EntityHandle[sqrrl__DepartmentTableState]] = None
        var sqrrl__parsed_profile: Optional[Profile] = None
        sc.expect_byte(UInt8(ord("{")))
        if not sc.try_consume_byte(UInt8(ord("}"))):
            while True:
                var sqrrl__key = sc.parse_json_string()
                sc.expect_byte(UInt8(ord(":")))
                if sqrrl__key == "email":
                    sqrrl__parsed_email = sqrrl__from_json[String](sc)
                elif sqrrl__key == "title":
                    sqrrl__parsed_title = sqrrl__from_json[String](sc)
                elif sqrrl__key == "years_employed":
                    sqrrl__parsed_years_employed = sqrrl__from_json[UInt32](sc)
                elif sqrrl__key == "salary":
                    sqrrl__parsed_salary = sqrrl__from_json[Float64](sc)
                elif sqrrl__key == "dept":
                    sqrrl__parsed_dept = sqrrl__tbl_Department.table.handle_for(UInt32(sc.parse_json_int()))
                elif sqrrl__key == "profile":
                    sqrrl__parsed_profile = sqrrl__Profile_from_json(sc)
                if sc.try_consume_byte(UInt8(ord(","))):
                    continue
                sc.expect_byte(UInt8(ord("}")))
                break
        return self.create(sqrrl__parsed_email.take(), sqrrl__parsed_title.take(), sqrrl__parsed_years_employed.take(), sqrrl__parsed_salary.take(), sqrrl__parsed_dept.take(), sqrrl__parsed_profile.take())

    def sqrrl__from_json_with_id(mut self, mut sqrrl__tbl_Department: sqrrl__DepartmentTable, sqrrl__id: UInt32, mut sc: sqrrl__JsonScanner) raises -> EntityHandle[sqrrl__EmployeeTableState]:
        var sqrrl__parsed_email: Optional[String] = None
        var sqrrl__parsed_title: Optional[String] = None
        var sqrrl__parsed_years_employed: Optional[UInt32] = None
        var sqrrl__parsed_salary: Optional[Float64] = None
        var sqrrl__parsed_dept: Optional[EntityHandle[sqrrl__DepartmentTableState]] = None
        var sqrrl__parsed_profile: Optional[Profile] = None
        sc.expect_byte(UInt8(ord("{")))
        if not sc.try_consume_byte(UInt8(ord("}"))):
            while True:
                var sqrrl__key = sc.parse_json_string()
                sc.expect_byte(UInt8(ord(":")))
                if sqrrl__key == "email":
                    sqrrl__parsed_email = sqrrl__from_json[String](sc)
                elif sqrrl__key == "title":
                    sqrrl__parsed_title = sqrrl__from_json[String](sc)
                elif sqrrl__key == "years_employed":
                    sqrrl__parsed_years_employed = sqrrl__from_json[UInt32](sc)
                elif sqrrl__key == "salary":
                    sqrrl__parsed_salary = sqrrl__from_json[Float64](sc)
                elif sqrrl__key == "dept":
                    sqrrl__parsed_dept = sqrrl__tbl_Department.table.handle_for(UInt32(sc.parse_json_int()))
                elif sqrrl__key == "profile":
                    sqrrl__parsed_profile = sqrrl__Profile_from_json(sc)
                if sc.try_consume_byte(UInt8(ord(","))):
                    continue
                sc.expect_byte(UInt8(ord("}")))
                break
        return self.sqrrl__create_with_id(sqrrl__id, sqrrl__parsed_email.take(), sqrrl__parsed_title.take(), sqrrl__parsed_years_employed.take(), sqrrl__parsed_salary.take(), sqrrl__parsed_dept.take(), sqrrl__parsed_profile.take())

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

    def sqrrl__all_from_json(mut self, mut sqrrl__tbl_Department: sqrrl__DepartmentTable, mut sqrrl__temp: List[EntityHandle[sqrrl__EmployeeTableState]], mut sc: sqrrl__JsonScanner) raises:
        sc.expect_byte(UInt8(ord("[")))
        if not sc.try_consume_byte(UInt8(ord("]"))):
            while True:
                sc.expect_byte(UInt8(ord("[")))
                var sqrrl__id = UInt32(sc.parse_json_int())
                sc.expect_byte(UInt8(ord(",")))
                var sqrrl__e = self.sqrrl__from_json_with_id(sqrrl__tbl_Department, sqrrl__id, sc)
                sqrrl__temp.append(sqrrl__e^)
                sc.expect_byte(UInt8(ord("]")))
                if sc.try_consume_byte(UInt8(ord(","))):
                    continue
                sc.expect_byte(UInt8(ord("]")))
                break
