from squirrel_runtime.entity import Table, EntityHandle, EntityInner, TableStateLike
from squirrel_runtime.rel import Rel, UniqueRel, ForwardOnlyRel, MultiRel, OrderedRel
from std.collections import Set
from std.os import abort
from sqrrl__Squirrel import sqrrl__init, sqrrl__Squirrel


from logic.factories import sqrrl__make_department, sqrrl__hire, sqrrl__make_person, sqrrl__make_team
from logic.reports import sqrrl__print_person

def main():
    var sqrrl__world = sqrrl__init();
    var sqrrl__dept = sqrrl__make_department(sqrrl__world, "Engineering");
    var sqrrl__emp = sqrrl__hire(sqrrl__world, "Engineer", sqrrl__dept);
    var sqrrl__alice = sqrrl__make_person(sqrrl__world, "alice", sqrrl__emp);
    sqrrl__print_person(sqrrl__world, sqrrl__alice);

    var sqrrl__team = sqrrl__make_team(sqrrl__world, ["bob", "carol"], sqrrl__emp);
    print("team size:", len(sqrrl__team));
    sqrrl__print_person(sqrrl__world, sqrrl__team[0]);
    sqrrl__print_person(sqrrl__world, sqrrl__team[1]);
