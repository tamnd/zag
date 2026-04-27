# Advanced generators

# Generator with send
def accumulator():
    total = 0
    while True:
        val = yield total
        if val is None:
            break
        total += val

gen = accumulator()
next(gen)                                            # prime the generator
print(gen.send(10))                                 # 10
print(gen.send(20))                                 # 30
print(gen.send(5))                                  # 35

# yield from
def chain(*iterables):
    for it in iterables:
        yield from it

print(list(chain([1, 2], [3, 4], [5])))            # [1, 2, 3, 4, 5]

# yield from with generator
def inner():
    yield 1
    yield 2
    yield 3

def outer():
    yield 0
    yield from inner()
    yield 4

print(list(outer()))                               # [0, 1, 2, 3, 4]

# Generator as infinite sequence
def integers(start=0):
    n = start
    while True:
        yield n
        n += 1

gen2 = integers(10)
print([next(gen2) for _ in range(5)])              # [10, 11, 12, 13, 14]

# Generator with return value (yield from passes it)
def producer():
    yield 1
    yield 2
    return 'finished'

def consumer():
    result = yield from producer()
    print(f'producer returned: {result}')          # producer returned: finished

list(consumer())

# Chaining generators
def squares(n):
    for i in range(n):
        yield i * i

def evens(it):
    for x in it:
        if x % 2 == 0:
            yield x

print(list(evens(squares(6))))                    # [0, 4, 16]

# Generator expression
gen3 = (x * x for x in range(5))
print(list(gen3))                                  # [0, 1, 4, 9, 16]

# Lazy pipeline
def take(n, it):
    for i, x in enumerate(it):
        if i >= n:
            break
        yield x

def fib_gen():
    a, b = 0, 1
    while True:
        yield a
        a, b = b, a + b

print(list(take(8, fib_gen())))                    # [0, 1, 1, 2, 3, 5, 8, 13]

print('done')
