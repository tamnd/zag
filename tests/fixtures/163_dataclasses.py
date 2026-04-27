import dataclasses

@dataclasses.dataclass
class Point:
    x: int
    y: int

p = Point(1, 2)
print(p.x, p.y)                                            # 1 2
print(repr(p))                                             # Point(x=1, y=2)
print(p == Point(1, 2))                                    # True
print(p == Point(1, 3))                                    # False

@dataclasses.dataclass
class Named:
    name: str
    value: int = 0

n = Named('hello')
print(n.name, n.value)                                     # hello 0
n2 = Named('world', 42)
print(n2.name, n2.value)                                   # world 42

# fields()
fs = dataclasses.fields(p)
print(len(fs))                                             # 2
print(fs[0].name)                                          # x
print(fs[1].name)                                          # y

# asdict
d = dataclasses.asdict(p)
print(d)                                                   # {'x': 1, 'y': 2}

# astuple
t = dataclasses.astuple(p)
print(t)                                                   # (1, 2)

# is_dataclass
print(dataclasses.is_dataclass(p))                         # True
print(dataclasses.is_dataclass(Point))                     # True
print(dataclasses.is_dataclass(42))                        # False

# replace
p3 = dataclasses.replace(p, y=99)
print(p3)                                                  # Point(x=1, y=99)

# frozen
@dataclasses.dataclass(frozen=True)
class Frozen:
    a: int
    b: str

f = Frozen(1, 'hi')
print(f.a, f.b)                                            # 1 hi
try:
    f.a = 2
except Exception:
    print('immutable')                                     # immutable

print('done')
