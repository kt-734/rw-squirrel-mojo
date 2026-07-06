from squirrel_runtime.entity import Table, EntityHandle, EntityInner, TableStateLike
from squirrel_runtime.rel import Rel, UniqueRel, ForwardOnlyRel, MultiRel, OrderedRel
from std.collections import Set
from std.os import abort
from sqrrl__json import sqrrl__to_json, sqrrl__from_json
from squirrel_runtime.json import sqrrl__JsonScanner
from sqrrl__json import sqrrl__Address_from_json
from schema.project import sqrrl__ProjectTableState
from schema.project import sqrrl__ProjectTable


struct sqrrl__DepartmentTableState(TableStateLike, Movable, ImplicitlyDeletable):
    var name: Rel[String]
    var tags: ForwardOnlyRel[List[String]]
    var projects: MultiRel[EntityHandle[sqrrl__ProjectTableState]]

    def __init__(out self):
        self.name = Rel[String]()
        self.tags = ForwardOnlyRel[List[String]]()
        self.projects = MultiRel[EntityHandle[sqrrl__ProjectTableState]]()

    def sqrrl__cleanup_relations(mut self, id: UInt32):
        _ = self.name.fetch_remove_fwd(id)
        _ = self.tags.fetch_remove_fwd(id)
        _ = self.projects.fetch_remove_fwd(id)


