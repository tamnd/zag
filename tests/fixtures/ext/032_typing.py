from typing import Optional, Union, List, Dict, Tuple, Any, Callable
from typing import TypeVar, Generic, cast, get_type_hints
from typing import NamedTuple, TypedDict

# Basic type annotations (runtime behavior)
def greet(name: str) -> str:
    return f'Hello, {name}'

print(greet('Alice'))                                  # Hello, Alice

# Optional
def maybe_int(s: str) -> Optional[int]:
    try:
        return int(s)
    except ValueError:
        return None

print(maybe_int('42'))                                 # 42
print(maybe_int('abc'))                                # None

# Union
def process(x: Union[int, str]) -> str:
    return str(x)

print(process(42))                                     # 42
print(process('hello'))                                # hello

# NamedTuple
class Point(NamedTuple):
    x: float
    y: float
    label: str = 'origin'

p = Point(1.0, 2.0)
print(p.x)                                             # 1.0
print(p.label)                                         # origin
print(p[0])                                            # 1.0

# TypeVar
T = TypeVar('T')
def identity(x: T) -> T:
    return x

print(identity(42))                                    # 42
print(identity('hi'))                                  # hi

# cast (no-op at runtime)
x = cast(int, 'hello')
print(x)                                               # hello

print('done')
