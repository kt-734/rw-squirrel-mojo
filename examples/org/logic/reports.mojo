from squirrel_runtime.entity import Table, EntityHandle, EntityInner, TableStateLike
from squirrel_runtime.rel import Rel, UniqueRel, ForwardOnlyRel, MultiRel, OrderedRel
from std.collections import Set
from std.os import abort
from sqrrl__world import sqrrl__init, sqrrl__World, sqrrl__world_from_json, sqrrl__init_from_json
from schema.person import sqrrl__PersonTableState


def sqrrl__print_person(mut sqrrl__world: sqrrl__World, sqrrl__p: EntityHandle[sqrrl__PersonTableState]):
    print(sqrrl__world.Person.get_name(sqrrl__p), "lives in", sqrrl__world.Person.get_home(sqrrl__p).city)
    print("  job:", sqrrl__world.Employee.get_title(sqrrl__world.Person.get_job(sqrrl__p)), "in", sqrrl__world.Department.get_name(sqrrl__world.Employee.get_dept(sqrrl__world.Person.get_job(sqrrl__p))))
