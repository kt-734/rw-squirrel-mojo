from squirrel_runtime.entity import Table, EntityHandle, EntityInner, TableStateLike
from squirrel_runtime.rel import Rel, UniqueRel, ForwardOnlyRel, MultiRel, OrderedRel
from std.collections import Set
from std.os import abort
from sqrrl__world import sqrrl__init, sqrrl__World, sqrrl__world_from_json, sqrrl__init_from_json
from schema.person import sqrrl__PersonTableState
from schema.team import sqrrl__TeamTableState
from schema.department import sqrrl__DepartmentTableState
from schema.project import sqrrl__ProjectTableState
from schema.vendor import sqrrl__VendorTableState
from schema.employee import sqrrl__EmployeeTableState
from schema.box import Box
from schema.address import Address
from schema.pair import Pair
from schema.contact_info import ContactInfo
from schema.money import Money
from schema.assignment import Assignment
from schema.profile import Profile


from schema.money import Money
from schema.address import Address
from schema.contact_info import ContactInfo
from schema.box import Box
from schema.pair import Pair
from schema.profile import Profile
from schema.assignment import Assignment


def sqrrl__make_vendor(mut sqrrl__world: sqrrl__World, name: String) -> EntityHandle[sqrrl__VendorTableState]:
    var sqrrl__v = sqrrl__world.Vendor.create(name = name)
    return sqrrl__v

def sqrrl__make_project(mut sqrrl__world: sqrrl__World, name: String, priority: UInt32, sqrrl__vendor: EntityHandle[sqrrl__VendorTableState], budget_cents: Int64) -> EntityHandle[sqrrl__ProjectTableState]:
    var sqrrl__p = sqrrl__world.Project.create(name = name, priority = priority, vendor = sqrrl__vendor, budget = Money(budget_cents))
    return sqrrl__p

def sqrrl__make_department(mut sqrrl__world: sqrrl__World, name: String) -> EntityHandle[sqrrl__DepartmentTableState]:
    var sqrrl__d = sqrrl__world.Department.create(name = name, tags = List[String](), projects = Set[EntityHandle[sqrrl__ProjectTableState]](), vendors = Set[EntityHandle[sqrrl__VendorTableState]](), skills = Set[String]())
    return sqrrl__d

def sqrrl__hire(mut sqrrl__world: sqrrl__World, name: String, email: String, title: String, years_employed: UInt32, sqrrl__dept: EntityHandle[sqrrl__DepartmentTableState]) raises -> EntityHandle[sqrrl__EmployeeTableState]:
    var profile = Profile(
        contact=ContactInfo(home=Address("1 Main St", "Springfield"), emails=List[String]()),
        nicknames=None,
        scores=Dict[String, Int](),
        rating=Box[UInt32](0),
        coordinates=Pair[Int, Int](0, 0),
        past_addresses=List[Address](),
        boxed_ratings=List[Box[UInt32]](),
    )
    var sqrrl__e = sqrrl__world.Employee.create(email = email, title = title, years_employed = years_employed, dept = sqrrl__dept, profile = profile)
    return sqrrl__e

def sqrrl__hire_team(mut sqrrl__world: sqrrl__World, names: List[String], email_suffix: String, starting_years: UInt32, sqrrl__dept: EntityHandle[sqrrl__DepartmentTableState]) raises -> List[EntityHandle[sqrrl__EmployeeTableState]]:
    var sqrrl__team = List[EntityHandle[sqrrl__EmployeeTableState]]()
    var years = starting_years
    for name in names:
        var sqrrl__emp = sqrrl__hire(sqrrl__world, name, name + email_suffix, "Engineer", years, sqrrl__dept)
        sqrrl__team.append(sqrrl__emp)
        years += 1
    return sqrrl__team^

def sqrrl__make_team(mut sqrrl__world: sqrrl__World, name: String, sqrrl__lead_person: EntityHandle[sqrrl__PersonTableState], role: String) -> EntityHandle[sqrrl__TeamTableState]:
    var assignment = Assignment(person=sqrrl__lead_person, role=role)
    var sqrrl__t = sqrrl__world.Team.create(name = name, lead = assignment, members = List[EntityHandle[sqrrl__PersonTableState]](), advisor = None)
    return sqrrl__t

def sqrrl__log(mut sqrrl__world: sqrrl__World, message: String) raises:
    # AuditLog is `keepalive` -- discarding the result here is deliberate,
    # not sloppy: there's no local var, no relation field pointing at it,
    # nothing at all keeping this entity alive except keepalive itself.
    _ = sqrrl__world.AuditLog.create(message = message)
