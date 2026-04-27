# functools.cache and lru_cache

import functools

# lru_cache basic
@functools.lru_cache(maxsize=None)
def fib(n):
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)

print(fib(10))                                     # 55
print(fib(20))                                     # 6765

# cache_info
info = fib.cache_info()
print(info.hits > 0)                              # True
print(info.misses > 0)                            # True

# cache_clear
fib.cache_clear()
info2 = fib.cache_info()
print(info2.hits)                                  # 0
print(info2.currsize)                              # 0

# lru_cache with maxsize
@functools.lru_cache(maxsize=3)
def square(n):
    return n * n

print(square(2))                                   # 4
print(square(3))                                   # 9
print(square(4))                                   # 16
print(square(2))                                   # 4 (from cache)

sq_info = square.cache_info()
print(sq_info.maxsize)                             # 3

# functools.cache (unbounded)
@functools.cache
def factorial(n):
    if n == 0:
        return 1
    return n * factorial(n - 1)

print(factorial(5))                                # 120
print(factorial(10))                               # 3628800

# reduce
from functools import reduce
total = reduce(lambda x, y: x + y, [1, 2, 3, 4, 5])
print(total)                                       # 15

product = reduce(lambda x, y: x * y, [1, 2, 3, 4], 1)
print(product)                                     # 24

# partial
from functools import partial

def power(base, exp):
    return base ** exp

square_fn = partial(power, exp=2)
cube_fn = partial(power, exp=3)

print(square_fn(5))                                # 25
print(cube_fn(3))                                  # 27

print('done')
