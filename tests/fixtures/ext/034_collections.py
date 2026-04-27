from collections import (OrderedDict, ChainMap, namedtuple,
                         defaultdict, Counter, deque)

# OrderedDict
od = OrderedDict()
od['a'] = 1
od['b'] = 2
od['c'] = 3
print(list(od.keys()))                                 # ['a', 'b', 'c']
od.move_to_end('a')
print(list(od.keys()))                                 # ['b', 'c', 'a']

# ChainMap
d1 = {'a': 1, 'b': 2}
d2 = {'b': 3, 'c': 4}
cm = ChainMap(d1, d2)
print(cm['a'])                                         # 1
print(cm['b'])                                         # 2  (from d1)
print(cm['c'])                                         # 4  (from d2)
print(len(cm))                                         # 3

# namedtuple
Point = namedtuple('Point', ['x', 'y'])
p = Point(1, 2)
print(p.x)                                             # 1
print(p.y)                                             # 2
print(p[0])                                            # 1
print(p._asdict())                                     # {'x': 1, 'y': 2}

# defaultdict
dd = defaultdict(list)
dd['a'].append(1)
dd['a'].append(2)
dd['b'].append(3)
print(dd['a'])                                         # [1, 2]
print(dd['b'])                                         # [3]
print(dd['c'])                                         # []

# Counter
c = Counter('abracadabra')
print(c['a'])                                          # 5
print(c.most_common(2))                                # [('a', 5), ('b', 2)] or [('a', 5), ('r', 2)]

# deque
dq = deque([1, 2, 3])
dq.appendleft(0)
dq.append(4)
print(list(dq))                                        # [0, 1, 2, 3, 4]
dq.rotate(2)
print(list(dq))                                        # [3, 4, 0, 1, 2]

print('done')
