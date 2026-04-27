# collections.ChainMap

from collections import ChainMap

# Basic ChainMap
d1 = {'a': 1, 'b': 2}
d2 = {'b': 3, 'c': 4}
cm = ChainMap(d1, d2)

print(cm['a'])                                     # 1
print(cm['b'])                                     # 2 (from first map)
print(cm['c'])                                     # 4

# len (unique keys)
print(len(cm))                                     # 3

# in operator
print('a' in cm)                                   # True
print('d' in cm)                                   # False

# keys, values
print(sorted(cm.keys()))                           # ['a', 'b', 'c']

# Setting updates first map only
cm['d'] = 10
print(d1)                                          # {'a': 1, 'b': 2, 'd': 10}
print(cm['d'])                                     # 10

# new_child
child = cm.new_child({'a': 100})
print(child['a'])                                  # 100
print(child['b'])                                  # 2 (from parent)

# parents
print(child.parents['a'])                          # 1

# maps attribute
cm2 = ChainMap({'x': 1}, {'y': 2}, {'z': 3})
print(len(cm2.maps))                               # 3
print(cm2.maps[0])                                 # {'x': 1}

# ChainMap from empty
empty_cm = ChainMap()
print(len(empty_cm))                               # 0
empty_cm['key'] = 'val'
print(empty_cm['key'])                             # val

# get with default
print(cm.get('missing', 'default'))               # default
print(cm.get('a'))                                 # 1

print('done')
