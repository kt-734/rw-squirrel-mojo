from std.collections import Set
from squirrel_runtime.entity import EntityHandle
from squirrel_runtime.json import sqrrl__JsonScanner, sqrrl__escape_json_string, sqrrl__JsonSerializable, list_to_json, list_from_json, set_to_json, set_from_json, optional_to_json, optional_from_json, dict_to_json, dict_from_json
from schema.person import sqrrl__PersonTableState, sqrrl__PersonTable
from schema.team import sqrrl__TeamTableState, sqrrl__TeamTable
from schema.department import sqrrl__DepartmentTableState, sqrrl__DepartmentTable
from schema.project import sqrrl__ProjectTableState, sqrrl__ProjectTable
from schema.vendor import sqrrl__VendorTableState, sqrrl__VendorTable
from schema.audit_log import sqrrl__AuditLogTableState, sqrrl__AuditLogTable
from schema.employee import sqrrl__EmployeeTableState, sqrrl__EmployeeTable
from schema.box import Box
from schema.address import Address
from schema.pair import Pair
from schema.contact_info import ContactInfo
from schema.money import Money
from schema.assignment import Assignment
from schema.profile import Profile


def sqrrl__to_json[T: AnyType](value: T) -> String:
    comptime if T == String:
        return sqrrl__escape_json_string(rebind[String](value))
    elif T == Int:
        return String(rebind[Int](value))
    elif T == UInt32:
        return String(rebind[UInt32](value))
    elif T == Int64:
        return String(rebind[Int64](value))
    elif T == UInt64:
        return String(rebind[UInt64](value))
    elif T == Float64:
        return String(rebind[Float64](value))
    elif T == Bool:
        return "true" if rebind[Bool](value) else "false"
    elif T == List[EntityHandle[sqrrl__PersonTableState]]:
        return list_to_json(rebind[List[EntityHandle[sqrrl__PersonTableState]]](value).copy())
    elif T == Optional[EntityHandle[sqrrl__EmployeeTableState]]:
        return optional_to_json(rebind[Optional[EntityHandle[sqrrl__EmployeeTableState]]](value).copy())
    elif T == List[String]:
        return list_to_json(rebind[List[String]](value).copy())
    elif T == Set[EntityHandle[sqrrl__ProjectTableState]]:
        return set_to_json(rebind[Set[EntityHandle[sqrrl__ProjectTableState]]](value).copy())
    elif T == Set[EntityHandle[sqrrl__VendorTableState]]:
        return set_to_json(rebind[Set[EntityHandle[sqrrl__VendorTableState]]](value).copy())
    elif T == Set[String]:
        return set_to_json(rebind[Set[String]](value).copy())
    elif T == Optional[List[String]]:
        return optional_to_json(rebind[Optional[List[String]]](value).copy())
    elif T == Dict[String, Int]:
        return dict_to_json(rebind[Dict[String, Int]](value).copy())
    elif T == List[Address]:
        return list_to_json(rebind[List[Address]](value).copy())
    elif T == List[Box[UInt32]]:
        return list_to_json(rebind[List[Box[UInt32]]](value).copy())
    elif conforms_to(T, sqrrl__JsonSerializable):
        return value.sqrrl__to_json()
    else:
        comptime r = reflect[T]
        comptime names = r.field_names()
        comptime ts = r.field_types()
        var p = UnsafePointer(to=value).bitcast[UInt8]()
        var out = String("{")
        comptime for i in range(r.field_count()):
            comptime Ti = ts[i]
            comptime off = r.field_offset[index=i]()
            var field_ptr = (p + off).bitcast[Ti]()
            if i > 0:
                out += ","
            out += "\"" + String(names[i]) + "\":" + sqrrl__to_json(field_ptr[])
        out += "}"
        return out^


