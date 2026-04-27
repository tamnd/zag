# enum module

from enum import Enum, IntEnum, auto

# Basic Enum
class Color(Enum):
    RED = 1
    GREEN = 2
    BLUE = 3

print(Color.RED)                                    # Color.RED
print(Color.RED.name)                               # RED
print(Color.RED.value)                              # 1
print(Color(2))                                     # Color.GREEN
print(Color['BLUE'])                                # Color.BLUE

# Membership test
print(Color.RED in Color)                           # True

# Iteration
for c in Color:
    print(c.name, c.value)
# RED 1
# GREEN 2
# BLUE 3

# Comparison
print(Color.RED == Color.RED)                       # True
print(Color.RED == Color.GREEN)                     # False
print(Color.RED is Color.RED)                       # True

# IntEnum (members are also ints)
class Priority(IntEnum):
    LOW = 1
    MEDIUM = 2
    HIGH = 3

print(Priority.HIGH)                                # Priority.HIGH
print(Priority.HIGH.value)                          # 3
print(Priority.HIGH > Priority.LOW)                 # True

# auto()
class Direction(Enum):
    NORTH = auto()
    SOUTH = auto()
    EAST = auto()
    WEST = auto()

print(Direction.NORTH.value)                        # 1
print(Direction.SOUTH.value)                        # 2
print(Direction.EAST.value)                         # 3
print(Direction.WEST.value)                         # 4

# list of values
print([c.value for c in Color])                    # [1, 2, 3]

# __members__
print(list(Color.__members__.keys()))              # ['RED', 'GREEN', 'BLUE']

print('done')
