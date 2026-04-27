# operator module

import operator

# Arithmetic operators
print(operator.add(3, 4))                           # 7
print(operator.sub(10, 3))                          # 7
print(operator.mul(4, 5))                           # 20
print(operator.truediv(10, 4))                      # 2.5
print(operator.floordiv(10, 3))                     # 3
print(operator.mod(10, 3))                          # 1
print(operator.pow(2, 8))                           # 256
print(operator.neg(-5))                             # 5
print(operator.abs(-7))                             # 7

# Comparison operators
print(operator.eq(1, 1))                            # True
print(operator.ne(1, 2))                            # True
print(operator.lt(1, 2))                            # True
print(operator.le(2, 2))                            # True
print(operator.gt(3, 2))                            # True
print(operator.ge(2, 2))                            # True

# Logical not
print(operator.not_(False))                         # True
print(operator.not_(True))                          # False

# Bitwise on integers
print(operator.and_(6, 3))                          # 2
print(operator.or_(6, 3))                           # 7
print(operator.xor(6, 3))                           # 5

# itemgetter
get_first = operator.itemgetter(0)
get_second = operator.itemgetter(1)
lst = [10, 20, 30]
print(get_first(lst))                               # 10
print(get_second(lst))                              # 20

# itemgetter for sorting
data = [('Alice', 30), ('Bob', 25), ('Charlie', 35)]
data.sort(key=operator.itemgetter(1))
print(data)                                         # [('Bob', 25), ('Alice', 30), ('Charlie', 35)]

# attrgetter
class Person:
    def __init__(self, name, age):
        self.name = name
        self.age = age

people = [Person('Alice', 30), Person('Bob', 25), Person('Charlie', 35)]
get_name = operator.attrgetter('name')
get_age = operator.attrgetter('age')
print(get_name(people[0]))                          # Alice
print(get_age(people[1]))                           # 25

people.sort(key=get_age)
print([p.name for p in people])                     # ['Bob', 'Alice', 'Charlie']

# methodcaller
class Str:
    def __init__(self, s):
        self.s = s
    def upper(self):
        return self.s.upper()

words = [Str('hello'), Str('world')]
upper_fn = operator.methodcaller('upper')
print([upper_fn(w) for w in words])                # ['HELLO', 'WORLD']

print('done')