struct sqrrl__DepartmentTable(Movable):
    var table: Table[sqrrl__DepartmentTableState]

    def __init__(out self):
        self.table = Table[sqrrl__DepartmentTableState](sqrrl__DepartmentTableState())

    def create(mut self, name: String, tags: List[String], projects: Set[EntityHandle[sqrrl__ProjectTableState]]) -> EntityHandle[sqrrl__DepartmentTableState]:
        var e = self.table.create()
        self.table.state[].state.name.put(e.id(), name)
        self.table.state[].state.tags.put(e.id(), tags)
        self.table.state[].state.projects.put(e.id(), projects)
        return e

    def sqrrl__create_with_id(mut self, sqrrl__id: UInt32, name: String, tags: List[String], projects: Set[EntityHandle[sqrrl__ProjectTableState]]) raises -> EntityHandle[sqrrl__DepartmentTableState]:
        var e = self.table.create_with_id(sqrrl__id)
        self.table.state[].state.name.put(e.id(), name)
        self.table.state[].state.tags.put(e.id(), tags)
        self.table.state[].state.projects.put(e.id(), projects)
        return e

    def all(self) -> Set[EntityHandle[sqrrl__DepartmentTableState]]:
        return self.table.all()

    def get_name(self, e: EntityHandle[sqrrl__DepartmentTableState]) -> String:
        var got = self.table.state[].state.name.get_fwd(e.id())
        return got.take()

    def set_name(mut self, e: EntityHandle[sqrrl__DepartmentTableState], v: String):
        self.table.state[].state.name.update(e.id(), v)

    def for_name(self, value: String) -> List[EntityHandle[sqrrl__DepartmentTableState]]:
        var ids = self.table.state[].state.name.get_bwd(value)
        var out = List[EntityHandle[sqrrl__DepartmentTableState]]()
        for id in ids:
            out.append(self.table.handle_for(id))
        return out^

    def get_tags(self, e: EntityHandle[sqrrl__DepartmentTableState]) -> List[String]:
        var got = self.table.state[].state.tags.get_fwd(e.id())
        return got.take()

    def set_tags(mut self, e: EntityHandle[sqrrl__DepartmentTableState], v: List[String]):
        self.table.state[].state.tags.update(e.id(), v)


    def get_projects(self, e: EntityHandle[sqrrl__DepartmentTableState]) -> Set[EntityHandle[sqrrl__ProjectTableState]]:
        var got = self.table.state[].state.projects.get_fwd(e.id())
        return got.take()

    def set_projects(mut self, e: EntityHandle[sqrrl__DepartmentTableState], v: Set[EntityHandle[sqrrl__ProjectTableState]]):
        self.table.state[].state.projects.update(e.id(), v)

    def add_to_projects(mut self, e: EntityHandle[sqrrl__DepartmentTableState], value: EntityHandle[sqrrl__ProjectTableState]) -> Bool:
        return self.table.state[].state.projects.add(e.id(), value)

    def remove_from_projects(mut self, e: EntityHandle[sqrrl__DepartmentTableState], value: EntityHandle[sqrrl__ProjectTableState]) -> Bool:
        return self.table.state[].state.projects.remove(e.id(), value)

    def for_projects(self, value: EntityHandle[sqrrl__ProjectTableState]) -> List[EntityHandle[sqrrl__DepartmentTableState]]:
        var ids = self.table.state[].state.projects.get_bwd(value)
        var out = List[EntityHandle[sqrrl__DepartmentTableState]]()
        for id in ids:
            out.append(self.table.handle_for(id))
        return out^

    def to_json(self, e: EntityHandle[sqrrl__DepartmentTableState]) -> String:
        var out = String("{")
        out += "\"name\":" + sqrrl__to_json(self.get_name(e))
        out += ","
        out += "\"tags\":" + sqrrl__to_json(self.get_tags(e))
        out += ","
        out += "\"projects\":" + sqrrl__to_json(self.get_projects(e))
        out += "}"
        return out^

    def from_json(mut self, mut sqrrl__tbl_Project: sqrrl__ProjectTable, mut sc: sqrrl__JsonScanner) raises -> EntityHandle[sqrrl__DepartmentTableState]:
        var sqrrl__parsed_name: Optional[String] = None
        var sqrrl__parsed_tags: Optional[List[String]] = None
        var sqrrl__parsed_projects: Optional[Set[EntityHandle[sqrrl__ProjectTableState]]] = None
        sc.expect_byte(UInt8(ord("{")))
        if not sc.try_consume_byte(UInt8(ord("}"))):
            while True:
                var sqrrl__key = sc.parse_json_string()
                sc.expect_byte(UInt8(ord(":")))
                if sqrrl__key == "name":
                    sqrrl__parsed_name = sqrrl__from_json[String](sc)
                elif sqrrl__key == "tags":
                    sqrrl__parsed_tags = sqrrl__from_json[List[String]](sc)
                elif sqrrl__key == "projects":
                    var sqrrl__parsed_projects_tmp = Set[EntityHandle[sqrrl__ProjectTableState]]()
                    sc.expect_byte(UInt8(ord("[")))
                    if not sc.try_consume_byte(UInt8(ord("]"))):
                        while True:
                            sqrrl__parsed_projects_tmp.add(sqrrl__tbl_Project.table.handle_for(UInt32(sc.parse_json_int())))
                            if sc.try_consume_byte(UInt8(ord(","))):
                                continue
                            sc.expect_byte(UInt8(ord("]")))
                            break
                    sqrrl__parsed_projects = sqrrl__parsed_projects_tmp^
                if sc.try_consume_byte(UInt8(ord(","))):
                    continue
                sc.expect_byte(UInt8(ord("}")))
                break
        return self.create(sqrrl__parsed_name.take(), sqrrl__parsed_tags.take(), sqrrl__parsed_projects.take())

    def sqrrl__from_json_with_id(mut self, mut sqrrl__tbl_Project: sqrrl__ProjectTable, sqrrl__id: UInt32, mut sc: sqrrl__JsonScanner) raises -> EntityHandle[sqrrl__DepartmentTableState]:
        var sqrrl__parsed_name: Optional[String] = None
        var sqrrl__parsed_tags: Optional[List[String]] = None
        var sqrrl__parsed_projects: Optional[Set[EntityHandle[sqrrl__ProjectTableState]]] = None
        sc.expect_byte(UInt8(ord("{")))
        if not sc.try_consume_byte(UInt8(ord("}"))):
            while True:
                var sqrrl__key = sc.parse_json_string()
                sc.expect_byte(UInt8(ord(":")))
                if sqrrl__key == "name":
                    sqrrl__parsed_name = sqrrl__from_json[String](sc)
                elif sqrrl__key == "tags":
                    sqrrl__parsed_tags = sqrrl__from_json[List[String]](sc)
                elif sqrrl__key == "projects":
                    var sqrrl__parsed_projects_tmp = Set[EntityHandle[sqrrl__ProjectTableState]]()
                    sc.expect_byte(UInt8(ord("[")))
                    if not sc.try_consume_byte(UInt8(ord("]"))):
                        while True:
                            sqrrl__parsed_projects_tmp.add(sqrrl__tbl_Project.table.handle_for(UInt32(sc.parse_json_int())))
                            if sc.try_consume_byte(UInt8(ord(","))):
                                continue
                            sc.expect_byte(UInt8(ord("]")))
                            break
                    sqrrl__parsed_projects = sqrrl__parsed_projects_tmp^
                if sc.try_consume_byte(UInt8(ord(","))):
                    continue
                sc.expect_byte(UInt8(ord("}")))
                break
        return self.sqrrl__create_with_id(sqrrl__id, sqrrl__parsed_name.take(), sqrrl__parsed_tags.take(), sqrrl__parsed_projects.take())
