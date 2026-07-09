from squirrel_runtime.entity import Table, EntityHandle, EntityInner, TableStateLike
from squirrel_runtime.rel import Rel, UniqueRel, ForwardOnlyRel, MultiRel, OrderedRel
from std.collections import Set
from std.os import abort
from sqrrl__world import sqrrl__init, sqrrl__World, sqrrl__world_from_json, sqrrl__init_from_json
from schema.audit_log import sqrrl__AuditLogTableState
from schema.employee import sqrrl__EmployeeTableState
from schema.address import Address


from schema.address import Address
from logic.factories import sqrrl__make_department, sqrrl__hire, sqrrl__hire_team, sqrrl__log


def promote(mut sqrrl__world: sqrrl__World, e: EntityHandle[sqrrl__EmployeeTableState], new_title: String) -> EntityHandle[sqrrl__EmployeeTableState]:
    # Ordinary, hand-written Mojo -- not a @@-marked call at all -- returning
    # a plain, untracked EntityHandle to show it can still be retroactively
    # marked afterward, same as arrays_and_relations' own `hire`.
    sqrrl__world.Employee.set_title(e, new_title)
    return e


def main() raises:
    var sqrrl__world = sqrrl__init()
    try:
        var sqrrl__eng = sqrrl__make_department(sqrrl__world, "Engineering")
        var sqrrl__sales = sqrrl__make_department(sqrrl__world, "Sales")

        var sqrrl__alice_emp = sqrrl__hire(sqrrl__world, "Alice", "alice@example.com", "Engineer", 5, sqrrl__eng)
        var sqrrl__bob_emp = sqrrl__hire(sqrrl__world, "Bob", "bob@example.com", "Sales Rep", 2, sqrrl__sales)

        var sqrrl__alice = sqrrl__world.Person.create(name = "Alice", home = Address("Springfield"), job = sqrrl__alice_emp)
        var sqrrl__bob = sqrrl__world.Person.create(name = "Bob", home = Address("Shelbyville"), job = sqrrl__bob_emp)

        # Multi-hop chain: Person -> Employee -> Department.
        print("alice works in:", sqrrl__world.Department.get_name(sqrrl__world.Employee.get_dept(sqrrl__world.Person.get_job(sqrrl__alice))))

        # unique field's own for_<field> -- raises variant, returns a single
        # tracked entity directly (not a List).
        var sqrrl__found_by_email = sqrrl__world.Employee.for_email("bob@example.com")
        print("found by email, title:", sqrrl__world.Employee.get_title(sqrrl__found_by_email))

        # A bare (non-collection) relation field's for_<field> -- non-unique,
        # returns every matching entity as a tracked, indexable container,
        # writable element-by-element.
        var sqrrl__eng_team = sqrrl__world.Employee.for_dept(sqrrl__eng)
        print("eng team size (via for_dept):", len(sqrrl__eng_team))
        print("first member title before promotion:", sqrrl__world.Employee.get_title(sqrrl__eng_team[0]))
        sqrrl__world.Employee.set_title(sqrrl__eng_team[0], "Staff Engineer");
        print("first member title after write-through-index:", sqrrl__world.Employee.get_title(sqrrl__eng_team[0]))

        # A function returning a container of freshly-constructed entities.
        var names = List[String]()
        names.append("Carol")
        names.append("Dave")
        var sqrrl__sales_team = sqrrl__hire_team(sqrrl__world, names, "@example.com", 3, sqrrl__sales)
        print("sales team size (via hire_team):", len(sqrrl__sales_team))

        # ordered field: years_employed keeps a sorted index alongside the
        # usual per-id storage, giving range queries (greater_than/less_than/
        # at_least/at_most/between) a plain unique/multi field can't answer in
        # better than a full linear scan. Alice=5, Bob=2, Carol=3, Dave=4.
        print("more than 3 years:", len(sqrrl__world.Employee.for_years_employed_greater_than(3)))
        print("at least 3 years:", len(sqrrl__world.Employee.for_years_employed_at_least(3)))
        print("less than 3 years:", len(sqrrl__world.Employee.for_years_employed_less_than(3)))
        print("3 to 4 years inclusive:", len(sqrrl__world.Employee.for_years_employed_between(3, 4)))
        for sqrrl__e in  sqrrl__world.Employee.for_years_employed(3):
            print("exactly 3 years:", sqrrl__world.Employee.get_title(sqrrl__e))

        # Retroactive marking: a value from ordinary hand-written Mojo, marked
        # @@ after the fact via an explicit type annotation.
        var raw = promote(sqrrl__world, sqrrl__bob_emp, "Senior Sales Rep")
        var sqrrl__promoted_bob: EntityHandle[sqrrl__EmployeeTableState] = raw
        print("bob's new title (retroactively marked):", sqrrl__world.Employee.get_title(sqrrl__promoted_bob))

        # forwardonly field: a plain (non-relation) List[String] whose element
        # type isn't KeyElement-relevant at all -- just needs ForwardOnlyRel
        # storage since Rel/UniqueRel would require a hashable field type.
        var tags = List[String]()
        tags.append("fast-paced")
        tags.append("hybrid")
        sqrrl__world.Department.set_tags(sqrrl__eng, tags)
        var got_tags = sqrrl__world.Department.get_tags(sqrrl__eng)
        print("eng tags count (forwardonly field):", len(got_tags))

        # Writing through a hop chain, not just reading -- one hop (job), then
        # the terminal plain field (title) is the write target.
        sqrrl__world.Employee.set_title(sqrrl__world.Person.get_job(sqrrl__alice), "Junior Engineer");
        print("alice's job title after hop-chain write:", sqrrl__world.Employee.get_title(sqrrl__world.Person.get_job(sqrrl__alice)))

        # multi: a genuine many-to-many relation, declared on just Department's
        # own side (Project has no field pointing back at all -- there's no
        # need for one; MultiRel's own get_fwd/get_bwd already answer both
        # directions from here). add_to_<field>/remove_from_<field> mutate one
        # member in place; for_<field> is the reverse query -- "which departments
        # run this project" -- from a bare Project value, with no Department
        # field involved on that end either.
        var sqrrl__website = sqrrl__world.Project.create(name = "Website Revamp")
        var sqrrl__onboarding = sqrrl__world.Project.create(name = "Onboarding Redesign")
        _ = sqrrl__world.Department.add_to_projects(sqrrl__eng, sqrrl__website)
        _ = sqrrl__world.Department.add_to_projects(sqrrl__eng, sqrrl__onboarding)
        _ = sqrrl__world.Department.add_to_projects(sqrrl__sales, sqrrl__onboarding)
        print("eng project count:", len(sqrrl__world.Department.get_projects(sqrrl__eng)))
        print("departments running onboarding:", len(sqrrl__world.Department.for_projects(sqrrl__onboarding)))
        print("eng drops onboarding:", sqrrl__world.Department.remove_from_projects(sqrrl__eng, sqrrl__onboarding))
        print("departments running onboarding after drop:", len(sqrrl__world.Department.for_projects(sqrrl__onboarding)))

        # keepalive: AuditLog entities are created and their handles immediately
        # discarded (@@log doesn't return one) -- no local var, no relation
        # field anywhere pointing at them. Without `keepalive`, each one would
        # die the instant @@log returns. all() walks the table's own id
        # allocator directly, so it finds every entity still alive regardless
        # of what's keeping it that way -- here, purely `keepalive` itself.
        sqrrl__log(sqrrl__world, "started")
        sqrrl__log(sqrrl__world, "did a thing")
        sqrrl__log(sqrrl__world, "finished")
        print("audit log entries kept alive:", len(sqrrl__world.AuditLog.all()))
        for sqrrl__entry in  sqrrl__world.AuditLog.all():
            print("audit log entry:", sqrrl__world.AuditLog.get_message(sqrrl__entry))

        for entry2 in sqrrl__test(sqrrl__world):
            print("audit log entry:", sqrrl__world.AuditLog.get_message(entry2))

        for var sqrrl__entry3 in  sqrrl__test2(sqrrl__world):
            print("audit log entry:", sqrrl__world.AuditLog.get_message(sqrrl__entry3))

        for entry4 in sqrrl__test2(sqrrl__world).items():
            print("audit log entry:", sqrrl__world.AuditLog.get_message(entry4.key))


        print(
            "keep alive:",
            sqrrl__world.Person.get_name(sqrrl__alice), sqrrl__world.Person.get_name(sqrrl__bob), sqrrl__world.Department.get_name(sqrrl__eng), sqrrl__world.Department.get_name(sqrrl__sales),
            sqrrl__world.Employee.get_title(sqrrl__alice_emp), sqrrl__world.Employee.get_title(sqrrl__bob_emp), sqrrl__world.Employee.get_title(sqrrl__promoted_bob),
            sqrrl__world.Employee.get_title(sqrrl__sales_team[0]), sqrrl__world.Employee.get_title(sqrrl__sales_team[1]),
            sqrrl__world.Employee.get_title(sqrrl__found_by_email), sqrrl__world.Project.get_name(sqrrl__website), sqrrl__world.Project.get_name(sqrrl__onboarding),
        )
    finally:
        sqrrl__world.sqrrl__check_no_leaks()

def sqrrl__test(mut sqrrl__world: sqrrl__World) -> Set[EntityHandle[sqrrl__AuditLogTableState]]:
    return Set[EntityHandle[sqrrl__AuditLogTableState]]()

def sqrrl__test2(mut sqrrl__world: sqrrl__World) -> Dict[EntityHandle[sqrrl__AuditLogTableState], EntityHandle[sqrrl__EmployeeTableState]]:
    return Dict[EntityHandle[sqrrl__AuditLogTableState], EntityHandle[sqrrl__EmployeeTableState]]()
