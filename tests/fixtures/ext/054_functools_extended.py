# functools extended

import functools

# reduce
result = functools.reduce(lambda a, b: a + b, [1, 2, 3, 4, 5])
print(result)                                        # 15

result2 = functools.reduce(lambda a, b: a * b, [1, 2, 3, 4], 1)
print(result2)                                       # 24

# partial
def power(base, exp):
    return base ** exp

square = functools.partial(power, exp=2)
cube = functools.partial(power, exp=3)
print(square(4))                                     # 16
print(cube(3))                                       # 27

def greet(greeting, name):
    return f'{greeting}, {name}!'

hello = functools.partial(greet, 'Hello')
print(hello('Alice'))                                # Hello, Alice!
print(hello('Bob'))                                  # Hello, Bob!

# lru_cache
@functools.lru_cache(maxsize=128)
def fib(n):
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)

print(fib(10))                                       # 55
print(fib(20))                                       # 6765

# cache (unbounded)
@functools.cache
def factorial(n):
    if n == 0:
        return 1
    return n * factorial(n - 1)

print(factorial(10))                                 # 3628800

# total_ordering
@functools.total_ordering
class Weight:
    def __init__(self, kg):
        self.kg = kg
    def __eq__(self, other):
        return self.kg == other.kg
    def __lt__(self, other):
        return self.kg < other.kg

w1 = Weight(50)
w2 = Weight(70)
w3 = Weight(50)
print(w1 < w2)                                       # True
print(w1 > w2)                                       # False
print(w1 <= w3)                                      # True
print(w1 >= w3)                                      # True

# reduce with strings
words = ['Hello', ' ', 'World']
sentence = functools.reduce(lambda a, b: a + b, words)
print(sentence)                                      # Hello  World

print('done')
