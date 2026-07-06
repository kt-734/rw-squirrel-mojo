from squirrel_runtime.entity import Table, EntityHandle, EntityInner, TableStateLike
from squirrel_runtime.rel import Rel, UniqueRel, ForwardOnlyRel, MultiRel, OrderedRel
from std.collections import Set
from std.os import abort
from sqrrl__world import sqrrl__init, sqrrl__World
from schema.person import sqrrl__PersonTableState
from schema.department import sqrrl__DepartmentTableState
from schema.employee import sqrrl__EmployeeTableState
from schema.address import Address


def sqrrl__make_department(mut sqrrl__world: sqrrl__World, name: String) -> EntityHandle[sqrrl__DepartmentTableState]:
    var sqrrl__d = sqrrl__world.Department.create(name = name);
    return sqrrl__d;

def sqrrl__hire(mut sqrrl__world: sqrrl__World, title: String, sqrrl__dept: EntityHandle[sqrrl__DepartmentTableState]) -> EntityHandle[sqrrl__EmployeeTableState]:
    var sqrrl__e = sqrrl__world.Employee.create(title = title, dept = sqrrl__dept);
    return sqrrl__e;

def sqrrl__make_person(mut sqrrl__world: sqrrl__World, name: String, sqrrl__job: EntityHandle[sqrrl__EmployeeTableState]) -> EntityHandle[sqrrl__PersonTableState]:
    var sqrrl__p = sqrrl__world.Person.create(name = name, home = Address(sqrrl__world.Department.get_name(sqrrl__world.Employee.get_dept(sqrrl__job))), job = sqrrl__job);
    return sqrrl__p;

def sqrrl__make_team(mut sqrrl__world: sqrrl__World, names: List[String], sqrrl__job: EntityHandle[sqrrl__EmployeeTableState]) -> List[EntityHandle[sqrrl__PersonTableState]]:
    var sqrrl__team = List[EntityHandle[sqrrl__PersonTableState]]();
    for name in names:
        sqrrl__team.append(sqrrl__make_person(sqrrl__world, name, sqrrl__job));
    return sqrrl__team^;
