from squirrel_runtime.entity import Table, EntityHandle, EntityInner, TableStateLike
from squirrel_runtime.rel import Rel, UniqueRel, ForwardOnlyRel, MultiRel, OrderedRel
from std.collections import Set
from std.os import abort
from sqrrl__world import sqrrl__init, sqrrl__World, sqrrl__world_from_json
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
from logic.factories import sqrrl__make_vendor, sqrrl__make_project, sqrrl__make_department, sqrrl__hire, sqrrl__hire_team, sqrrl__make_team, sqrrl__log
from squirrel_runtime.json import sqrrl__JsonScanner


def promote(mut sqrrl__world: sqrrl__World, e: EntityHandle[sqrrl__EmployeeTableState], new_title: String) -> EntityHandle[sqrrl__EmployeeTableState]:
    # Ordinary, hand-written Mojo -- not a @@-marked call -- to show a
    # value can still be retroactively marked afterward.
    sqrrl__world.Employee.set_title(e, new_title)
    return e


def main() raises:
    # `@@init_from_json(json)` is `@@init()`'s reload counterpart --
    # obtains the same shared `sqrrl__world` binding, but by reconstructing
    # it from a JSON dump instead of building an empty one. A real app
    # would pass in a previously-saved dump; an empty object bootstraps an
    # empty world exactly like `@@init()` would, just by going through the
    # JSON-parsing path for real instead of skipping it.
    var seed = String("{}");
    var sqrrl__scanner = sqrrl__JsonScanner(seed); var sqrrl__world = sqrrl__world_from_json(sqrrl__scanner);

    # ---- deep dependency chain: Vendor -> Project -> Department -> Employee -> Person -> Team ----
    var sqrrl__acme = sqrrl__make_vendor(sqrrl__world, "Acme Supplies");
    var sqrrl__globex = sqrrl__make_vendor(sqrrl__world, "Globex Corp");

    var sqrrl__website = sqrrl__make_project(sqrrl__world, "Website Revamp", 3, sqrrl__acme, 500000);
    var sqrrl__onboarding = sqrrl__make_project(sqrrl__world, "Onboarding Redesign", 1, sqrrl__globex, 250000);

    var sqrrl__eng = sqrrl__make_department(sqrrl__world, "Engineering");
    var sqrrl__sales = sqrrl__make_department(sqrrl__world, "Sales");

    _ = sqrrl__world.Department.add_to_projects(sqrrl__eng, sqrrl__website);
    _ = sqrrl__world.Department.add_to_projects(sqrrl__eng, sqrrl__onboarding);
    _ = sqrrl__world.Department.add_to_projects(sqrrl__sales, sqrrl__onboarding);
    print("eng project count:", len(sqrrl__world.Department.get_projects(sqrrl__eng)));
    print("departments running onboarding:", len(sqrrl__world.Department.for_projects(sqrrl__onboarding)));

    # Set-wrapped *ordinary* relation field (not `multi`) -- a whole Set
    # assigned/read at once, unlike `multi`'s one-member-at-a-time API.
    var sqrrl__eng_vendors = Set[EntityHandle[sqrrl__VendorTableState]]();
    sqrrl__eng_vendors.add(sqrrl__acme);
    sqrrl__eng_vendors.add(sqrrl__globex);
    sqrrl__world.Department.set_vendors(sqrrl__eng, sqrrl__eng_vendors);
    print("eng vendor count (Set-wrapped ordinary field):", len(sqrrl__world.Department.get_vendors(sqrrl__eng)));

    # `multi` on a *plain* (non-relation) field -- Set[String]-backed.
    _ = sqrrl__world.Department.add_to_skills(sqrrl__eng, "mojo");
    _ = sqrrl__world.Department.add_to_skills(sqrrl__eng, "distributed-systems");
    print("eng skills:", len(sqrrl__world.Department.get_skills(sqrrl__eng)));
    print("departments with mojo skill:", len(sqrrl__world.Department.for_skills("mojo")));

    var sqrrl__alice_emp = sqrrl__hire(sqrrl__world, "Alice", "alice@example.com", "Engineer", 5, sqrrl__eng);
    var sqrrl__bob_emp = sqrrl__hire(sqrrl__world, "Bob", "bob@example.com", "Sales Rep", 2, sqrrl__sales);

    var sqrrl__alice = sqrrl__world.Person.create(name = "Alice", home = Address("1 Elm St", "Springfield"), job = sqrrl__alice_emp);
    var sqrrl__bob = sqrrl__world.Person.create(name = "Bob", home = Address("2 Oak St", "Shelbyville"), job = sqrrl__bob_emp);

    # Multi-hop chain, four levels deep: Person -> Employee -> Department -> Project.
    print("alice works in:", sqrrl__world.Department.get_name(sqrrl__world.Employee.get_dept(sqrrl__world.Person.get_job(sqrrl__alice))));

    # unique field's own for_<field> -- raises variant.
    var sqrrl__found_by_email = sqrrl__world.Employee.for_email("bob@example.com");
    print("found by email, title:", sqrrl__world.Employee.get_title(sqrrl__found_by_email));

    var sqrrl__eng_team = sqrrl__world.Employee.for_dept(sqrrl__eng);
    print("eng team size (via for_dept):", len(sqrrl__eng_team));
    print("first member title before promotion:", sqrrl__world.Employee.get_title(sqrrl__eng_team[0]));
    sqrrl__world.Employee.set_title(sqrrl__eng_team[0], "Staff Engineer");
    print("first member title after write-through-index:", sqrrl__world.Employee.get_title(sqrrl__eng_team[0]));

    var names = List[String]();
    names.append("Carol");
    names.append("Dave");
    var sqrrl__sales_team = sqrrl__hire_team(sqrrl__world, names, "@example.com", 3, sqrrl__sales);
    print("sales team size (via hire_team):", len(sqrrl__sales_team));

    # ordered field on Employee.
    print("more than 3 years:", len(sqrrl__world.Employee.for_years_employed_greater_than(3)));
    print("at least 3 years:", len(sqrrl__world.Employee.for_years_employed_at_least(3)));
    print("less than 3 years:", len(sqrrl__world.Employee.for_years_employed_less_than(3)));
    print("3 to 4 years inclusive:", len(sqrrl__world.Employee.for_years_employed_between(3, 4)));

    # ordered field on Project too -- the same modifier on a completely
    # different struct's own numeric field.
    print("projects with priority >= 2:", len(sqrrl__world.Project.for_priority_at_least(2)));
    for sqrrl__p in  sqrrl__world.Project.for_priority_between(1, 3):
        print("project in priority range:", sqrrl__world.Project.get_name(sqrrl__p));

    var raw = promote(sqrrl__world, sqrrl__bob_emp, "Senior Sales Rep");
    var sqrrl__promoted_bob: EntityHandle[sqrrl__EmployeeTableState] = raw;
    print("bob's new title (retroactively marked):", sqrrl__world.Employee.get_title(sqrrl__promoted_bob));

    var tags = List[String]();
    tags.append("fast-paced");
    tags.append("hybrid");
    sqrrl__world.Department.set_tags(sqrrl__eng, tags);
    print("eng tags count (forwardonly field):", len(sqrrl__world.Department.get_tags(sqrrl__eng)));

    sqrrl__world.Employee.set_title(sqrrl__world.Person.get_job(sqrrl__alice), "Junior Engineer");
    print("alice's job title after hop-chain write:", sqrrl__world.Employee.get_title(sqrrl__world.Person.get_job(sqrrl__alice)));

    # A team: plain struct embedding a relation (`Assignment.@@person`),
    # an ordinary List-wrapped relation field, and an Optional-wrapped one.
    var sqrrl__platform_team = sqrrl__make_team(sqrrl__world, "Platform", sqrrl__alice, "Tech Lead");
    var members = List[EntityHandle[sqrrl__PersonTableState]]();
    members.append(sqrrl__alice);
    members.append(sqrrl__bob);
    sqrrl__world.Team.set_members(sqrrl__platform_team, members);
    print("platform team member count:", len(sqrrl__world.Team.get_members(sqrrl__platform_team)));
    print("platform team lead role:", sqrrl__world.Team.get_lead(sqrrl__platform_team).role);

    sqrrl__world.Team.set_advisor(sqrrl__platform_team, sqrrl__promoted_bob);
    if sqrrl__world.Team.get_advisor(sqrrl__platform_team):
        print("platform team advisor:", sqrrl__world.Employee.get_title(sqrrl__world.Team.get_advisor(sqrrl__platform_team).value()));

    # keepalive: AuditLog entities survive with no local var and no
    # relation field pointing at them, purely via `keepalive`.
    sqrrl__log(sqrrl__world, "started");
    sqrrl__log(sqrrl__world, "did a thing");
    sqrrl__log(sqrrl__world, "finished");
    print("audit log entries kept alive:", len(sqrrl__world.AuditLog.all()));
    for sqrrl__entry in  sqrrl__world.AuditLog.all():
        print("audit log entry:", sqrrl__world.AuditLog.get_message(sqrrl__entry));

    # ---- deep plain-struct nesting + generics, through Employee.profile ----
    var profile = sqrrl__world.Employee.get_profile(sqrrl__alice_emp);
    profile.contact.emails.append("alice@work.example.com");
    profile.scores["mojo"] = 97;
    profile.scores["systems"] = 88;
    profile.nicknames = List[String]();
    profile.nicknames.value().append("Ali");
    profile.rating = Box[UInt32](5);
    profile.coordinates = Pair[Int, Int](10, -3);
    sqrrl__world.Employee.set_profile(sqrrl__alice_emp, profile);

    var got_profile = sqrrl__world.Employee.get_profile(sqrrl__alice_emp);
    print("alice's city (deep nested plain struct):", got_profile.contact.home.city);
    print("alice's email count:", len(got_profile.contact.emails));
    print("alice's mojo score (Dict field):", got_profile.scores["mojo"]);
    print("alice's rating (generic Box[UInt32]):", got_profile.rating.value);
    print("alice's coordinates (generic Pair[Int, Int]):", got_profile.coordinates.first, got_profile.coordinates.second);
    print("alice's nickname count (Optional[List[String]]):", len(got_profile.nicknames.value()));

    # ---- per-entity JSON round trip ----
    # Project has no `unique` field, so reconstructing a second copy
    # alongside the still-live original is unremarkable.
    var project_json = sqrrl__world.Project.to_json(sqrrl__website);
    print("website as json:", project_json);
    var sc = sqrrl__JsonScanner(project_json);
    var sqrrl__rebuilt_website = sqrrl__world.Project.from_json(sqrrl__world.Vendor, sc);
    print("rebuilt website's name:", sqrrl__world.Project.get_name(sqrrl__rebuilt_website));
    print("rebuilt website's priority:", sqrrl__world.Project.get_priority(sqrrl__rebuilt_website));

    # Employee's own `unique email` still enforces its constraint through
    # `from_json`, exactly like `create` -- reconstructing alice's JSON
    # while the original @@alice_emp is still alive (it is: @@alice.@@job
    # holds it) raises the same `UniqueConstraintViolation` a duplicate
    # `create` would.
    var employee_json = sqrrl__world.Employee.to_json(sqrrl__alice_emp);
    print("alice as json:", employee_json);
    var sc2 = sqrrl__JsonScanner(employee_json);
    try:
        var sqrrl__rebuilt_alice = sqrrl__world.Employee.from_json(sqrrl__world.Department, sc2);
        print("ERROR: expected UniqueConstraintViolation, got", sqrrl__world.Employee.get_title(sqrrl__rebuilt_alice));
    except e:
        print("reconstructing alice while the original lives raised:", e);

    # ---- whole-world JSON round trip -- `sqrrl__world` itself, threaded
    # by hand, since to_json/sqrrl__world_from_json aren't @@-marked
    # constructs (see ADVANCED_FEATURES.md). ----
    var world_json = sqrrl__world.to_json();
    print("whole world byte length:", world_json.byte_length());
    var sc3 = sqrrl__JsonScanner(world_json);
    var reloaded = sqrrl__world_from_json(sc3);
    print("reloaded department count:", len(reloaded.Department.all()));
    print("reloaded employee count:", len(reloaded.Employee.all()));
    var reloaded_alice = reloaded.Employee.for_email("alice@example.com");
    print("reloaded alice's dept:", reloaded.Department.get_name(reloaded.Employee.get_dept(reloaded_alice)));
    print("reloaded alice's rating survived:", reloaded.Employee.get_profile(reloaded_alice).rating.value);
    print("reloaded audit log count:", len(reloaded.AuditLog.all()));

    print(
        "keep alive:",
        sqrrl__world.Person.get_name(sqrrl__alice), sqrrl__world.Person.get_name(sqrrl__bob), sqrrl__world.Department.get_name(sqrrl__eng), sqrrl__world.Department.get_name(sqrrl__sales),
        sqrrl__world.Employee.get_title(sqrrl__alice_emp), sqrrl__world.Employee.get_title(sqrrl__bob_emp), sqrrl__world.Employee.get_title(sqrrl__promoted_bob),
        sqrrl__world.Employee.get_title(sqrrl__sales_team[0]), sqrrl__world.Employee.get_title(sqrrl__sales_team[1]),
        sqrrl__world.Employee.get_title(sqrrl__found_by_email), sqrrl__world.Project.get_name(sqrrl__website), sqrrl__world.Project.get_name(sqrrl__onboarding),
        sqrrl__world.Team.get_name(sqrrl__platform_team),
    );
