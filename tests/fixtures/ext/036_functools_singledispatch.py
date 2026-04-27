import functools

# singledispatch
@functools.singledispatch
def process(arg):
    return f'generic: {arg}'

@process.register(int)
def _(arg):
    return f'int: {arg}'

@process.register(str)
def _(arg):
    return f'str: {arg}'

@process.register(list)
def _(arg):
    return f'list: {len(arg)}'

print(process(42))                                     # int: 42
print(process('hello'))                                # str: hello
print(process([1, 2, 3]))                              # list: 3
print(process(3.14))                                   # generic: 3.14

# total_ordering
from functools import total_ordering

@total_ordering
class Student:
    def __init__(self, name, grade):
        self.name = name
        self.grade = grade
    def __eq__(self, other):
        return self.grade == other.grade
    def __lt__(self, other):
        return self.grade < other.grade

s1 = Student('Alice', 90)
s2 = Student('Bob', 85)
print(s1 > s2)                                         # True
print(s2 >= s1)                                        # False
print(s1 == s1)                                        # True

# partial
add = lambda x, y: x + y
add5 = functools.partial(add, 5)
print(add5(3))                                         # 8
print(add5(10))                                        # 15

# reduce
from functools import reduce
print(reduce(lambda a, b: a + b, [1, 2, 3, 4, 5]))    # 15
print(reduce(lambda a, b: a * b, range(1, 6)))         # 120

print('done')
