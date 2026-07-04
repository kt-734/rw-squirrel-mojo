from squirrel_runtime.entity import Table, EntityHandle, EntityInner, TableStateLike
from squirrel_runtime.rel import Rel, UniqueRel, ForwardOnlyRel, MultiRel, OrderedRel
from std.collections import Set
from std.os import abort
from sqrrl__Squirrel import sqrrl__init, sqrrl__Squirrel
from schema.department import sqrrl__DepartmentTableState
from schema.project import sqrrl__ProjectTableState
from schema.employee import sqrrl__EmployeeTableState


def sqrrl__make_department(mut sqrrl__world: sqrrl__Squirrel, name: String) -> EntityHandle[sqrrl__DepartmentTableState]:
    var sqrrl__dept = sqrrl__world.Department.create(name = name, tags = List[String](), projects = Set[EntityHandle[sqrrl__ProjectTableState]]());
    return sqrrl__dept;

def sqrrl__hire(mut sqrrl__world: sqrrl__Squirrel, name: String, email: String, title: String, sqrrl__dept: EntityHandle[sqrrl__DepartmentTableState]) raises -> EntityHandle[sqrrl__EmployeeTableState]:
    var sqrrl__emp = sqrrl__world.Employee.create(email = email, title = title, dept = sqrrl__dept);
    return sqrrl__emp;

def sqrrl__hire_team(mut sqrrl__world: sqrrl__Squirrel, names: List[String], email_suffix: String, sqrrl__dept: EntityHandle[sqrrl__DepartmentTableState]) raises -> List[EntityHandle[sqrrl__EmployeeTableState]]:
    var sqrrl__team = List[EntityHandle[sqrrl__EmployeeTableState]]();
    for name in names:
        var sqrrl__emp = sqrrl__hire(sqrrl__world, name, name + email_suffix, "Engineer", sqrrl__dept);
        sqrrl__team.append(sqrrl__emp);
    return sqrrl__team^;

def sqrrl__log(mut sqrrl__world: sqrrl__Squirrel, message: String) raises:
    # AuditLog is `keepalive` -- discarding the result here is deliberate,
    # not sloppy: there's no local var, no relation field pointing at it,
    # nothing at all keeping this entity alive except keepalive itself.
    _ = sqrrl__world.AuditLog.create(message = message);
