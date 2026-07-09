from std.sys import argv

from squirrel_compiler.driver import convert_directory


def main() raises:
    var args = argv()
    if len(args) < 2:
        print("Usage:", args[0], "<directory>")
        raise Error("MissingArgument")

    convert_directory(args[1])
