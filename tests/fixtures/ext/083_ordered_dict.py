# collections.OrderedDict

from collections import OrderedDict

# Basic OrderedDict
od = OrderedDict()
od['b'] = 2
od['a'] = 1
od['c'] = 3
print(list(od.keys()))                             # ['b', 'a', 'c']
print(list(od.values()))                           # [2, 1, 3]

# Preserves insertion order
od2 = OrderedDict([('first', 1), ('second', 2), ('third', 3)])
print(list(od2.items()))                           # [('first', 1), ('second', 2), ('third', 3)]

# move_to_end
od2.move_to_end('first')
print(list(od2.keys()))                            # ['second', 'third', 'first']

od2.move_to_end('first', last=False)
print(list(od2.keys()))                            # ['first', 'second', 'third']

# popitem (LIFO by default)
od3 = OrderedDict([('a', 1), ('b', 2), ('c', 3)])
item = od3.popitem()
print(item)                                        # ('c', 3)
item2 = od3.popitem(last=False)
print(item2)                                       # ('a', 1)
print(list(od3.keys()))                            # ['b']

# Equality (order matters for OrderedDict vs OrderedDict)
od4 = OrderedDict([('a', 1), ('b', 2)])
od5 = OrderedDict([('b', 2), ('a', 1)])
od6 = OrderedDict([('a', 1), ('b', 2)])
print(od4 == od5)                                  # False
print(od4 == od6)                                  # True

# Regular dict equality doesn't care about order
d1 = {'a': 1, 'b': 2}
d2 = {'b': 2, 'a': 1}
print(d1 == d2)                                    # True

# OrderedDict can be compared with regular dict
print(od4 == d1)                                   # True

# update
od7 = OrderedDict([('x', 1)])
od7.update({'y': 2, 'z': 3})
print(list(od7.keys()))                            # ['x', 'y', 'z']

# setdefault
od8 = OrderedDict()
od8.setdefault('key', 'default_val')
print(od8['key'])                                  # default_val
od8.setdefault('key', 'other')
print(od8['key'])                                  # default_val

# copy
od9 = OrderedDict([('a', 1), ('b', 2)])
od10 = od9.copy()
od10['c'] = 3
print(list(od9.keys()))                            # ['a', 'b']
print(list(od10.keys()))                           # ['a', 'b', 'c']

print('done')