def sqrrl__from_json[T: Copyable & ImplicitlyDeletable](mut sc: sqrrl__JsonScanner) raises -> T:
    comptime if T == String:
        var v = sc.parse_json_string()
        return rebind[T](v^).copy()
    elif T == Int:
        var v = sc.parse_json_int()
        return rebind[T](v).copy()
    elif T == UInt32:
        var v = UInt32(sc.parse_json_int())
        return rebind[T](v).copy()
    elif T == Int64:
        var v = Int64(sc.parse_json_int())
        return rebind[T](v).copy()
    elif T == UInt64:
        var v = UInt64(sc.parse_json_int())
        return rebind[T](v).copy()
    elif T == Float64:
        var v = sc.parse_json_float()
        return rebind[T](v).copy()
    elif T == Bool:
        var v = sc.parse_json_bool()
        return rebind[T](v).copy()
    elif T == List[String]:
        return rebind[T](list_from_json[String](sc)).copy()
    elif T == Set[String]:
        return rebind[T](set_from_json[String](sc)).copy()
    elif T == Optional[List[String]]:
        return rebind[T](optional_from_json[List[String]](sc)).copy()
    elif T == Dict[String, Int]:
        return rebind[T](dict_from_json[String, Int](sc)).copy()
    elif T == List[Address]:
        return rebind[T](list_from_json[Address](sc)).copy()
    elif T == List[Box[UInt32]]:
        return rebind[T](list_from_json[Box[UInt32]](sc)).copy()
    elif T == Address:
        return rebind[T](sqrrl__Address_from_json(sc)).copy()
    elif T == Box[UInt32]:
        return rebind[T](sqrrl__Box_from_json[UInt32](sc)).copy()
    else:
        raise Error("sqrrl__from_json: unsupported type -- structs use their own generated from_json")


def sqrrl__Box_from_json[T: Copyable & ImplicitlyDeletable](mut sc: sqrrl__JsonScanner) raises -> Box[T]:
    var sqrrl__parsed_value: Optional[T] = None
    sc.expect_byte(UInt8(ord("{")))
    if not sc.try_consume_byte(UInt8(ord("}"))):
        while True:
            var sqrrl__key = sc.parse_json_string()
            sc.expect_byte(UInt8(ord(":")))
            if sqrrl__key == "value":
                    sqrrl__parsed_value = sqrrl__from_json[T](sc)
            if sc.try_consume_byte(UInt8(ord(","))):
                continue
            sc.expect_byte(UInt8(ord("}")))
            break
    return Box[T](sqrrl__parsed_value.take())


def sqrrl__Address_from_json(mut sc: sqrrl__JsonScanner) raises -> Address:
    var sqrrl__parsed_street: Optional[String] = None
    var sqrrl__parsed_city: Optional[String] = None
    sc.expect_byte(UInt8(ord("{")))
    if not sc.try_consume_byte(UInt8(ord("}"))):
        while True:
            var sqrrl__key = sc.parse_json_string()
            sc.expect_byte(UInt8(ord(":")))
            if sqrrl__key == "street":
                    sqrrl__parsed_street = sqrrl__from_json[String](sc)
            elif sqrrl__key == "city":
                    sqrrl__parsed_city = sqrrl__from_json[String](sc)
            if sc.try_consume_byte(UInt8(ord(","))):
                continue
            sc.expect_byte(UInt8(ord("}")))
            break
    return Address(sqrrl__parsed_street.take(), sqrrl__parsed_city.take())


def sqrrl__Pair_from_json[A: Copyable & ImplicitlyDeletable, B: Copyable & ImplicitlyDeletable](mut sc: sqrrl__JsonScanner) raises -> Pair[A, B]:
    var sqrrl__parsed_first: Optional[A] = None
    var sqrrl__parsed_second: Optional[B] = None
    sc.expect_byte(UInt8(ord("{")))
    if not sc.try_consume_byte(UInt8(ord("}"))):
        while True:
            var sqrrl__key = sc.parse_json_string()
            sc.expect_byte(UInt8(ord(":")))
            if sqrrl__key == "first":
                    sqrrl__parsed_first = sqrrl__from_json[A](sc)
            elif sqrrl__key == "second":
                    sqrrl__parsed_second = sqrrl__from_json[B](sc)
            if sc.try_consume_byte(UInt8(ord(","))):
                continue
            sc.expect_byte(UInt8(ord("}")))
            break
    return Pair[A, B](sqrrl__parsed_first.take(), sqrrl__parsed_second.take())


def sqrrl__ContactInfo_from_json(mut sc: sqrrl__JsonScanner) raises -> ContactInfo:
    var sqrrl__parsed_home: Optional[Address] = None
    var sqrrl__parsed_emails: Optional[List[String]] = None
    sc.expect_byte(UInt8(ord("{")))
    if not sc.try_consume_byte(UInt8(ord("}"))):
        while True:
            var sqrrl__key = sc.parse_json_string()
            sc.expect_byte(UInt8(ord(":")))
            if sqrrl__key == "home":
                    sqrrl__parsed_home = sqrrl__Address_from_json(sc)
            elif sqrrl__key == "emails":
                    sqrrl__parsed_emails = sqrrl__from_json[List[String]](sc)
            if sc.try_consume_byte(UInt8(ord(","))):
                continue
            sc.expect_byte(UInt8(ord("}")))
            break
    return ContactInfo(sqrrl__parsed_home.take(), sqrrl__parsed_emails.take())


