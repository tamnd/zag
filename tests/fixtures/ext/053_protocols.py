# Protocol / dunder methods

# __bool__
class MyBool:
    def __init__(self, val):
        self.val = val
    def __bool__(self):
        return bool(self.val)

print(bool(MyBool(0)))                                # False
print(bool(MyBool(1)))                                # True
print(bool(MyBool('')))                               # False

# __add__, __radd__, __mul__
class Vec:
    def __init__(self, x, y):
        self.x = x
        self.y = y
    def __add__(self, other):
        return Vec(self.x + other.x, self.y + other.y)
    def __mul__(self, scalar):
        return Vec(self.x * scalar, self.y * scalar)
    def __rmul__(self, scalar):
        return Vec(self.x * scalar, self.y * scalar)
    def __eq__(self, other):
        return self.x == other.x and self.y == other.y
    def __str__(self):
        return f'Vec({self.x}, {self.y})'

v1 = Vec(1, 2)
v2 = Vec(3, 4)
v3 = v1 + v2
print(v3)                                             # Vec(4, 6)
v4 = v1 * 3
print(v4)                                             # Vec(3, 6)
v5 = 2 * v1
print(v5)                                             # Vec(2, 4)

# __hash__ and dict keys
class Point:
    def __init__(self, x, y):
        self.x = x
        self.y = y
    def __eq__(self, other):
        return self.x == other.x and self.y == other.y
    def __hash__(self):
        return hash((self.x, self.y))

p1 = Point(1, 2)
p2 = Point(1, 2)
p3 = Point(3, 4)
d = {p1: 'first', p3: 'second'}
print(d[p2])                                          # first (p2 == p1)

# __enter__ and __exit__
class Timer:
    def __init__(self, name):
        self.name = name
        self.elapsed = 0
    def __enter__(self):
        self.start = 0
        return self
    def __exit__(self, *args):
        self.elapsed = 42  # fake elapsed
        return False

with Timer('test') as t:
    pass
print(t.elapsed)                                      # 42

# __getattr__ and __setattr__
class Proxy:
    def __init__(self, target):
        object.__setattr__(self, '_target', target)
    def __getattr__(self, name):
        return getattr(self._target, name)
    def __setattr__(self, name, value):
        if name == '_target':
            object.__setattr__(self, name, value)
        else:
            setattr(self._target, name, value)

class Simple:
    def __init__(self):
        self.x = 10

s = Simple()
p = Proxy(s)
print(p.x)                                            # 10
p.x = 20
print(s.x)                                            # 20

# __call__
class Accumulator:
    def __init__(self):
        self.total = 0
    def __call__(self, n):
        self.total += n
        return self.total

acc = Accumulator()
print(acc(5))                                         # 5
print(acc(3))                                         # 8
print(acc(2))                                         # 10

print('done')
