# dataclasses extended

from dataclasses import dataclass, field, asdict, astuple, replace, fields

# Basic dataclass with defaults
@dataclass
class Config:
    host: str = 'localhost'
    port: int = 8080
    debug: bool = False

c = Config()
print(c.host)                                      # localhost
print(c.port)                                      # 8080
print(c.debug)                                     # False

c2 = Config('example.com', 443, True)
print(c2.host)                                     # example.com
print(c2.port)                                     # 443

# field() with default_factory
@dataclass
class Container:
    items: list = field(default_factory=list)
    tags: set = field(default_factory=set)

con1 = Container()
con2 = Container()
con1.items.append(1)
print(con1.items)                                  # [1]
print(con2.items)                                  # [] (independent)

# asdict
@dataclass
class Point:
    x: float
    y: float

p = Point(1.0, 2.0)
d = asdict(p)
print(d)                                           # {'x': 1.0, 'y': 2.0}

# astuple
t = astuple(p)
print(t)                                           # (1.0, 2.0)

# replace (like copy with modifications)
p2 = replace(p, x=10.0)
print(p2.x, p2.y)                                  # 10.0 2.0
print(p.x)                                         # 1.0 (original unchanged)

# fields()
fs = fields(Point)
print([f.name for f in fs])                        # ['x', 'y']

# frozen dataclass
@dataclass(frozen=True)
class ImmutablePoint:
    x: float
    y: float

ip = ImmutablePoint(3.0, 4.0)
print(ip.x)                                        # 3.0
try:
    ip.x = 5.0
except Exception:
    print('Cannot modify frozen')                  # Cannot modify frozen

print('done')
