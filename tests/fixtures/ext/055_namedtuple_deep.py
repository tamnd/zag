# namedtuple deeper features

from collections import namedtuple

# Basic namedtuple
Point = namedtuple('Point', ['x', 'y'])
p = Point(1, 2)
print(p.x)                                           # 1
print(p.y)                                           # 2
print(p[0])                                          # 1
print(p[1])                                          # 2
print(len(p))                                        # 2

# _asdict
d = p._asdict()
print(d['x'])                                        # 1
print(d['y'])                                        # 2

# _replace
p2 = p._replace(x=10)
print(p2.x)                                          # 10
print(p2.y)                                          # 2
print(p.x)                                           # 1 (original unchanged)

# _fields
print(Point._fields)                                 # ('x', 'y')

# _make
p3 = Point._make([3, 4])
print(p3)                                            # Point(x=3, y=4)

# Defaults
Color = namedtuple('Color', ['r', 'g', 'b', 'a'], defaults=[255])
c1 = Color(10, 20, 30)
print(c1.a)                                          # 255
c2 = Color(10, 20, 30, 128)
print(c2.a)                                          # 128

# Nested namedtuples
Circle = namedtuple('Circle', ['center', 'radius'])
circle = Circle(Point(0, 0), 5)
print(circle.center.x)                               # 0
print(circle.radius)                                 # 5

# Unpack
x, y = Point(7, 8)
print(x)                                             # 7
print(y)                                             # 8

# Equality
pa = Point(1, 2)
pb = Point(1, 2)
pc = Point(1, 3)
print(pa == pb)                                      # True
print(pa == pc)                                      # False

print('done')
