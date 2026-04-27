from enum import Enum, IntEnum, Flag, auto

class Color(Enum):
    RED = 1
    GREEN = 2
    BLUE = 3

print(Color.RED)                                       # Color.RED
print(Color.RED.name)                                  # RED
print(Color.RED.value)                                 # 1
print(Color(2))                                        # Color.GREEN
print(list(Color))                                     # [<Color.RED: 1>, <Color.GREEN: 2>, <Color.BLUE: 3>]
print(Color.RED == Color.RED)                          # True
print(Color.RED == Color.GREEN)                        # False

# IntEnum
class Status(IntEnum):
    PENDING = 0
    ACTIVE = 1
    DONE = 2

print(Status.ACTIVE)                                   # Status.ACTIVE
print(Status.ACTIVE == 1)                              # True
print(Status.ACTIVE > Status.PENDING)                  # True

# auto()
class Direction(Enum):
    NORTH = auto()
    SOUTH = auto()
    EAST = auto()
    WEST = auto()

print(Direction.NORTH.value)                           # 1
print(Direction.SOUTH.value)                           # 2

# Flag
class Permission(Flag):
    READ = auto()
    WRITE = auto()
    EXEC = auto()

p = Permission.READ | Permission.WRITE
print(Permission.READ in p)                            # True
print(Permission.EXEC in p)                            # False

print('done')
