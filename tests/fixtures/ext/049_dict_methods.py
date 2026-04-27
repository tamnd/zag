# Dict methods and operations

d = {'a': 1, 'b': 2, 'c': 3}

# Basic access
print(d.get('a'))                                     # 1
print(d.get('z', 0))                                  # 0

# setdefault
d.setdefault('d', 4)
d.setdefault('a', 99)                                 # won't overwrite
print(d['d'])                                         # 4
print(d['a'])                                         # 1

# update
d.update({'e': 5, 'f': 6})
print(len(d))                                         # 6

d2 = dict(g=7, h=8)
print(d2['g'])                                        # 7

# pop
val = d.pop('f')
print(val)                                            # 6
val2 = d.pop('z', -1)
print(val2)                                           # -1

# popitem
d3 = {'x': 10, 'y': 20}
k, v = d3.popitem()
print(isinstance(k, str))                             # True
print(isinstance(v, int))                             # True

# keys, values, items
d4 = {'a': 1, 'b': 2, 'c': 3}
print(sorted(d4.keys()))                              # ['a', 'b', 'c']
print(sorted(d4.values()))                            # [1, 2, 3]
print(sorted(d4.items()))                             # [('a', 1), ('b', 2), ('c', 3)]

# copy
d5 = d4.copy()
d5['d'] = 4
print('d' in d4)                                      # False
print('d' in d5)                                      # True

# dict comprehension
inv = {v: k for k, v in d4.items()}
print(inv[1])                                         # a

# fromkeys
dk = dict.fromkeys(['x', 'y', 'z'], 0)
print(dk['x'])                                        # 0
print(dk['z'])                                        # 0

# Merge operator (Python 3.9+)
a = {'x': 1}
b = {'y': 2}
c = a | b
print(sorted(c.keys()))                               # ['x', 'y']
print(c['x'])                                         # 1

# in operator
print('a' in d4)                                      # True
print('z' in d4)                                      # False

# len
print(len(d4))                                        # 3

# clear
d6 = {'a': 1}
d6.clear()
print(len(d6))                                        # 0

print('done')
