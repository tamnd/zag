# collections.Counter extended

from collections import Counter

# Basic counter from iterable
c = Counter('aabbbcccc')
print(c['a'])                                       # 2
print(c['b'])                                       # 3
print(c['c'])                                       # 4
print(c['z'])                                       # 0 (missing returns 0)

# Counter from dict
c2 = Counter({'red': 4, 'blue': 2})
print(c2['red'])                                    # 4

# Counter from kwargs
c3 = Counter(cats=4, dogs=8)
print(c3['dogs'])                                   # 8

# most_common
c4 = Counter('abracadabra')
print(c4.most_common(3))                           # [('a', 5), ('b', 2), ('r', 2)]

# elements()
c5 = Counter(a=2, b=1)
print(sorted(c5.elements()))                       # ['a', 'a', 'b']

# update (adds counts)
c6 = Counter(a=1, b=2)
c6.update({'a': 3, 'c': 1})
print(c6['a'])                                     # 4
print(c6['b'])                                     # 2
print(c6['c'])                                     # 1

# subtract
c7 = Counter(a=4, b=2, c=0)
c7.subtract({'a': 1, 'b': 3, 'd': 1})
print(c7['a'])                                     # 3
print(c7['b'])                                     # -1
print(c7['d'])                                     # -1

# Arithmetic operations
c8 = Counter(a=3, b=1)
c9 = Counter(a=1, b=2, c=5)

# Addition
c10 = c8 + c9
print(sorted(c10.items()))                         # [('a', 4), ('b', 3), ('c', 5)]

# Subtraction (keeps positive only)
c11 = c8 - c9
print(sorted(c11.items()))                         # [('a', 2)]

# Intersection (min)
c12 = c8 & c9
print(sorted(c12.items()))                         # [('a', 1), ('b', 1)]

# Union (max)
c13 = c8 | c9
print(sorted(c13.items()))                         # [('a', 3), ('b', 2), ('c', 5)]

# total() - sum of all counts
c14 = Counter(a=5, b=3, c=2)
print(c14.total())                                 # 10

# keys, values, items
print(sorted(c14.keys()))                          # ['a', 'b', 'c']

print('done')
