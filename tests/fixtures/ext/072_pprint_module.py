# pprint module

import pprint

# Basic pprint
data = {'name': 'Alice', 'age': 30, 'scores': [100, 95, 88]}
pprint.pprint(data)

# Nested structure
nested = {
    'a': [1, 2, 3],
    'b': {'x': 10, 'y': 20},
    'c': 'hello',
}
pprint.pprint(nested)

# pformat returns string
s = pprint.pformat({'key': 'value', 'num': 42})
print(type(s).__name__)                             # str

# depth limiting
deep = {'a': {'b': {'c': {'d': 'deep'}}}}
pprint.pprint(deep, depth=2)

# width
lst = list(range(10))
pprint.pprint(lst, width=40)

# PrettyPrinter object
pp = pprint.PrettyPrinter(indent=4)
pp.pprint([1, 2, 3])

# isreadable
print(pprint.isreadable({'a': 1}))                 # True
print(pprint.isreadable(lambda: None))             # False

# isrecursive
lst2 = []
lst2.append(lst2)  # recursive
print(pprint.isrecursive(lst2))                    # True
print(pprint.isrecursive([1, 2, 3]))               # False

print('done')