def sqrrl__Assignment_from_json(mut sqrrl__tbl_Person: sqrrl__PersonTable, mut sc: sqrrl__JsonScanner) raises -> Assignment:
    var sqrrl__parsed_person: Optional[EntityHandle[sqrrl__PersonTableState]] = None
    var sqrrl__parsed_role: Optional[String] = None
    sc.expect_byte(UInt8(ord("{")))
    if not sc.try_consume_byte(UInt8(ord("}"))):
        while True:
            var sqrrl__key = sc.parse_json_string()
            sc.expect_byte(UInt8(ord(":")))
            if sqrrl__key == "person":
                    sqrrl__parsed_person = sqrrl__tbl_Person.table.handle_for(UInt32(sc.parse_json_int()))
            elif sqrrl__key == "role":
                    sqrrl__parsed_role = sqrrl__from_json[String](sc)
            if sc.try_consume_byte(UInt8(ord(","))):
                continue
            sc.expect_byte(UInt8(ord("}")))
            break
    return Assignment(sqrrl__parsed_person.take(), sqrrl__parsed_role.take())


def sqrrl__Profile_from_json(mut sc: sqrrl__JsonScanner) raises -> Profile:
    var sqrrl__parsed_contact: Optional[ContactInfo] = None
    var sqrrl__parsed_nicknames: Optional[Optional[List[String]]] = None
    var sqrrl__parsed_scores: Optional[Dict[String, Int]] = None
    var sqrrl__parsed_rating: Optional[Box[UInt32]] = None
    var sqrrl__parsed_coordinates: Optional[Pair[Int, Int]] = None
    var sqrrl__parsed_past_addresses: Optional[List[Address]] = None
    var sqrrl__parsed_boxed_ratings: Optional[List[Box[UInt32]]] = None
    sc.expect_byte(UInt8(ord("{")))
    if not sc.try_consume_byte(UInt8(ord("}"))):
        while True:
            var sqrrl__key = sc.parse_json_string()
            sc.expect_byte(UInt8(ord(":")))
            if sqrrl__key == "contact":
                    sqrrl__parsed_contact = sqrrl__ContactInfo_from_json(sc)
            elif sqrrl__key == "nicknames":
                    sqrrl__parsed_nicknames = sqrrl__from_json[Optional[List[String]]](sc)
            elif sqrrl__key == "scores":
                    sqrrl__parsed_scores = sqrrl__from_json[Dict[String, Int]](sc)
            elif sqrrl__key == "rating":
                    sqrrl__parsed_rating = sqrrl__Box_from_json[UInt32](sc)
            elif sqrrl__key == "coordinates":
                    sqrrl__parsed_coordinates = sqrrl__Pair_from_json[Int, Int](sc)
            elif sqrrl__key == "past_addresses":
                    sqrrl__parsed_past_addresses = sqrrl__from_json[List[Address]](sc)
            elif sqrrl__key == "boxed_ratings":
                    sqrrl__parsed_boxed_ratings = sqrrl__from_json[List[Box[UInt32]]](sc)
            if sc.try_consume_byte(UInt8(ord(","))):
                continue
            sc.expect_byte(UInt8(ord("}")))
            break
    return Profile(sqrrl__parsed_contact.take(), sqrrl__parsed_nicknames.take(), sqrrl__parsed_scores.take(), sqrrl__parsed_rating.take(), sqrrl__parsed_coordinates.take(), sqrrl__parsed_past_addresses.take(), sqrrl__parsed_boxed_ratings.take())


def sqrrl__Money_from_json(mut sc: sqrrl__JsonScanner) raises -> Money:
    var sqrrl__parsed_cents: Optional[Int64] = None
    sc.expect_byte(UInt8(ord("{")))
    if not sc.try_consume_byte(UInt8(ord("}"))):
        while True:
            var sqrrl__key = sc.parse_json_string()
            sc.expect_byte(UInt8(ord(":")))
            if sqrrl__key == "cents":
                    sqrrl__parsed_cents = sqrrl__from_json[Int64](sc)
            if sc.try_consume_byte(UInt8(ord(","))):
                continue
            sc.expect_byte(UInt8(ord("}")))
            break
    return Money(sqrrl__parsed_cents.take())
