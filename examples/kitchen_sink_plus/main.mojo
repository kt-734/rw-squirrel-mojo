from squirrel_runtime.entity import Table, EntityHandle, EntityInner, TableStateLike
from squirrel_runtime.rel import Rel, UniqueRel, ForwardOnlyRel, MultiRel, OrderedRel
from std.collections import Set
from std.os import abort
from sqrrl__world import sqrrl__init, sqrrl__World, sqrrl__world_from_json, sqrrl__init_from_json
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


def sqrrl__promote(mut sqrrl__world: sqrrl__World, sqrrl__e: EntityHandle[sqrrl__EmployeeTableState], new_title: String) -> EntityHandle[sqrrl__EmployeeTableState]:
    sqrrl__world.Employee.set_title(sqrrl__e, new_title);
    return sqrrl__e;


def main() raises:
    # `@@declare()` brings `sqrrl__world` into scope, uninitialized --
    # required once, before any `@@init()`/`@@start_init_from_json(...)`
    # call, specifically so a script *could* choose between them
    # conditionally (`if restoring: @@start_init_from_json(dump); else:
    # @@init();`) with Mojo's own definite-initialization checking
    # catching a branch that forgot to initialize it, rather than a
    # hand-rolled control-flow analysis in this compiler.
    var sqrrl__world = sqrrl__init();
    # `@@start_init_from_json(json)` is `@@init()`'s reload counterpart --
    # obtains the same shared `sqrrl__world` binding, but by reconstructing
    # it from a JSON dump instead of building an empty one. A real app
    # would pass in a previously-saved dump; an empty object bootstraps an
    # empty world exactly like `@@init()` would, just by going through the
    # JSON-parsing path for real instead of skipping it.
    var seed = String("{}");
    sqrrl__world.sqrrl__check_no_leaks(); sqrrl__world = sqrrl__init_from_json(seed);
    # Nothing temporary to drop yet (`seed` is an empty world), but
    # `@@finalize_init_from_json()` is valid right away regardless --
    # a no-op here, exercised for real below on the whole-world reload.
    sqrrl__world.sqrrl__finalize_temp_keep_alives();

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

    var sqrrl__promoted_bob = sqrrl__promote(sqrrl__world, sqrrl__bob_emp, "Senior Sales Rep");
    print("bob's new title:", sqrrl__world.Employee.get_title(sqrrl__promoted_bob));

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
    # A container wrapping a bare, non-generic plain struct, and one
    # wrapping a generic plain struct's own instantiation -- both used to
    # fail from_json the moment they round-tripped through JSON (no
    # sqrrl__from_json[T] dispatch branch existed for the element type),
    # since list_from_json[X]'s own recursion into sqrrl__from_json[X] has
    # no way to special-case X at codegen time.
    profile.past_addresses.append(Address("10 Birch Rd", "Capital City"));
    profile.past_addresses.append(Address("22 Cedar Ln", "Ogdenville"));
    profile.boxed_ratings.append(Box[UInt32](3));
    profile.boxed_ratings.append(Box[UInt32](4));
    sqrrl__world.Employee.set_profile(sqrrl__alice_emp, profile);

    var got_profile = sqrrl__world.Employee.get_profile(sqrrl__alice_emp);
    print("alice's city (deep nested plain struct):", got_profile.contact.home.city);
    print("alice's email count:", len(got_profile.contact.emails));
    print("alice's mojo score (Dict field):", got_profile.scores["mojo"]);
    print("alice's rating (generic Box[UInt32]):", got_profile.rating.value);
    print("alice's coordinates (generic Pair[Int, Int]):", got_profile.coordinates.first, got_profile.coordinates.second);
    print("alice's nickname count (Optional[List[String]]):", len(got_profile.nicknames.value()));
    print("alice's past address count (List[Address]):", len(got_profile.past_addresses));
    print("alice's first past address city:", got_profile.past_addresses[0].city);
    print("alice's boxed rating count (List[Box[UInt32]]):", len(got_profile.boxed_ratings));
    print("alice's first boxed rating:", got_profile.boxed_ratings[0].value);

    # ---- per-entity JSON round trip ----
    # ---- whole-world JSON round trip, reusing `sqrrl__world` itself --
    # the dump has to happen *before* every entity built above has its
    # actual last mention (the "keep alive" print just below): Mojo's own
    # ASAP destruction drops a local var right after its last textual use,
    # regardless of what unrelated statements come later in the function,
    # so `sqrrl__world.to_json()` called *after* that print would see an
    # empty world -- confirmed empirically (every count read back as 0
    # until this was reordered). Once the dump is taken and "keep alive"
    # has run, nothing is left referencing the current world, so
    # `@@start_init_from_json(...)` can safely replace it in place (see
    # `sqrrl__check_no_leaks`/`@@declare()`'s own doc comments) -- no need
    # to hand-thread a second, independent `sqrrl__World` the way
    # ADVANCED_FEATURES.md's escape hatch would. `sqrrl__world.to_json()`
    # is still the one unavoidably `sqrrl__`-prefixed call here -- there's
    # no `@@`-marked sugar for "dump the current world," only for the
    # reload half.
    var world_json = sqrrl__world.to_json();
    print("whole world byte length:", world_json.byte_length());

    print(
        "keep alive:",
        sqrrl__world.Person.get_name(sqrrl__alice), sqrrl__world.Person.get_name(sqrrl__bob), sqrrl__world.Department.get_name(sqrrl__eng), sqrrl__world.Department.get_name(sqrrl__sales),
        sqrrl__world.Employee.get_title(sqrrl__alice_emp), sqrrl__world.Employee.get_title(sqrrl__bob_emp), sqrrl__world.Employee.get_title(sqrrl__promoted_bob),
        sqrrl__world.Employee.get_title(sqrrl__sales_team[0]), sqrrl__world.Employee.get_title(sqrrl__sales_team[1]),
        sqrrl__world.Employee.get_title(sqrrl__found_by_email), sqrrl__world.Project.get_name(sqrrl__website), sqrrl__world.Project.get_name(sqrrl__onboarding),
        sqrrl__world.Team.get_name(sqrrl__platform_team),
    );

    sqrrl__world.sqrrl__check_no_leaks(); sqrrl__world = sqrrl__init_from_json(world_json);
    print("reloaded department count:", len(sqrrl__world.Department.all()));
    print("reloaded employee count:", len(sqrrl__world.Employee.all()));
    var sqrrl__reloaded_alice = sqrrl__world.Employee.for_email("alice@example.com");
    print("reloaded alice's dept:", sqrrl__world.Department.get_name(sqrrl__world.Employee.get_dept(sqrrl__reloaded_alice)));
    print("reloaded alice's rating survived:", sqrrl__world.Employee.get_profile(sqrrl__reloaded_alice).rating.value);
    print("reloaded audit log count:", len(sqrrl__world.AuditLog.all()));

    # `@@reloaded_alice` is a real, independently-held handle now --
    # everything else `@@start_init_from_json(...)` only retained
    # *temporarily* (`TempKeepAlives`, see README's "JSON serialization"
    # section) can be dropped in one shot via `@@finalize_init_from_json()`.
    # Department count drops from 2 to 1 -- `sales` (Bob/Carol/Dave's own
    # department, nothing here still references) goes with the drop; `eng`
    # survives, kept alive transitively through `@@reloaded_alice`'s own
    # `dept` relation field, since she's referenced again below.
    print("reloaded department count before finalize:", len(sqrrl__world.Department.all()));
    sqrrl__world.sqrrl__finalize_temp_keep_alives();
    print("reloaded department count after finalize:", len(sqrrl__world.Department.all()));
    print("reloaded alice's title survives finalize:", sqrrl__world.Employee.get_title(sqrrl__reloaded_alice));
