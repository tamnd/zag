# __slots__ in classes

class Point:
    __slots__ = ('x', 'y')
    def __init__(self, x, y):
        self.x = x
        self.y = y
    def __repr__(self):
        return f'Point({self.x}, {self.y})'

p = Point(1, 2)
print(p.x)                                         # 1
print(p.y)                                         # 2
p.x = 10
print(p.x)                                         # 10

# __slots__ with inheritance
class Point3D(Point):
    __slots__ = ('z',)
    def __init__(self, x, y, z):
        super().__init__(x, y)
        self.z = z

p3 = Point3D(1, 2, 3)
print(p3.x, p3.y, p3.z)                          # 1 2 3

# Class without __slots__ can add attrs
class Regular:
    pass

r = Regular()
r.x = 5
r.y = 10
print(r.x, r.y)                                   # 5 10

# __slots__ with list
class Config:
    __slots__ = ['name', 'value']
    def __init__(self, name, value):
        self.name = name
        self.value = value

c = Config('debug', True)
print(c.name)                                      # debug
print(c.value)                                     # True

# Check __slots__ attribute
print('x' in Point.__slots__)                     # True
print('z' in Point.__slots__)                     # False

# slots instance has no __dict__ (in CPython, but we just test it works)
print(isinstance(p, Point))                        # True

print('done')
