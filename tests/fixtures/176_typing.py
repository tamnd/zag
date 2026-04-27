from typing import TypeVar, cast, TYPE_CHECKING, NamedTuple, TypedDict

# TYPE_CHECKING is False at runtime
print(TYPE_CHECKING)

# cast just returns the value unchanged
print(cast(int, 42))
print(cast(str, 'hello'))

# TypeVar keeps the name
T = TypeVar('T')
print(T.__name__)

# NamedTuple subclass
class Point(NamedTuple):
    x: int
    y: int = 0

p = Point(3, 4)
print(p.x)
print(p.y)
print(p[0])
print(p[1])
print(len(p))

# NamedTuple with default value
p2 = Point(x=5)
print(p2.x)
print(p2.y)

# TypedDict creates a dict-like class
Movie = TypedDict('Movie', {'name': str, 'year': int})
m = Movie(name='Blade Runner', year=1982)
print(m['name'])
print(m['year'])
