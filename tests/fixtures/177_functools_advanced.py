import functools

# lru_cache
@functools.lru_cache(maxsize=128)
def fib(n):
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)

print(fib(10))                                         # 55
print(fib(20))                                         # 6765

info = fib.cache_info()
print(info.hits > 0)                                   # True
print(info.maxsize)                                    # 128

fib.cache_clear()
print(fib.cache_info().currsize)                       # 0

# wraps
def decorator(f):
    @functools.wraps(f)
    def wrapper(*a, **kw):
        return f(*a, **kw)
    return wrapper

@decorator
def greet(name):
    """Greet someone."""
    return f'Hello, {name}'

print(greet.__name__)                                  # greet
print(greet.__doc__)                                   # Greet someone.
print(greet('world'))                                  # Hello, world

# reduce
result = functools.reduce(lambda a, b: a + b, [1, 2, 3, 4, 5])
print(result)                                          # 15

result2 = functools.reduce(lambda a, b: a * b, range(1, 6))
print(result2)                                         # 120

# partial
add = lambda x, y: x + y
add5 = functools.partial(add, 5)
print(add5(3))                                         # 8
print(add5(10))                                        # 15

# cached_property
class Circle:
    def __init__(self, r):
        self.r = r

    @functools.cached_property
    def area(self):
        import math
        return math.pi * self.r * self.r

c = Circle(5)
area = c.area
print(round(area, 2))                                  # 78.54
print(c.area is area)                                  # True (cached)

print('done')
