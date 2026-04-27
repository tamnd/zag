import pprint

# pformat basic types
print(pprint.pformat('hello'))
print(pprint.pformat(42))
print(pprint.pformat([1, 2, 3]))
print(pprint.pformat({'b': 2, 'a': 1}))

# pprint writes to stdout
pprint.pprint({'z': 10, 'a': 1})

# width causes wrapping
print(pprint.pformat({'key1': 'value1', 'key2': 'value2'}, width=20))

# sort_dicts=False keeps insertion order
print(pprint.pformat({'b': 2, 'a': 1}, sort_dicts=False))

# nested structures
print(pprint.pformat({'x': [1, 2], 'y': {'inner': 3}}, sort_dicts=True))

# PrettyPrinter class
pp = pprint.PrettyPrinter(sort_dicts=True)
print(pp.pformat({'z': 1, 'a': 2}))

# saferepr
print(pprint.saferepr('hello'))
print(pprint.saferepr([1, 2, 3]))

# isreadable
print(pprint.isreadable('hello'))

# isrecursive
x = []
x.append(x)
print(pprint.isrecursive(x))
print(pprint.isrecursive([1, 2]))
