from dataclasses import dataclass, field, asdict, astuple, replace

@dataclass
class Point:
    x: float
    y: float = 0.0

p = Point(1.0, 2.0)
print(p.x)                                             # 1.0
print(p.y)                                             # 2.0
print(p)                                               # Point(x=1.0, y=2.0)

# Default values
p2 = Point(3.0)
print(p2.y)                                            # 0.0

# asdict
d = asdict(p)
print(d['x'])                                          # 1.0
print(d['y'])                                          # 2.0

# astuple
t = astuple(p)
print(t[0])                                            # 1.0
print(t[1])                                            # 2.0

# replace
p3 = replace(p, x=10.0)
print(p3.x)                                            # 10.0
print(p3.y)                                            # 2.0

# field with default_factory
@dataclass
class Container:
    items: list = field(default_factory=list)
    name: str = 'default'

c1 = Container()
c2 = Container()
c1.items.append(1)
print(c1.items)                                        # [1]
print(c2.items)                                        # []
print(c1.name)                                         # default

# Inheritance
@dataclass
class Point3D(Point):
    z: float = 0.0

p4 = Point3D(1.0, 2.0, 3.0)
print(p4.z)                                            # 3.0

print('done')
