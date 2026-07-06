from std.collections import Set
from squirrel_runtime.entity import EntityHandle
from squirrel_runtime.json import sqrrl__JsonScanner, sqrrl__escape_json_string, sqrrl__JsonSerializable, list_to_json, list_from_json, set_to_json, set_from_json, optional_to_json, optional_from_json, dict_to_json, dict_from_json
from schema.person import sqrrl__PersonTableState, sqrrl__PersonTable
from schema.department import sqrrl__DepartmentTableState, sqrrl__DepartmentTable
from schema.employee import sqrrl__EmployeeTableState, sqrrl__EmployeeTable
from schema.address import Address


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
    else:
        raise Error("sqrrl__from_json: unsupported type -- structs use their own generated from_json")


def sqrrl__Address_from_json(mut sc: sqrrl__JsonScanner) raises -> Address:
    var sqrrl__parsed_city: Optional[String] = None
    sc.expect_byte(UInt8(ord("{")))
    if not sc.try_consume_byte(UInt8(ord("}"))):
        while True:
            var sqrrl__key = sc.parse_json_string()
            sc.expect_byte(UInt8(ord(":")))
            if sqrrl__key == "city":
                    sqrrl__parsed_city = sqrrl__from_json[String](sc)
            if sc.try_consume_byte(UInt8(ord(","))):
                continue
            sc.expect_byte(UInt8(ord("}")))
            break
    return Address(sqrrl__parsed_city.take())
