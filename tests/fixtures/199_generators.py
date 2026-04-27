# Generator functions and expressions

# Basic generator
def count_up(n):
    for i in range(n):
        yield i

g = count_up(5)
print(list(g))                                        # [0, 1, 2, 3, 4]

# Generator with send
def accumulator():
    total = 0
    while True:
        val = yield total
        if val is None:
            break
        total += val

acc = accumulator()
next(acc)                                             # prime
print(acc.send(10))                                   # 10
print(acc.send(20))                                   # 30
print(acc.send(5))                                    # 35

# Generator expression
squares = (x**2 for x in range(6))
print(list(squares))                                  # [0, 1, 4, 9, 16, 25]

# Nested generator
def flatten(nested):
    for item in nested:
        if isinstance(item, list):
            yield from flatten(item)
        else:
            yield item

nested = [1, [2, [3, 4], 5], 6]
print(list(flatten(nested)))                          # [1, 2, 3, 4, 5, 6]

# Generator with return value
def gen_with_return():
    yield 1
    yield 2
    return 'done'

g2 = gen_with_return()
print(next(g2))                                       # 1
print(next(g2))                                       # 2
try:
    next(g2)
except StopIteration as e:
    print(e.value)                                    # done

# yield from
def chain(*iterables):
    for it in iterables:
        yield from it

print(list(chain([1, 2], [3, 4], [5])))               # [1, 2, 3, 4, 5]

print('done')
