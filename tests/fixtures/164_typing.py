from typing import TypeVar, cast, TYPE_CHECKING, NamedTuple, TypedDict
from typing import Optional, Union, List, Dict, Tuple, Set, Any

# TypeVar
T = TypeVar('T')
print(T.__name__)                                          # T

# cast is a no-op at runtime
x = cast(int, 'hello')
print(x)                                                   # hello

# TYPE_CHECKING is False at runtime
print(TYPE_CHECKING)                                       # False

# NamedTuple subclass
class Point(NamedTuple):
    x: int
    y: int = 0

p = Point(1, 2)
print(p.x, p.y)                                           # 1 2
print(p[0], p[1])                                         # 1 2
print(isinstance(p, tuple))                               # True
print(repr(p))                                            # Point(x=1, y=2)

p2 = Point(3)
print(p2.x, p2.y)                                         # 3 0

# TypedDict (runtime: just a dict subclass)
Movie = TypedDict('Movie', {'name': str, 'year': int})
m = Movie(name='test', year=2020)
print(m['name'], m['year'])                               # test 2020
print(isinstance(m, dict))                                 # True

# Optional / Union work as subscriptable
o = Optional[int]
print(o is not None)                                      # True
u = Union[int, str]
print(u is not None)                                      # True

# Any is a special form
print(Any is not None)                                     # True

print('done')
