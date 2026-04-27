# collections.defaultdict extended

from collections import defaultdict

# Basic defaultdict with list
dd = defaultdict(list)
dd['a'].append(1)
dd['a'].append(2)
dd['b'].append(3)
print(dict(dd))                                    # {'a': [1, 2], 'b': [3]}

# defaultdict with int (counting)
dd2 = defaultdict(int)
for c in 'hello world':
    dd2[c] += 1
print(dd2['l'])                                    # 3
print(dd2['o'])                                    # 2
print(dd2['z'])                                    # 0 (default)

# defaultdict with set
dd3 = defaultdict(set)
dd3['fruits'].add('apple')
dd3['fruits'].add('banana')
dd3['vegs'].add('carrot')
print(sorted(dd3['fruits']))                       # ['apple', 'banana']

# defaultdict with factory function
def make_zero():
    return 0

dd4 = defaultdict(make_zero)
dd4['x'] += 5
print(dd4['x'])                                    # 5
print(dd4['y'])                                    # 0

# Nested defaultdict
nested = defaultdict(lambda: defaultdict(int))
nested['a']['x'] += 1
nested['a']['y'] += 2
nested['b']['x'] += 10
print(nested['a']['x'])                            # 1
print(nested['a']['y'])                            # 2
print(nested['b']['x'])                            # 10

# Missing key uses factory
dd6 = defaultdict(str)
val = dd6['missing']
print(repr(val))                                   # ''
print('missing' in dd6)                            # True

# Update and iteration
dd8 = defaultdict(int, {'a': 1, 'b': 2})
dd8.update({'c': 3})
print(sorted(dd8.items()))                         # [('a', 1), ('b', 2), ('c', 3)]

print('done')
